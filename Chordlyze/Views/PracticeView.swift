import SwiftUI

/// Practice in song time; capture and scoring retain the exact key, range and
/// pace chosen at record start. Completed and interrupted audio stays on disk.
struct PracticeView: View {
    let analysis: ChordAnalysis
    let title: String
    let artist: String
    var album: String? = nil
    let trackID: String
    @ObservedObject var songStore: SongSheetStore
    var initialRange: ClosedRange<Double>? = nil

    private enum Phase: Equatable { case intro, countdown(Int), recording, uploading, saved, failed(String) }
    @State private var phase: Phase = .intro
    @State private var recorder = TakeRecorder()
    @State private var metronome = Metronome()
    @ObservedObject private var nowPlaying = SpotifyNowPlaying.shared
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
    @State private var useSpotify = false
    @State private var initialized = false
    @State private var saveError: String?

    private var songEnd: Double { max(1, analysis.coverageEnd) }
    private var spotifyThisTrack: SpotifyNowPlaying.Playing? {
        guard let playing = nowPlaying.playing, playing.track.id == trackID else { return nil }
        return playing
    }
    private var canSync: Bool { !sectionOnly && rate == 1 && songStore.manualShift == 0 }
    private var savedTake: PracticeTake? {
        activeTake.flatMap { active in takes.takes.first { $0.id == active.id } ?? active }
    }

    var body: some View {
        Group {
            switch phase {
            case .intro: intro
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
            useSpotify = !sectionOnly && canSync && spotifyThisTrack?.isPlaying == true
        }
        .onChange(of: canSync) { _, allowed in if !allowed { useSpotify = false } }
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
        .onDisappear { abandon() }
        .navigationDestination(isPresented: Binding(get: { report != nil }, set: { if !$0 { report = nil } })) {
            if let report { ReportCardView(report: report, title: title, artist: artist) }
        }
    }

    private var isCounting: Bool { if case .countdown = phase { return true }; return false }

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
                if let first = analysis.chords.first(where: {
                    $0.start <= (sectionOnly ? sectionStart : 0) && $0.end > (sectionOnly ? sectionStart : 0)
                }), first.label != "N", !useSpotify {
                    Text("Start on \(ChordMath.transpose(first.displayName, by: songStore.shift))")
                        .font(.title2.bold()).foregroundStyle(Color.spotifyGreen)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Practice pace").font(.headline)
                    Picker("Practice pace", selection: $rate) {
                        Text("50%").tag(0.5); Text("75%").tag(0.75); Text("100%").tag(1.0)
                    }.pickerStyle(.segmented)
                    Text("Slower practice changes the metronome and chord timing. Spotify audio stays at its original speed.")
                        .font(.footnote).foregroundStyle(Palette.secondary)
                }
                if canSync {
                    Toggle("Follow Spotify playback", isOn: $useSpotify)
                }
                Text(setupNote).font(.subheadline).foregroundStyle(Palette.secondary)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 14))
                if songStore.manualShift != 0 || songStore.capoMode {
                    Text("Sounding key shift: \(songStore.manualShift > 0 ? "+" : "")\(songStore.manualShift) semitones. \(songStore.capoMode ? "Use capo fret \(songStore.capo) with the displayed shapes." : "No capo.")")
                        .font(.subheadline)
                }
                Button {
                    guard countIn == nil else { return }
                    countIn = Task { await begin() }
                } label: {
                    Text(sectionOnly ? "Start section" : "Start recording").font(.headline)
                        .foregroundStyle(.black).frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color.spotifyGreen, in: Capsule())
                }.buttonStyle(.plain)
                Text("Up to 10 minutes per take. Recordings stay on this device until you delete them; scoring uploads the selected take.")
                    .font(.footnote).foregroundStyle(Palette.secondary)
            }.padding(24)
        }
    }

    private var setupNote: String {
        if useSpotify {
            return "Start Spotify on this song first. Recording follows its current position after a three-second count-in. Pausing or seeking ends and saves the take."
        }
        let bpm = analysis.tempo.map { " at \(Int(($0.bpm * rate).rounded())) BPM" } ?? ""
        return "Pause Spotify before starting. After the count-in, play from \(mmss(sectionOnly ? sectionStart : 0))\(bpm).\(analysis.tempo == nil ? " This chart has no beat grid, so the count-in is visual." : "")"
    }

    private var recordingView: some View {
        LiveNowView(store: songStore) { position() }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Label(synced ? "Recording · Spotify" : "Recording · \(Int(rate * 100))%", systemImage: "record.circle")
                        .font(.subheadline).foregroundStyle(Palette.destructive)
                    Spacer()
                    Button("Finish take") { finish() }.buttonStyle(.borderedProminent).tint(.spotifyGreen)
                }.padding().background(Palette.card)
            }
    }

    private func begin() async {
        defer { countIn = nil }
        guard songStore.canPractice, songStore.analysis == analysis else {
            phase = .failed("The song sheet is updating. Reopen it before starting a take."); return
        }
        guard useSpotify ? (canSync && spotifyThisTrack?.isPlaying == true) : nowPlaying.playing?.isPlaying != true else {
            phase = .failed(useSpotify ? "Play this song in Spotify before starting." : "Pause Spotify before practicing with the metronome."); return
        }
        guard await recorder.requestPermission() else {
            phase = .failed("Enable microphone access for Chordlyze in Settings to record."); return
        }
        guard !Task.isCancelled else { return }
        do {
            let start = sectionOnly ? sectionStart : 0
            let end = sectionOnly ? sectionEnd : songEnd
            let setup = try PracticePlan(start: start, end: end, rate: rate,
                transpose: songStore.manualShift, capo: songStore.capoMode ? songStore.capo : 0)
            if !useSpotify, let tempo = analysis.tempo, tempo.bpm > 0 {
                let period = 60 / (tempo.bpm * rate)
                let recordAt = try metronome.start(countIn: 4, period: period, beats: setup.beats(tempo.beats))
                for n in [4, 3, 2, 1] {
                    phase = .countdown(n)
                    try await Task.sleep(until: recordAt - .seconds(Double(n - 1) * period), clock: .continuous)
                }
            } else {
                for n in [3, 2, 1] { phase = .countdown(n); try await Task.sleep(for: .seconds(1)) }
            }
            try Task.checkCancellation()
            let plan: PracticePlan
            if useSpotify {
                guard canSync, spotifyThisTrack?.isPlaying == true, let live = nowPlaying.livePosition(), live < songEnd else {
                    throw NSError(domain: "Practice", code: 1, userInfo: [NSLocalizedDescriptionKey: "Spotify playback changed during the count-in. Start again."])
                }
                plan = try PracticePlan(start: live, end: songEnd, capo: setup.capo)
            } else { plan = setup }
            let take = try takes.prepare(song: songStore.song, plan: plan)
            activeTake = take
            try recorder.start(maxDuration: plan.recordingDuration, at: takes.audioURL(take))
            startedAt = .now
            synced = useSpotify
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

    private func position() -> Double? {
        guard let startedAt, let activeTake else { return nil }
        // The captured clock remains continuous even when a playback poll jumps.
        return activeTake.plan.position(elapsed: startedAt.duration(to: .now).seconds)
    }

    private func tick() {
        guard phase == .recording, let startedAt, let activeTake else { return }
        let elapsed = startedAt.duration(to: .now).seconds
        if !recorder.isRecording || elapsed >= activeTake.plan.recordingDuration { finish(); return }
        guard synced else { return }
        let reason: String
        if let playing = spotifyThisTrack, playing.isPlaying {
            guard let live = nowPlaying.livePosition(), abs(live - (activeTake.plan.start + elapsed)) > 2.5 else { return }
            reason = "Spotify moved to another position. The partial take was saved."
        } else {
            reason = "Spotify paused or changed songs. The partial take was saved."
        }
        finish(note: reason, score: false)
    }

    private func finish(note: String? = nil, score: Bool = true) {
        guard phase == .recording, let take = activeTake else { return }
        metronome.stop()
        _ = recorder.stop()
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
        if isCounting { metronome.stop(); _ = recorder.stop(); phase = .intro }
        if phase == .recording { finish(note: "You left during recording. The partial take was saved.", score: false) }
    }
}
