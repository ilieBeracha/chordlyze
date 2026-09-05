import SwiftUI

/// Practice mode: song in headphones, instrument at the mic. When Spotify is
/// playing this track the take locks to Spotify's clock (position captured at
/// record start, teleprompter follows the poller); otherwise a local clock
/// from 0:00. The take is then uploaded for scoring against the song's chart.
struct PracticeView: View {
    let analysis: ChordAnalysis
    let title: String
    let artist: String
    /// Album name, when known: keeps the teleprompter's lyrics on the same
    /// version the sheet and live view show.
    var album: String? = nil
    let trackID: String
    @ObservedObject var songStore: SongSheetStore

    private enum Phase: Equatable {
        case intro
        case countdown(Int)
        case recording
        case uploading
        case failed(String)
    }

    @State private var recorder = TakeRecorder()
    @State private var metronome = Metronome()
    @ObservedObject private var nowPlaying = SpotifyNowPlaying.shared
    @State private var phase: Phase = .intro
    /// Count-in in flight; cancelled when the screen goes away so no take
    /// starts recording behind a screen that is no longer there.
    @State private var countIn: Task<Void, Never>?
    @State private var startedAt: ContinuousClock.Instant?
    /// Song second that take second 0 corresponds to.
    @State private var songOffset: Double = 0
    /// Take clock is Spotify's playback position rather than a local timer.
    @State private var synced = false
    /// Full song length at record start (Spotify's), for the progress rail.
    @State private var takeDuration: Double?
    /// Metronome is clicking the song's beat grid (local clock only).
    @State private var clicking = false
    @State private var report: BackendClient.PracticeReport?
    /// Spotify position vs. expected drift beyond this = user seeked mid-take.
    private static let seekTolerance: Double = 2.5
    /// Shorter takes are dropped on interruption instead of scored.
    private static let minScorableTake: Double = 10
    private static let maxTake: Double = 600

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
        .task { await songStore.observe() }
        .onChange(of: songStore.analysis) { _, current in
            if current != analysis {
                abandon()
                phase = .failed("This song’s analysis changed or was cleared. Reopen its sheet before starting another take.")
            }
        }
        .task(id: phase == .recording) {
            while phase == .recording && !Task.isCancelled {
                tick()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .onDisappear { abandon() }
        .navigationDestination(isPresented: Binding(
            get: { report != nil },
            set: { if !$0 { report = nil; phase = .intro } })) {
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
                    guard countIn == nil else { return }
                    countIn = Task { await begin() }
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
                        "Synced to Spotify · playing at \(mmss(pos)). Start locks the take to Spotify's position.")
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
            LiveNowView(store: songStore) {
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
        defer { countIn = nil }
        guard songStore.canPractice, songStore.analysis == analysis else {
            phase = .failed("The song sheet is updating. Reopen it before starting this take.")
            return
        }
        guard await recorder.requestPermission() else {
            phase = .failed("Microphone access denied — enable it in Settings.")
            return
        }
        guard !Task.isCancelled else { return }
        let followSpotify = spotifyThisTrack?.isPlaying == true
        do {
            if !followSpotify, let tempo = analysis.tempo {
                // Solo: four-beat count-in at the song's tempo, clicks through the take.
                let period = 60 / tempo.bpm
                let recordAt = try metronome.start(countIn: 4, period: period, beats: tempo.beats)
                for n in [4, 3, 2, 1] {
                    withAnimation { phase = .countdown(n) }
                    try await Task.sleep(until: recordAt - .seconds(Double(n - 1) * period), clock: .continuous)
                }
                clicking = true
            } else {
                for n in [3, 2, 1] {
                    withAnimation { phase = .countdown(n) }
                    try await Task.sleep(for: .seconds(1))
                }
                clicking = false
            }
            try recorder.start(maxDuration: Self.maxTake)
        } catch is CancellationError {
            // Screen went away during the count-in; nothing started.
            metronome.stop()
            return
        } catch {
            metronome.stop()
            phase = .failed("Could not start: \(error.localizedDescription)")
            return
        }
        startedAt = .now
        if followSpotify, let pos = nowPlaying.livePosition() {
            songOffset = pos
            synced = true
        } else {
            songOffset = 0
            synced = false
        }
        takeDuration = spotifyThisTrack?.track.durationMs.map { Double($0) / 1000 }
        phase = .recording
    }

    /// Song position of the take right now.
    private func takePosition() -> TimeInterval? {
        guard let startedAt else { return nil }
        if synced, let live = nowPlaying.livePosition() { return live }
        return songOffset + startedAt.duration(to: .now).seconds
    }

    /// Once a second while recording: the take hit its cap, or Spotify
    /// paused, seeked, or changed song mid-take. Either way the rest can't
    /// be scored, so end it here (score what was played if long enough).
    private func tick() {
        guard phase == .recording, let startedAt else { return }
        let elapsed = startedAt.duration(to: .now).seconds
        if !recorder.isRecording {
            finish()
            return
        }
        guard synced else { return }
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
            discard()
            phase = .failed("\(reason). Keep it playing for a continuous take.")
        }
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

    /// Stop everything and throw the audio away.
    private func discard() {
        metronome.stop()
        if let url = recorder.stop() { try? FileManager.default.removeItem(at: url) }
    }

    /// Leaving the screen: cancel a count-in, drop an unfinished take.
    private func abandon() {
        countIn?.cancel()
        countIn = nil
        if phase == .recording {
            discard()
            phase = .intro
        }
    }
}
