import AVFoundation
import SwiftUI

/// Practice in song time; capture and scoring retain the exact key, range and
/// pace chosen at record start. Completed and interrupted audio stays on disk.
///
/// Two ways to record. "Play from Spotify" starts the song on the account's
/// active device and the chart follows Spotify's reported position, so what
/// the player hears and what the sheet shows are the same clock. The
/// metronome path records against the chart's own beat grid with Spotify
/// paused, and is the only path that can slow the song down.
struct PracticeView: View {
    let analysis: ChordAnalysis
    let title: String
    let artist: String
    var album: String? = nil
    let trackID: String
    @ObservedObject var songStore: SongSheetStore
    var initialRange: ClosedRange<Double>? = nil
    @ObservedObject var nowPlaying: SpotifyNowPlaying = .shared
    /// Display-only lead shared with Live; the take itself is anchored to
    /// Spotify's reported position so scoring stays in real song time.
    @AppStorage("chordLead") private var lead = 0.3

    private enum Phase: Equatable { case intro, starting, countdown(Int), recording, uploading, saved, failed(String) }
    @State private var phase: Phase = .intro
    @State private var recorder = TakeRecorder()
    @State private var metronome = Metronome()
    @ObservedObject private var takes = PracticeTakeStore.shared
    @State private var countIn: Task<Void, Never>?
    @State private var startedAt: ContinuousClock.Instant?
    @State private var activeTake: PracticeTake?
    @State private var synced = false
    @State private var report: BackendClient.PracticeReport?
    @State private var sectionOnly = false
    @State private var sectionStart = 0.0
    @State private var sectionEnd = 30.0
    @State private var rate = 1.0
    @State private var initialized = false
    @State private var saveError: String?
    @State private var pausedSince: ContinuousClock.Instant?
    @State private var feedback: PracticeFeedback?
    @State private var feedbackTap: FeedbackTap?
    @State private var lastJudged: String?

    private var songEnd: Double { max(1, analysis.coverageEnd) }
    private var grid: BeatGrid? { BeatGrid(tempo: analysis.tempo, chords: analysis.chords) }
    private var rangeStart: Double { sectionOnly ? sectionStart : 0 }
    /// Metronome takes begin on a bar: the downbeat at or before the range.
    private var barStart: Double { grid.map { min($0.downbeat(atOrBefore: rangeStart), rangeStart) } ?? rangeStart }
    private var rangeEnd: Double { sectionOnly ? sectionEnd : songEnd }
    private var spotifyThisTrack: SpotifyNowPlaying.Playing? {
        guard let playing = nowPlaying.playing, playing.track.id == trackID else { return nil }
        return playing
    }
    /// Spotify plays the original recording at full speed, so following it
    /// needs the original key and 100% pace. Sections are fine: playback
    /// starts at the section.
    private var canSync: Bool { rate == 1 && songStore.manualShift == 0 }
    private var calibrationNote: String {
        songStore.timingNote ?? "Not calibrated: chords follow the chart's recording. Calibrate by ear in Key & capo if they sound early or late."
    }
    private var savedTake: PracticeTake? {
        activeTake.flatMap { active in takes.takes.first { $0.id == active.id } ?? active }
    }

    var body: some View {
        Group {
            switch phase {
            case .intro: intro
            case .starting:
                VStack(spacing: 30) {
                    ProgressView(nowPlaying.playbackDevice.map { "Starting Spotify on \($0)…" } ?? "Finding Spotify on this phone…").tint(.white)
                    Button("Cancel") { abandon(); phase = .intro }.frame(minHeight: 44)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .countdown(let n):
                VStack(spacing: 30) {
                    Text("\(n)").font(.system(size: 110, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.spotifyGreen)
                    Button("Cancel") { abandon(); phase = .intro }.frame(minHeight: 44)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .recording: recordingView
            case .uploading:
                VStack(spacing: 18) {
                    ProgressView("Scoring your take…")
                    Text("Your recording is saved on this device.").font(.subheadline).foregroundStyle(Palette.secondary)
                    BackCircle()
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .saved:
                ScrollView {
                    VStack(spacing: 20) {
                        if let savedTake { SavedTakeView(take: savedTake) }
                        if let saveError { Text(saveError).foregroundStyle(Palette.warning) }
                        if let feedback, !feedback.judged.isEmpty {
                            Text("Live feedback: \(feedback.hits) of \(feedback.judged.count) heard chords matched the chart. Scoring below is the full analysis.")
                                .font(.footnote).foregroundStyle(Palette.secondary).padding(.horizontal, 24)
                        }
                        Button(sectionOnly ? "Practice this section again" : "Record another take") {
                            activeTake = nil; saveError = nil; phase = .intro
                        }.buttonStyle(.borderedProminent).tint(.spotifyGreen)
                    }.padding(.bottom, 24)
                }
            case .failed(let message):
                VStack(spacing: 18) {
                    Text(message).multilineTextAlignment(.center)
                    Button("Back to setup") { phase = .intro }.frame(minHeight: 44)
                    BackCircle()
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(phase == .recording || isCounting ? .hidden : .visible, for: .tabBar)
        .observes(songStore)
        .onAppear {
            guard !initialized else { return }
            initialized = true
            sectionStart = min(initialRange?.lowerBound ?? 0, max(0, songEnd - 1))
            sectionEnd = min(songEnd, max(sectionStart + 1, initialRange?.upperBound ?? 30))
            sectionOnly = initialRange != nil
        }
        .onChange(of: songStore.analysis) { _, current in
            guard current != analysis else { return }
            if phase == .recording { finish(note: "The song chart changed. This take was saved without automatic scoring.", score: false) }
            else if phase == .intro || isCounting {
                abandon()
                phase = .failed("This song’s chart changed. Reopen its sheet before starting another take.")
            }
        }
        .task(id: phase == .recording) {
            while phase == .recording && !Task.isCancelled {
                tick()
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            // Headphones pulled mid-take: the microphone would record Spotify from here on.
            guard phase == .recording, synced, let route = try? TakeRecorder.recordingRoute(), !route.headphones else { return }
            finish(note: "Headphones disconnected. The partial take was saved.", score: false)
        }
        .onDisappear { abandon() }
        .navigationDestination(isPresented: Binding(get: { report != nil }, set: { if !$0 { report = nil } })) {
            if let report { ReportCardView(report: report, title: title, artist: artist) }
        }
    }

    private var isCounting: Bool {
        if case .countdown = phase { return true }
        return phase == .starting
    }

    private var intro: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                BackCircle()
                Text("Practice \(title)").font(.largeTitle.bold())
                Text("Use headphones so the microphone hears your instrument clearly.")
                    .font(.body).foregroundStyle(Palette.secondary)
                Toggle("Practice a section", isOn: $sectionOnly)
                if sectionOnly {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Start · \(mmss(sectionStart))").monospacedDigit()
                        Slider(value: $sectionStart, in: 0...max(0.1, songEnd - 1), step: 1)
                            .accessibilityLabel("Section start")
                            .onChange(of: sectionStart) { _, start in
                                sectionEnd = min(songEnd, max(start + 1, sectionEnd))
                            }
                        Text("End · \(mmss(sectionEnd))").monospacedDigit()
                        Slider(value: $sectionEnd, in: min(songEnd - 0.1, sectionStart + 1)...songEnd)
                            .accessibilityLabel("Section end")
                        Text("The recording stops at the end of this passage.")
                            .font(.footnote).foregroundStyle(Palette.secondary)
                    }
                }
                if let first = analysis.chords.first(where: { $0.start <= rangeStart && $0.end > rangeStart }),
                   first.label != "N" {
                    Text("Start on \(ChordMath.transpose(first.displayName, by: songStore.shift))")
                        .font(.title2.bold()).foregroundStyle(Color.spotifyGreen)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Practice pace").font(.headline)
                    Picker("Practice pace", selection: $rate) {
                        Text("50%").tag(0.5); Text("75%").tag(0.75); Text("100%").tag(1.0)
                    }.pickerStyle(.segmented)
                    Text("Slower practice uses the metronome; Spotify always plays at full speed.")
                        .font(.footnote).foregroundStyle(Palette.secondary)
                }
                if let note = songStore.editionNote {
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(Palette.warning)
                }
                Label(calibrationNote, systemImage: songStore.timingIsStale ? "exclamationmark.triangle" : "ear")
                    .font(.footnote).foregroundStyle(songStore.timingIsStale ? Palette.warning : Palette.secondary)
                if songStore.manualShift != 0 || songStore.capoMode {
                    Text("Sounding key shift: \(songStore.manualShift > 0 ? "+" : "")\(songStore.manualShift) semitones. \(songStore.capoMode ? "Use capo fret \(songStore.capo) with the displayed shapes." : "No capo.")")
                        .font(.subheadline)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        start(spotify: true)
                    } label: {
                        Label("Play from Spotify and record", systemImage: "play.fill").font(.headline)
                            .foregroundStyle(.black).frame(maxWidth: .infinity, minHeight: 52)
                            .background(Color.spotifyGreen.opacity(canSync ? 1 : 0.35), in: Capsule())
                    }.buttonStyle(.plain).disabled(!canSync)
                    Text(spotifyNote).font(.footnote).foregroundStyle(Palette.secondary)
                    Button {
                        start(spotify: false)
                    } label: {
                        Label(analysis.tempo == nil ? "Record without Spotify" : "Record with metronome",
                              systemImage: "metronome").font(.headline)
                            .foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 48)
                            .background(Palette.card, in: Capsule())
                    }.buttonStyle(.plain)
                    Text(metronomeNote).font(.footnote).foregroundStyle(Palette.secondary)
                }
                Text("Up to 10 minutes per take. Recordings stay on this device until you delete them; scoring uploads the selected take.")
                    .font(.footnote).foregroundStyle(Palette.secondary)
            }.padding(24)
        }
    }

    private var spotifyNote: String {
        guard canSync else { return "Spotify playback needs 100% pace and the original key." }
        let lead = min(3, rangeStart)
        return "Headphones required, so the microphone hears you and not the song. Spotify plays on this phone, not on another device. It starts \(lead > 0 ? "\(Int(lead)) seconds before " : "at ")\(mmss(rangeStart)); recording begins when the song reaches \(mmss(rangeStart)). Needs Spotify Premium. Pausing or seeking ends and saves the take."
    }

    private var metronomeNote: String {
        guard let grid else { return "Pause Spotify first. This chart has no beat grid, so the count-in is visual and there is no click." }
        let bpm = Int((60 / grid.period * rate).rounded())
        let bar = barStart < rangeStart ? " (the bar at \(mmss(barStart)))" : ""
        return "Pause Spotify first. Four clicks count in the bar before, then the take starts on beat 1 at \(mmss(barStart))\(bar), \(bpm) BPM, beat 1 accented."
    }

    private var recordingView: some View {
        LiveNowView(store: songStore, verdict: feedback.map { feedback in { feedback.verdict(startingAt: $0) } }) { position() }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    if let feedback {
                        HStack(spacing: 8) {
                            Image(systemName: "ear").font(.system(size: 12, weight: .semibold))
                            Text(lastJudged ?? "Listening for your chords…").lineLimit(1)
                            Spacer()
                            if !feedback.judged.isEmpty {
                                Text("\(feedback.hits)/\(feedback.judged.count)").monospacedDigit()
                            }
                        }
                        .font(.footnote).foregroundStyle(Palette.secondary)
                        .accessibilityIdentifier("live-feedback")
                    }
                    HStack {
                        Label(synced ? "Recording · Spotify on \(nowPlaying.playbackDevice ?? "phone")" : "Recording · \(Int(rate * 100))%", systemImage: "record.circle")
                            .font(.subheadline).foregroundStyle(Palette.destructive)
                        Spacer()
                        if !synced, let grid {
                            BeatDots(grid: grid) { position() }
                        }
                        Button("Finish take") { finish() }.buttonStyle(.borderedProminent).tint(.spotifyGreen)
                    }
                }.padding().background(Palette.card)
            }
    }

    private func start(spotify: Bool) {
        guard countIn == nil else { return }
        countIn = Task { await begin(spotify: spotify) }
    }

    /// Chart time for Spotify's current position on this track, or nil when
    /// Spotify is not playing it or its position is unknown.
    private func spotifyChartPosition() -> Double? {
        guard spotifyThisTrack?.isPlaying == true, let live = nowPlaying.livePosition() else { return nil }
        return songStore.timing.chartTime(live)
    }

    private func begin(spotify: Bool) async {
        defer { countIn = nil }
        guard songStore.canPractice, songStore.analysis == analysis else {
            phase = .failed("The song sheet is updating. Reopen it before starting a take."); return
        }
        if spotify {
            guard canSync else { phase = .failed("Spotify playback needs 100% pace and the original key."); return }
            let route: TakeRecorder.Route
            do { route = try TakeRecorder.recordingRoute() } catch {
                phase = .failed("The audio session could not start: \(error.localizedDescription)"); return
            }
            guard route.headphones else {
                phase = .failed("Connect headphones first. On the speaker the microphone records Spotify instead of your playing. Current output: \(route.outputs.joined(separator: ", "))."); return
            }
        } else {
            guard nowPlaying.playing?.isPlaying != true else {
                phase = .failed("Pause Spotify before practicing with the metronome."); return
            }
        }
        guard await recorder.requestPermission() else {
            phase = .failed("Enable microphone access for Chordlyze in Settings to record."); return
        }
        guard !Task.isCancelled else { return }
        do {
            // Microphone first, then Spotify: opening input later would
            // interrupt playback for a moment right as the take begins.
            try recorder.prime()
            let setup = try PracticePlan(start: spotify ? rangeStart : barStart, end: rangeEnd, rate: rate,
                transpose: songStore.manualShift, capo: songStore.capoMode ? songStore.capo : 0)
            let plan: PracticePlan
            if spotify {
                plan = try await startWithSpotify(setup)
            } else {
                if let grid {
                    // Count in the bar before the take at the song's own spacing,
                    // then click every beat of the range, beat 1 accented.
                    let period = grid.period / rate
                    let clicks = grid.clicks(from: setup.start, to: setup.end)
                    let recordAt = try metronome.start(countIn: BeatGrid.beatsPerBar, period: period,
                        beats: clicks.map { $0.offset / rate },
                        downbeats: Set(clicks.indices.filter { clicks[$0].downbeat }))
                    for n in [4, 3, 2, 1] {
                        phase = .countdown(n)
                        try await Task.sleep(until: recordAt - .seconds(Double(n - 1) * period), clock: .continuous)
                    }
                } else {
                    for n in [3, 2, 1] { phase = .countdown(n); try await Task.sleep(for: .seconds(1)) }
                }
                plan = setup
            }
            try Task.checkCancellation()
            let take = try takes.prepare(song: songStore.song, plan: plan)
            activeTake = take
            feedback = PracticeFeedback(chords: analysis.chords, start: plan.start, end: plan.end, transpose: plan.transpose)
            lastJudged = nil
            let tap = FeedbackTap { snapshot in judge(snapshot, plan: plan) }
            feedbackTap = tap
            try recorder.start(maxDuration: plan.recordingDuration, at: takes.audioURL(take)) { samples, sampleTime, sampleRate in
                tap.handle(samples, sampleTime: sampleTime, sampleRate: sampleRate)
            }
            startedAt = .now
            synced = spotify
            pausedSince = nil
            phase = .recording
        } catch is CancellationError {
            metronome.stop()
            _ = recorder.stop()
        } catch {
            metronome.stop()
            _ = recorder.stop()
            phase = .failed("Could not start: \(error.localizedDescription)")
        }
    }

    /// Starts Spotify a few seconds before the range so the player hears the
    /// lead-in, then waits until Spotify's reported position reaches the
    /// range. The take begins at the position Spotify actually reports.
    private func startWithSpotify(_ setup: PracticePlan) async throws -> PracticePlan {
        phase = .starting
        let lead = min(3, setup.start)
        try await nowPlaying.play(trackID: trackID, at: songStore.timing.spotifyTime(setup.start - lead))
        try Task.checkCancellation()
        while true {
            guard let position = spotifyChartPosition() else {
                throw NSError(domain: "Practice", code: 2, userInfo: [NSLocalizedDescriptionKey: "Spotify stopped before the recording started."])
            }
            if position >= setup.start { break }
            phase = .countdown(max(1, Int((setup.start - position).rounded(.up))))
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let start = spotifyChartPosition(), start < setup.end else {
            throw NSError(domain: "Practice", code: 3, userInfo: [NSLocalizedDescriptionKey: "Spotify is already past the end of this range."])
        }
        return try PracticePlan(start: start, end: setup.end, capo: setup.capo)
    }

    /// Every detector snapshot, in take order. The snapshot time is seconds
    /// of recorded audio, mapped through the plan like the backend does.
    private func judge(_ snapshot: DrillSnapshot, plan: PracticePlan) {
        guard phase == .recording, feedback != nil else { return }
        let chartTime = plan.position(elapsed: snapshot.time)
        if let index = feedback!.observe(current: snapshot.current, chartTime: chartTime) {
            let target = feedback!.targets[index]
            lastJudged = PracticeFeedback.describe(target, feedback!.verdicts[index]!)
        }
    }

    /// Chart position for the sheet while recording. A synced take shows
    /// Spotify's clock so the chart and the audio agree; during a connection
    /// loss it falls back to the take's own clock instead of freezing.
    private func position() -> Double? {
        guard let startedAt, let activeTake else { return nil }
        if synced, nowPlaying.connectionMessage == nil, let live = spotifyChartPosition() { return live + lead }
        return activeTake.plan.position(elapsed: startedAt.duration(to: .now).seconds) + (synced ? lead : 0)
    }

    private func tick() {
        guard phase == .recording, let startedAt, let activeTake else { return }
        let elapsed = startedAt.duration(to: .now).seconds
        if !recorder.isRecording || elapsed >= activeTake.plan.recordingDuration { finish(); return }
        guard synced, nowPlaying.connectionMessage == nil else { return }
        let reason: String
        if let playing = spotifyThisTrack, playing.isPlaying {
            pausedSince = nil
            guard let live = spotifyChartPosition(), abs(live - (activeTake.plan.start + elapsed)) > 2.5 else { return }
            reason = "Spotify moved to another position. The partial take was saved."
        } else if let playing = nowPlaying.playing, playing.track.id != trackID {
            reason = "Spotify changed songs. The partial take was saved."
        } else {
            // iOS pauses other audio for a moment on some route changes and
            // Spotify resumes on its own; only a real pause ends the take.
            let since = pausedSince ?? .now
            pausedSince = since
            guard since.duration(to: .now) > .seconds(3) else { return }
            reason = "Spotify paused. The partial take was saved."
        }
        finish(note: reason, score: false)
    }

    private func finish(note: String? = nil, score: Bool = true) {
        guard phase == .recording, let take = activeTake else { return }
        metronome.stop()
        _ = recorder.stop()
        feedbackTap?.cancel(); feedbackTap = nil
        do { try takes.finish(take, note: note) }
        catch { saveError = "The audio is saved, but its details could not be updated: \(error.localizedDescription)" }
        phase = score ? .uploading : .saved
        guard score else { return }
        Task {
            do { report = try await takes.score(savedTake ?? take) }
            catch { saveError = "Scoring failed. Your recording is saved; retry below. \(error.localizedDescription)" }
            phase = .saved
        }
    }

    private func abandon() {
        countIn?.cancel(); countIn = nil
        if isCounting { metronome.stop(); _ = recorder.stop(); feedbackTap?.cancel(); feedbackTap = nil; phase = .intro }
        if phase == .recording { finish(note: "You left during recording. The partial take was saved.", score: false) }
    }
}

/// Bridges the recorder's sample stream to the chord detector. The detector
/// needs the microphone's sample rate, known only once audio flows, so the
/// worker is created on the first buffer.
private final class FeedbackTap: @unchecked Sendable {
    private let lock = NSLock()
    private var worker: DrillAudioWorker?
    private var failed = false
    private let onSnapshot: @MainActor @Sendable (DrillSnapshot) -> Void

    init(onSnapshot: @escaping @MainActor @Sendable (DrillSnapshot) -> Void) {
        self.onSnapshot = onSnapshot
    }

    func handle(_ samples: UnsafeBufferPointer<Float>, sampleTime: Int64, sampleRate: Double) {
        lock.lock()
        if worker == nil, !failed {
            do { worker = DrillAudioWorker(detector: try ChordDrillDetector(sampleRate: sampleRate), onSnapshot: onSnapshot) }
            catch { failed = true }
        }
        let worker = worker
        lock.unlock()
        worker?.offer(samples, sampleTime: sampleTime)
    }

    func cancel() {
        lock.lock(); let worker = worker; failed = true; lock.unlock()
        worker?.cancel()
    }
}

/// Where the bar is right now: four dots, the current beat lit, beat 1 larger.
struct BeatDots: View {
    let grid: BeatGrid
    let position: () -> Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { _ in
            let current = position().flatMap { grid.beatInBar(at: $0) }
            HStack(spacing: 6) {
                ForEach(1...BeatGrid.beatsPerBar, id: \.self) { beat in
                    Circle()
                        .fill(beat == current ? Color.spotifyGreen : Palette.faint)
                        .frame(width: beat == 1 ? 10 : 7, height: beat == 1 ? 10 : 7)
                }
            }
            .accessibilityLabel(current.map { "Beat \($0)" } ?? "Waiting for the first beat")
        }
        .padding(.trailing, 6)
    }
}
