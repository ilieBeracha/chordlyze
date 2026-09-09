import AVFoundation
import SwiftUI
import AVKit

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

    private enum Phase: Equatable { case intro, starting, countdown(Int), recording, uploading, saved, failed(String) }
    @State private var phase: Phase = .intro
    @State private var needsSpotifyDevice = false
    @State private var automaticallyOpenSpotify = false
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
    /// The metronome follows the chart at the chosen pace, without the song.
    @State private var slower = false
    @State private var recordTake = true
    @State private var activePlan: PracticePlan?
    @State private var showPassage = false
    @State private var showDetails = false
    @State private var audioChecked = false
    @State private var audioMessage: String?
    @State private var audioCheck: Task<Void, Never>?
    @State private var outputName = "Check audio output"
    @State private var inputName = "Check microphone"
    @State private var outputReady = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var initialized = false
    @State private var saveError: String?
    @State private var pausedSince: ContinuousClock.Instant?
    @State private var feedback: PracticeFeedback?
    @State private var feedbackTap: FeedbackTap?
    @State private var lastJudged: String?
    @State private var liveSnapshot: DrillSnapshot?
    @State private var feedbackError: String?

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
    private var timingSummary: String {
        songStore.timingIsStale ? "Needs rechecking" : songStore.timingNote == nil ? "Not checked" : "Calibrated"
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
                    ProgressView(nowPlaying.playbackDevice.map { "Waiting for Spotify on \($0)…" } ?? "Finding Spotify on this phone…").tint(.white)
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
                ScrollView {
                    VStack(spacing: 18) {
                        Text(message).multilineTextAlignment(.center)
                        if needsSpotifyDevice {
                            SpotifyDeviceRecoveryView(nowPlaying: nowPlaying, trackID: trackID, retryTitle: "Start practice",
                                                      automaticallyOpen: automaticallyOpenSpotify) {
                                start(spotify: true, allowWake: false)
                            }
                        }
                        Button("Back to setup") { phase = .intro }.frame(minHeight: 44)
                        BackCircle()
                    }.padding(24)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .environment(\.nativeBackSwipeEnabled, !isCounting && phase != .recording)
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
            refreshAudioRoute()
            guard phase == .recording, recordTake, synced, let route = try? TakeRecorder.recordingRoute(), !route.headphones else { return }
            finish(note: "Headphones disconnected. The partial take was saved.", score: false)
        }
        .onDisappear { abandon() }
        .onChange(of: scenePhase) { _, value in
            if value != .active, phase == .intro { stopAudioCheck() }
            if value == .active { refreshAudioRoute() }
        }
        .onChange(of: recordTake) { _, value in
            if !value { stopAudioCheck() }
        }
        .task(id: phase == .intro) {
            if phase == .intro { refreshAudioRoute() }
        }
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
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Song")
                    Text(title).font(.system(.title, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                    if !artist.isEmpty { Text(artist).font(.subheadline).foregroundStyle(Palette.secondaryAlt) }
                    Label("Spotify", systemImage: "music.note").font(.subheadline.weight(.semibold)).foregroundStyle(Color.spotifyGreen)
                }.padding(.top, 4)
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Practice mode")
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(spacing: 4) {
                                modeButton("Spotify", icon: "music.note", metronome: false)
                                modeButton("Metronome", icon: "metronome", metronome: true)
                            }
                        } else {
                            HStack(spacing: 4) {
                                modeButton("Spotify", icon: "music.note", metronome: false)
                                modeButton("Metronome", icon: "metronome", metronome: true)
                            }
                        }
                    }.padding(4).background(Palette.card, in: RoundedRectangle(cornerRadius: 14))

                    if slower {
                        Picker("Practice pace", selection: $rate) {
                            Text("50%").tag(0.5); Text("75%").tag(0.75); Text("100%").tag(1.0)
                        }.pickerStyle(.segmented)
                        Text(grid == nil ? "Visual count-in · no beat grid available" : "Metronome · \(Int((60 / grid!.period * rate).rounded())) BPM")
                            .font(.footnote).foregroundStyle(Palette.secondaryAlt)
                    }
                }
                VStack(spacing: 0) {
                    Button { showPassage = true } label: {
                        setupRow("Passage", subtitle: sectionOnly ? "\(mmss(rangeStart)) – \(mmss(rangeEnd))" : "Whole song", icon: "music.note") {
                            Image(systemName: "chevron.right").foregroundStyle(Palette.secondaryAlt)
                        }
                    }.buttonStyle(.plain).accessibilityIdentifier("practice-passage")
                    Divider().overlay(Palette.separator)
                    HStack(spacing: 14) {
                        setupIcon("record.circle")
                        Toggle("Record this take", isOn: $recordTake).tint(.spotifyGreen)
                            .accessibilityIdentifier("practice-record-toggle")
                    }.padding(.vertical, 12)
                    Divider().overlay(Palette.separator)
                }
                if recordTake {
                    VStack(alignment: .leading, spacing: 0) {
                        SectionLabel("Audio").padding(.bottom, 8)
                        setupRow("Output", subtitle: outputName, icon: "headphones") {
                            HStack(spacing: 10) {
                                if audioChecked && (outputReady || slower) { readyMark }
                                PracticeRoutePicker().frame(width: 44, height: 44)
                            }
                        }
                        Divider().overlay(Palette.separator)
                        setupRow("Input", subtitle: inputName, icon: "mic") {
                            Button(audioCheck != nil ? "Checking…" : audioChecked ? "Stop" : "Check") {
                                if audioChecked { stopAudioCheck() } else { checkAudio() }
                            }.font(.subheadline.weight(.semibold)).foregroundStyle(Color.spotifyGreen)
                                .disabled(audioCheck != nil).frame(minWidth: 44, minHeight: 44)
                                .accessibilityLabel(audioChecked ? "Stop microphone check" : "Check microphone")
                                .accessibilityIdentifier("practice-check-audio")
                        }
                        if audioChecked {
                            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                                HStack(spacing: 4) {
                                    ForEach(0..<24, id: \.self) { index in
                                        Capsule().fill(Double(index) / 24 < recorder.inputLevel ? Color.spotifyGreen : Palette.gray5)
                                            .frame(maxWidth: .infinity).frame(height: 8)
                                    }
                                }.accessibilityElement(children: .ignore)
                                    .accessibilityLabel("Microphone input level")
                                    .accessibilityValue("\(Int(recorder.inputLevel * 100)) percent")
                            }.padding(.leading, 54).padding(.bottom, 12)
                        }
                        if let audioMessage {
                            Text(audioMessage).font(.footnote).foregroundStyle(Palette.warning).padding(.top, 4)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Timing")
                    NavigationLink {
                        AutomaticSyncView(store: songStore, nowPlaying: nowPlaying)
                            .toolbar(.visible, for: .navigationBar)
                    } label: {
                        setupRow("Timing", subtitle: timingSummary, icon: "clock") {
                            Text("Check timing").font(.subheadline).foregroundStyle(Color.spotifyGreen)
                            Image(systemName: "chevron.right").foregroundStyle(Palette.secondaryAlt)
                        }
                    }.buttonStyle(.plain).accessibilityIdentifier("practice-check-timing")
                }
                if let note = songStore.editionNote {
                    Label(note, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Palette.warning)
                }
                if !slower && !canSync {
                    Text("Spotify needs the original key. Reset transpose in Song settings, or choose Metronome.")
                        .font(.footnote).foregroundStyle(Palette.warning)
                }
                DisclosureGroup("Recording details", isExpanded: $showDetails) {
                    Text(recordTake ? "Up to 10 minutes per take. Recordings stay on this iPhone until you delete them. Finishing a take uploads it for scoring. Spotify requires Premium; pausing or seeking ends and saves the take." : "Follow the chart without recording or scoring. Spotify requires Premium. Metronome mode plays clicks without the song.")
                        .font(.footnote).foregroundStyle(Palette.secondaryAlt).padding(.top, 6)
                }.font(.footnote).tint(Palette.secondaryAlt)
            }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 20)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ZStack {
                Text("Practice").font(.headline)
                HStack { BackCircle(); Spacer() }
            }.frame(minHeight: 44).padding(.horizontal, 24).padding(.vertical, 8).background(.black)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) {
                Button { start(spotify: !slower) } label: {
                    Label("Start practice", systemImage: "play.fill")
                        .font(.headline).foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(Color.spotifyGreen, in: Capsule())
                }.buttonStyle(.plain).disabled((!slower && !canSync) || audioCheck != nil || countIn != nil)
                    .opacity((!slower && !canSync) ? 0.4 : 1)
                    .accessibilityIdentifier("practice-start")
                Label(recordTake ? "Saved on this iPhone · uploaded for scoring" : "No recording · just play along", systemImage: recordTake ? "iphone" : "music.note")
                    .font(.caption).foregroundStyle(Palette.secondaryAlt).multilineTextAlignment(.center)
            }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 8).background(.black)
        }
        .sheet(isPresented: $showPassage) { passageEditor }
    }

    private func modeButton(_ title: String, icon: String, metronome: Bool) -> some View {
        Button {
            slower = metronome; rate = metronome ? 0.75 : 1
            audioMessage = nil
        } label: {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
                .foregroundStyle(slower == metronome ? Color.spotifyGreen : .white)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(slower == metronome ? Palette.gray5 : .clear, in: RoundedRectangle(cornerRadius: 11))
        }.buttonStyle(.plain)
            .accessibilityAddTraits(slower == metronome ? .isSelected : [])
            .accessibilityIdentifier(metronome ? "practice-mode-metronome" : "practice-mode-spotify")
    }

    private var readyMark: some View {
        Image(systemName: "checkmark.circle").foregroundStyle(Color.spotifyGreen).accessibilityLabel("Ready")
    }

    private func setupIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 20)).foregroundStyle(.white)
            .frame(width: 40, height: 40).background(Palette.card, in: Circle()).accessibilityHidden(true)
    }

    private func setupRow<T: View>(_ name: String, subtitle: String, icon: String, @ViewBuilder trailing: () -> T) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                setupIcon(icon)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.body)
                    Text(subtitle).font(.subheadline).foregroundStyle(Palette.secondaryAlt)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if !dynamicTypeSize.isAccessibilitySize { trailing() }
            }
            if dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: 8) { trailing(); Spacer(minLength: 0) }.padding(.leading, 54)
            }
        }.foregroundStyle(.white).frame(minHeight: 52).padding(.vertical, 8)
    }

    private var passageEditor: some View {
        NavigationStack {
            Form {
                Toggle("Practice a section", isOn: $sectionOnly)
                if sectionOnly {
                    Section("Passage") {
                        Text("Start · \(mmss(sectionStart))").monospacedDigit()
                        Slider(value: $sectionStart, in: 0...max(0.1, songEnd - 1), step: 1)
                            .accessibilityLabel("Section start")
                            .onChange(of: sectionStart) { _, start in sectionEnd = min(songEnd, max(start + 1, sectionEnd)) }
                        Text("End · \(mmss(sectionEnd))").monospacedDigit()
                        Slider(value: $sectionEnd, in: min(songEnd - 0.1, sectionStart + 1)...songEnd)
                            .accessibilityLabel("Section end")
                        Text("Practice stops at the end of this passage.").font(.footnote)
                    }
                }
            }.navigationTitle("Passage").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showPassage = false } } }
        }.preferredColorScheme(.dark).presentationDetents([.medium, .large])
    }

    private func refreshAudioRoute() {
        let route = AVAudioSession.sharedInstance().currentRoute
        outputName = route.outputs.map { $0.portType == .builtInSpeaker ? "iPhone speaker" : $0.portName }.joined(separator: ", ")
        if outputName.isEmpty { outputName = "Not connected" }
        outputReady = !route.outputs.isEmpty && route.outputs.allSatisfy { $0.portType != .builtInSpeaker && $0.portType != .builtInReceiver }
        inputName = audioChecked ? route.inputs.map { $0.portType == .builtInMic ? "iPhone microphone" : $0.portName }.joined(separator: ", ") : "Check microphone"
        if audioChecked && inputName.isEmpty { inputName = "Microphone unavailable" }
    }

    private func checkAudio() {
        guard audioCheck == nil else { return }
        audioMessage = nil
        audioCheck = Task { @MainActor in
            defer { audioCheck = nil }
            guard await recorder.requestPermission() else {
                audioMessage = "Allow microphone access in Settings to record."; return
            }
            guard !Task.isCancelled, phase == .intro, recordTake else { return }
            do {
                try recorder.prime()
                audioChecked = true
                refreshAudioRoute()
                if !slower && !outputReady { audioMessage = "Connect headphones before recording with Spotify." }
            } catch { audioMessage = error.localizedDescription; _ = recorder.stop() }
        }
    }

    private func stopAudioCheck() {
        audioCheck?.cancel()
        if audioChecked { _ = recorder.stop() }
        audioChecked = false
        audioMessage = nil
        refreshAudioRoute()
    }

    private var recordingView: some View {
        LiveNowView(store: songStore, verdict: feedback.map { feedback in { feedback.verdict(startingAt: $0) } },
                    allowsSimpleVersionChanges: false) { position() }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    if let feedback {
                        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                            PracticeListeningPanel(
                                expected: feedback.targets.first { $0.start <= (position() ?? 0) && (position() ?? 0) < $0.end }?.name,
                                snapshot: liveSnapshot, inputLevel: recorder.inputLevel,
                                lastJudged: lastJudged, error: feedbackError, capo: activePlan?.capo ?? 0)
                        }
                    }
                    (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                     : AnyLayout(HStackLayout())) {
                        Label(!recordTake ? "Playing along" : synced ? "Recording · Spotify on \(nowPlaying.playbackDevice ?? "phone")" : "Recording · \(Int(rate * 100))%", systemImage: "record.circle")
                            .font(.subheadline).foregroundStyle(Palette.destructive)
                        Spacer()
                        if !synced, let grid {
                            BeatDots(grid: grid) { position() }
                        }
                        Button(recordTake ? "Finish take" : "Finish practice") { finish() }
                            .buttonStyle(.borderedProminent).tint(.spotifyGreen).foregroundStyle(.black)
                    }
                }.padding().background(Palette.card)
            }
    }

    private func start(spotify: Bool, allowWake: Bool = true) {
        guard countIn == nil else { return }
        needsSpotifyDevice = false
        automaticallyOpenSpotify = allowWake
        feedback = nil; feedbackTap?.cancel(); feedbackTap = nil
        activePlan = nil; activeTake = nil
        phase = .starting
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
        } else {
            guard nowPlaying.playing?.isPlaying != true else {
                phase = .failed("Pause Spotify before practicing with the metronome."); return
            }
        }
        if recordTake {
            guard await recorder.requestPermission() else {
                phase = .failed("Enable microphone access for Chordlyze in Settings to record."); return
            }
        }
        guard !Task.isCancelled else { return }
        do {
            // Microphone first, then Spotify: opening input later would
            // interrupt playback for a moment right as the take begins.
            if recordTake {
                try recorder.prime()
                if spotify {
                    let route = try TakeRecorder.recordingRoute()
                    guard route.headphones else {
                        _ = recorder.stop(); audioChecked = false
                        throw NSError(domain: "Practice", code: 5, userInfo: [NSLocalizedDescriptionKey: "Connect headphones to record with Spotify. Current output: \(route.outputs.joined(separator: ", ")). You can also turn off Record this take to play along."])
                    }
                }
            }
            let setup = try PracticePlan(start: spotify ? rangeStart : barStart, end: rangeEnd, rate: rate,
                transpose: songStore.manualShift, capo: songStore.capoMode ? songStore.capo : 0,
                timingScale: spotify ? songStore.timing.scale : 1, chartRevision: songStore.analysis?.chartRevision, limitRecordingDuration: recordTake)
            let plan: PracticePlan
            if spotify {
                plan = try await startWithSpotify(setup)
            } else {
                if let grid {
                    // Count in the bar before the take at the song's own spacing,
                    // then click every beat of the range, beat 1 accented.
                    let period = grid.period(at: setup.start) / rate
                    let countIn = grid.beatsInBar(at: setup.start)
                    let clicks = grid.clicks(from: setup.start, to: setup.end)
                    let recordAt = try metronome.start(countIn: countIn, period: period,
                        beats: clicks.map { $0.offset / rate },
                        downbeats: Set(clicks.indices.filter { clicks[$0].downbeat }), recording: recordTake)
                    for n in stride(from: countIn, through: 1, by: -1) {
                        phase = .countdown(n)
                        try await Task.sleep(until: recordAt - .seconds(Double(n - 1) * period), clock: .continuous)
                    }
                } else {
                    for n in [3, 2, 1] { phase = .countdown(n); try await Task.sleep(for: .seconds(1)) }
                }
                plan = setup
            }
            try Task.checkCancellation()
            activePlan = plan
            if recordTake {
                let take = try takes.prepare(song: songStore.song, plan: plan)
                activeTake = take
                feedback = PracticeFeedback(analysis: analysis, start: plan.start, end: plan.end, transpose: plan.transpose)
                lastJudged = nil
                liveSnapshot = nil
                feedbackError = nil
                let tap = FeedbackTap(onSnapshot: { snapshot in judge(snapshot, plan: plan) }, onFailure: {
                    guard phase == .recording else { return }
                    liveSnapshot = nil
                    feedbackError = "Live detection unavailable. Your take is still recording."
                })
                feedbackTap = tap
                try recorder.start(maxDuration: plan.recordingDuration, at: takes.audioURL(take)) { samples, sampleTime, sampleRate in
                    tap.handle(samples, sampleTime: sampleTime, sampleRate: sampleRate)
                }
            }
            startedAt = .now
            synced = spotify
            pausedSince = nil
            phase = .recording
        } catch is CancellationError {
            metronome.stop()
            _ = recorder.stop()
            audioChecked = false
        } catch {
            metronome.stop()
            _ = recorder.stop()
            audioChecked = false
            needsSpotifyDevice = (error as? SpotifyNowPlaying.PlayError)?.needsDeviceRecovery == true
            automaticallyOpenSpotify = automaticallyOpenSpotify && (error as? SpotifyNowPlaying.PlayError)?.canWakeApp == true
            phase = .failed(automaticallyOpenSpotify ? "Connecting to Spotify" : "Could not start: \(error.localizedDescription)")
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
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while true {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline, nowPlaying.connectionMessage == nil, !nowPlaying.needsReauth else {
                throw NSError(domain: "Practice", code: 4, userInfo: [NSLocalizedDescriptionKey: "Lost Spotify playback before the take. Try starting again."])
            }
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
        return try PracticePlan(start: start, end: setup.end, capo: setup.capo, timingScale: setup.timingScale ?? 1, chartRevision: setup.chartRevision, limitRecordingDuration: recordTake)
    }

    /// Every detector snapshot, in take order. The snapshot time is seconds
    /// of recorded audio, mapped through the plan like the backend does.
    private func judge(_ snapshot: DrillSnapshot, plan: PracticePlan) {
        guard phase == .recording, feedback != nil else { return }
        if liveSnapshot?.evidence != snapshot.evidence || liveSnapshot?.current != snapshot.current {
            liveSnapshot = snapshot
        }
        let chartTime = plan.position(elapsed: snapshot.time)
        if let index = feedback!.observe(current: snapshot.current, chartTime: chartTime, chartRate: plan.chartRate,
                                         recognizedAt: snapshot.recognizedAt.map { plan.position(elapsed: $0) },
                                         detectorLatency: snapshot.latency) {
            let target = feedback!.targets[index]
            lastJudged = PracticeFeedback.describe(target, feedback!.verdicts[index]!)
        }
    }

    /// Calibrated chart position for the sheet while recording, without the
    /// display lead (the sheet adds it for chords only). A synced take shows
    /// Spotify's clock so the chart and the audio agree; during a connection
    /// loss it falls back to the take's own clock instead of freezing.
    private func position() -> Double? {
        guard let startedAt, let activePlan else { return nil }
        if synced, nowPlaying.connectionMessage == nil, let live = spotifyChartPosition() { return live }
        return activePlan.position(elapsed: startedAt.duration(to: .now).seconds)
    }

    private func tick() {
        guard phase == .recording, let startedAt, let activePlan else { return }
        let elapsed = startedAt.duration(to: .now).seconds
        if (recordTake && !recorder.isRecording) || elapsed >= (recordTake ? activePlan.recordingDuration : (activePlan.end - activePlan.start) / activePlan.chartRate) { finish(); return }
        guard synced, nowPlaying.connectionMessage == nil else { return }
        let reason: String
        if let playing = spotifyThisTrack, playing.isPlaying {
            pausedSince = nil
            guard let live = spotifyChartPosition(), abs(live - activePlan.position(elapsed: elapsed)) > 2.5 else { return }
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
        guard phase == .recording else { return }
        if !recordTake {
            metronome.stop(); activePlan = nil; startedAt = nil; phase = .intro
            return
        }
        guard let take = activeTake else { return }
        metronome.stop()
        _ = recorder.stop()
        audioChecked = false
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
        audioCheck?.cancel()
        if phase != .recording { stopAudioCheck() }
        countIn?.cancel(); countIn = nil
        if isCounting { metronome.stop(); _ = recorder.stop(); audioChecked = false; feedbackTap?.cancel(); feedbackTap = nil; phase = .intro }
        if phase == .recording { finish(note: "You left during recording. The partial take was saved.", score: false) }
    }
}

/// Shows current evidence separately from the most recent chart judgment.
struct PracticeListeningPanel: View {
    let expected: String?
    let snapshot: DrillSnapshot?
    let inputLevel: Double
    let lastJudged: String?
    let error: String?
    var capo: Int = 0
    @Environment(\.dynamicTypeSize) private var typeSize

    private var matchesExpected: Bool {
        guard let heard = snapshot?.current.flatMap(Chord.init(display:)),
              let expected = expected.flatMap(Chord.init(display:)),
              let mask = PracticeFeedback.mask(heard) else { return false }
        return mask == PracticeFeedback.mask(expected)
    }

    private var status: String {
        if let error { return error }
        if snapshot?.current != nil { return matchesExpected ? "Matches the chart" : "Chord recognized" }
        switch snapshot?.evidence {
        case .chord: return "Confirming chord…"
        case .uncertain: return "Sound received · finding the chord"
        default: return "Listening for your next chord"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
             : AnyLayout(HStackLayout(spacing: 20))) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(capo > 0 ? "Sounding" : "Chart").foregroundStyle(Palette.secondaryAlt)
                    Text(expected ?? "—").font(.title3.bold())
                }.accessibilityElement(children: .combine)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Heard").foregroundStyle(Palette.secondaryAlt)
                    Text(snapshot?.current ?? "—").font(.title3.bold())
                        .foregroundStyle(snapshot?.current == nil ? Palette.secondaryAlt : matchesExpected ? Color.spotifyGreen : .white)
                }.accessibilityElement(children: .combine)
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill").foregroundStyle(Palette.secondaryAlt)
                    ProgressView(value: inputLevel).tint(.spotifyGreen).frame(width: 48)
                }.accessibilityElement(children: .ignore)
                    .accessibilityLabel("Microphone input")
                    .accessibilityValue("\(Int(inputLevel * 100)) percent")
            }
            Text(status).foregroundStyle(error == nil ? Palette.secondaryAlt : Palette.warning)
            if error == nil, let lastJudged {
                Text("Last check: \(lastJudged)").foregroundStyle(Palette.secondaryAlt)
            }
        }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("live-feedback")
    }
}

#if DEBUG
/// Pure display fixtures: no microphone, Spotify playback, or real takes.
struct PracticeListeningPreview: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                MusicHeader(title: "Live feedback", subtitle: "Display preview · sample states")
                sample("Listening", snapshot: nil, level: 0)
                sample("Finding a chord", snapshot: .init(time: 1, evidence: .uncertain, current: nil, changes: 0), level: 0.28)
                sample("Recognized", snapshot: .init(time: 2, evidence: .chord("Am"), current: "Am", changes: 0), level: 0.45,
                       result: "Am matched · near chart change")
                sample("Detection interrupted", snapshot: nil, level: 0.3,
                       error: "Live detection unavailable. Your take is still recording.")
            }.padding(24)
        }.modifier(MusicSurface())
    }
    private func sample(_ title: String, snapshot: DrillSnapshot?, level: Double, result: String? = nil, error: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(title)
            PracticeListeningPanel(expected: "Am", snapshot: snapshot, inputLevel: level, lastJudged: result, error: error)
                .padding(16).background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}
#endif

/// Bridges recorded samples to the detector, using the input's actual sample rate.
private final class FeedbackTap: @unchecked Sendable {
    private let lock = NSLock()
    private var worker: DrillAudioWorker?
    private var failed = false
    private let onSnapshot: @MainActor @Sendable (DrillSnapshot) -> Void
    private let onFailure: @MainActor @Sendable () -> Void

    init(onSnapshot: @escaping @MainActor @Sendable (DrillSnapshot) -> Void,
         onFailure: @escaping @MainActor @Sendable () -> Void) {
        self.onSnapshot = onSnapshot
        self.onFailure = onFailure
    }

    func handle(_ samples: UnsafeBufferPointer<Float>, sampleTime: Int64, sampleRate: Double) {
        lock.lock()
        if worker == nil, !failed {
            do {
                // Use the same stable, full-vocabulary recognition as the live
                // chord tool; transition mixtures must not become wrong verdicts.
                worker = DrillAudioWorker(detector: try ChordDrillDetector(sampleRate: sampleRate, mode: .practiceFeedback),
                                          onSnapshot: onSnapshot, onFailure: onFailure)
            } catch {
                failed = true
                DispatchQueue.main.async(execute: onFailure)
            }
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

/// The current bar's detected beat count; legacy charts retain four dots.
struct BeatDots: View {
    let grid: BeatGrid
    let position: () -> Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { _ in
            let current = position().flatMap { grid.beatInBar(at: $0) }
            HStack(spacing: 6) {
                ForEach(1...grid.beatsInBar(at: position() ?? 0), id: \.self) { beat in
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

/// Uses the system route control; no app-maintained list of Bluetooth devices.
private struct PracticeRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView(frame: .zero)
        view.prioritizesVideoDevices = false
        view.tintColor = UIColor(Color.spotifyGreen)
        view.accessibilityLabel = "Change audio output"
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
