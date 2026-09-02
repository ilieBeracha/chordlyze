import SwiftUI

/// Practice mode: song in headphones, instrument at the mic. When Spotify is
/// playing this track the take locks to Spotify's clock (position captured at
/// record start, teleprompter follows the poller); otherwise a local clock
/// from 0:00. The take is then uploaded for scoring against the song's chart.
struct PracticeView: View {
    let analysis: ChordAnalysis
    let title: String
    let artist: String
    let trackID: String

    private enum Phase: Equatable {
        case intro
        case countdown(Int)
        case recording
        case uploading
        case failed(String)
    }

    @StateObject private var recorder = ListenRecorder()
    @State private var metronome = Metronome()
    @ObservedObject private var nowPlaying = SpotifyNowPlaying.shared
    @State private var phase: Phase = .intro
    @State private var startedAt: Date?
    /// Song second that take second 0 corresponds to.
    @State private var songOffset: Double = 0
    /// Take clock is Spotify's playback position rather than a local timer.
    @State private var synced = false
    /// Metronome is clicking the song's beat grid (local clock only).
    @State private var clicking = false
    @State private var report: BackendClient.PracticeReport?
    @Environment(\.dismiss) private var dismiss
    private static let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    /// Spotify position vs. expected drift beyond this = user seeked mid-take.
    private static let seekTolerance: Double = 2.5
    /// Shorter takes are dropped on interruption instead of scored.
    private static let minScorableTake: Double = 10

    /// Spotify playback of this track, when that's what the account is playing.
    private var spotifyThisTrack: SpotifyNowPlaying.Playing? {
        guard let p = nowPlaying.playing, p.track.id == trackID else { return nil }
        return p
    }

    var body: some View {
        ZStack {
            switch phase {
            case .intro:
                intro
            case .countdown(let n):
                countdown(n)
            case .recording:
                recordingView
            case .uploading:
                statusView("Scoring your take…", spinning: true)
            case .failed(let message):
                failedView(message)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: Binding(
            get: { report != nil },
            set: { if !$0 { report = nil } })) {
            if let report {
                ReportCardView(report: report, title: title, artist: artist)
            }
        }
    }

    // MARK: - Phases

    private var intro: some View {
        VStack(spacing: 0) {
            HStack { BackCircle(size: 38); Spacer() }
            Spacer()
            VStack(spacing: 18) {
                Image(systemName: "headphones")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.spotifyGreen)
                Text("Practice \(title)")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text("Put the song in your headphones — the mic should hear only your instrument. Stop whenever you like.")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.secondary)
                    .multilineTextAlignment(.center)
                syncStatus
                Button {
                    Task { await begin() }
                } label: {
                    Text("Start")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.vertical, 13)
                        .padding(.horizontal, 44)
                        .background(Capsule().fill(Color.spotifyGreen))
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
            }
            .padding(.horizontal, 30)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 34)
    }

    private var syncStatus: some View {
        let solo = analysis.tempo.map { "with a metronome at \(Int($0.bpm.rounded())) BPM" }
            ?? "on a local clock"
        let (icon, tint, text): (String, Color, String) = {
            if let p = spotifyThisTrack, p.isPlaying, let pos = nowPlaying.livePosition() {
                return ("waveform", Color.spotifyGreen,
                        "Synced to Spotify · playing at \(Self.mmss(pos)). Start locks the take to Spotify's position.")
            }
            if spotifyThisTrack != nil {
                return ("pause.circle", Palette.secondary,
                        "Spotify has this song paused. Press play there to sync, or Start to play from the top \(solo).")
            }
            return (analysis.tempo == nil ? "clock" : "metronome", Palette.secondary,
                    "Spotify isn't playing this song. Play it there to sync, or Start to play from the top \(solo).")
        }()
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
            Text(text).font(.system(size: 12)).multilineTextAlignment(.leading)
        }
        .foregroundStyle(tint)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
    }

    private func countdown(_ n: Int) -> some View {
        Text("\(n)")
            .font(.system(size: 110, weight: .heavy, design: .rounded))
            .foregroundStyle(Color.spotifyGreen)
            .contentTransition(.numericText(countsDown: true))
    }

    private var recordingView: some View {
        ZStack(alignment: .bottom) {
            LiveNowView(title: title, artist: artist, analysis: analysis,
                        trackDuration: spotifyThisTrack?.track.durationMs.map { Double($0) / 1000 }) {
                takePosition()
            }
            HStack(spacing: 10) {
                Circle().fill(Palette.destructive).frame(width: 8, height: 8)
                Text(synced ? "REC · SPOTIFY" : "REC · LOCAL")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Palette.destructive)
                if clicking, let bpm = analysis.tempo?.bpm {
                    Text("♩ \(Int(bpm.rounded()))")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.secondary)
                }
                Spacer()
                Button {
                    finish()
                } label: {
                    Text("Finish take")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 22)
                        .background(Capsule().fill(Color.spotifyGreen))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 64)
        }
        .onReceive(Self.clock) { _ in checkSync() }
        .onDisappear {
            metronome.stop()
            if phase == .recording { _ = recorder.stop() }
        }
    }

    private func statusView(_ message: String, spinning: Bool) -> some View {
        VStack(spacing: 14) {
            if spinning { ProgressView() }
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Palette.secondary)
        }
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Button {
                phase = .intro
            } label: {
                Text("Try again")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.vertical, 11)
                    .padding(.horizontal, 26)
                    .background(Capsule().fill(Color.spotifyGreen))
            }
            .buttonStyle(.plain)
            BackCircle(size: 38)
        }
    }

    // MARK: - Flow

    private func begin() async {
        guard await recorder.requestPermission() else {
            phase = .failed("Microphone access denied — enable it in Settings.")
            return
        }
        let followSpotify = spotifyThisTrack?.isPlaying == true
        if !followSpotify, let tempo = analysis.tempo {
            // Solo: four-beat count-in at the song's tempo, clicks through the take.
            let period = 60 / tempo.bpm
            let recordAt: ContinuousClock.Instant
            do {
                recordAt = try metronome.start(countIn: 4, period: period, beats: tempo.beats)
            } catch {
                phase = .failed("Could not start the metronome: \(error.localizedDescription)")
                return
            }
            for n in [4, 3, 2, 1] {
                withAnimation { phase = .countdown(n) }
                try? await Task.sleep(until: recordAt - .seconds(Double(n - 1) * period), clock: .continuous)
            }
            clicking = true
        } else {
            for n in [3, 2, 1] {
                withAnimation { phase = .countdown(n) }
                try? await Task.sleep(for: .seconds(1))
            }
            clicking = false
        }
        do {
            try recorder.start(maxDuration: 600)
            startedAt = Date()
            if followSpotify, let pos = nowPlaying.livePosition() {
                songOffset = pos
                synced = true
            } else {
                songOffset = 0
                synced = false
            }
            phase = .recording
        } catch {
            metronome.stop()
            phase = .failed("Could not start recording: \(error.localizedDescription)")
        }
    }

    /// Song position of the take right now.
    private func takePosition() -> TimeInterval? {
        guard let startedAt else { return nil }
        if synced, let live = nowPlaying.livePosition() { return live }
        return songOffset + Date().timeIntervalSince(startedAt)
    }

    /// Spotify paused, seeked, or changed song mid-take: the rest of the take
    /// can't be scored, so end it here (score what was played if long enough).
    private func checkSync() {
        guard phase == .recording, synced, let startedAt else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        let expected = songOffset + elapsed
        let reason: String
        if let p = spotifyThisTrack, p.isPlaying {
            guard let live = nowPlaying.livePosition(),
                  abs(live - expected) > Self.seekTolerance else { return }
            reason = "Spotify was seeked mid-take"
        } else if spotifyThisTrack != nil {
            reason = "Spotify was paused mid-take"
        } else {
            reason = "Spotify changed song mid-take"
        }
        if elapsed >= Self.minScorableTake {
            finish()
        } else {
            metronome.stop()
            if let url = recorder.stop() { try? FileManager.default.removeItem(at: url) }
            phase = .failed("\(reason). Keep it playing for a continuous take.")
        }
    }

    private static func mmss(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(max(0, seconds)) / 60, Int(max(0, seconds)) % 60)
    }

    private func finish() {
        metronome.stop()
        guard let url = recorder.stop() else {
            phase = .failed("Nothing was recorded.")
            return
        }
        phase = .uploading
        Task {
            do {
                report = try await BackendClient.submitPracticeTake(fileURL: url, trackID: trackID,
                                                                    offset: songOffset)
            } catch {
                phase = .failed(error.localizedDescription)
            }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
