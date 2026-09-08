import AVFoundation
import SwiftUI

struct PracticeHubView: View {
    @ObservedObject private var takes = PracticeTakeStore.shared
    @State private var firstChord = "C"
    @State private var secondChord = "G"
    private let chords = ["C", "D", "Dm", "E", "Em", "F", "G", "A", "Am", "B7"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Practice").font(.largeTitle.bold())
                Text("Choose a song, work on a change, or return to a saved take.")
                    .foregroundStyle(Palette.secondary)
                NavigationLink { LibraryView() } label: {
                    Label("Choose a song to practice", systemImage: "music.note.list")
                        .frame(maxWidth: .infinity, minHeight: 48)
                }.buttonStyle(.borderedProminent).tint(.spotifyGreen)
                NavigationLink { LiveChordRecognitionView() } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "waveform").font(.title2).foregroundStyle(Color.spotifyGreen)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Recognize a chord").font(.headline).foregroundStyle(.white)
                            Text("Play your instrument. See what you hear.").font(.subheadline).foregroundStyle(Palette.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(Palette.secondary)
                    }.padding(16).background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
                }.buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 12) {
                    Text("One-minute chord changes").font(.headline)
                    HStack {
                        Picker("First chord", selection: $firstChord) {
                            ForEach(chords, id: \.self) { Text($0).tag($0) }
                        }
                        Image(systemName: "arrow.right")
                        Picker("Second chord", selection: $secondChord) {
                            ForEach(chords, id: \.self) { Text($0).tag($0) }
                        }
                        Spacer()
                        NavigationLink("Start drill") { DrillView(from: firstChord, to: secondChord) }
                            .disabled(firstChord == secondChord).frame(minHeight: 44)
                    }
                    if firstChord == secondChord {
                        Text("Choose two different chords.").font(.footnote).foregroundStyle(Palette.secondary)
                    }
                }.padding(16).background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
                Text("Saved takes").font(.title2.bold())
                if let error = takes.error { Text(error).foregroundStyle(Palette.warning) }
                if takes.takes.isEmpty {
                    Text("Your recordings and results will appear here—even if an upload fails.")
                        .foregroundStyle(Palette.secondary)
                }
                ForEach(takes.takes) { take in
                    NavigationLink { ScrollView { SavedTakeView(take: take) } } label: {
                        HStack(spacing: 12) {
                            Image(systemName: take.report == nil ? "waveform" : "checkmark.circle")
                                .foregroundStyle(Color.spotifyGreen)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(take.song.title).font(.headline).foregroundStyle(.white)
                                Text(take.createdAt, style: .date).font(.footnote).foregroundStyle(Palette.secondary)
                                Text(take.report.map { "\(Int(($0.displayScore * 100).rounded()))% \($0.scoreLabel)" } ?? "Saved · ready to score")
                                    .font(.subheadline).foregroundStyle(Palette.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(Palette.secondary)
                        }.padding(.vertical, 8)
                    }.buttonStyle(.plain)
                }
            }.padding(20)
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { takes.reload() }
    }
}

struct SavedTakeView: View {
    let take: PracticeTake
    @ObservedObject private var takes: PracticeTakeStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var player: AVAudioPlayer?
    @State private var listening = false
    @State private var playbackTime = 0.0
    @State private var duration = 0.0
    @State private var scrubbing = false
    @State private var playbackSessionActive = false
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var newReport: BackendClient.PracticeReport?

    init(take: PracticeTake, takes: PracticeTakeStore = .shared) {
        self.take = take
        self.takes = takes
    }
    private var current: PracticeTake { takes.takes.first { $0.id == take.id } ?? take }
    private var uploading: Bool { takes.uploading.contains(take.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            PracticeDetailHeader(context: "Saved take", title: current.song.title, subtitle: current.song.artist)
                .overlay(alignment: .topTrailing) { takeMenu }
            VStack(alignment: .leading, spacing: 14) {
                Text(current.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline).foregroundStyle(MusicStyle.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { settings }
                    VStack(alignment: .leading, spacing: 8) { settings }
                }
            }
            recordingPlayer
            scoring
            if let note = current.note {
                Label(note, systemImage: "info.circle").font(.subheadline).foregroundStyle(MusicStyle.secondary)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.subheadline).foregroundStyle(Palette.warning).accessibilityIdentifier("take-error")
            }
            NavigationLink { AnalysisTabsView(song: current.song) } label: {
                HStack(spacing: 14) {
                    Image(systemName: "music.note.list").font(.title3).foregroundStyle(Color.spotifyGreen)
                        .frame(width: 44, height: 44).background(MusicStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Open song sheet").font(.headline).foregroundStyle(.white)
                        Text("Return to the chords and lyrics").font(.caption).foregroundStyle(MusicStyle.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(MusicStyle.secondary)
                }.padding(.vertical, 4).contentShape(Rectangle())
            }.buttonStyle(MusicPressStyle())
        }
        .padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 32)
        .frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity)
        .modifier(MusicSurface())
        .toolbar(.hidden, for: .tabBar)
        .confirmationDialog("Delete this take from this device?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete take", role: .destructive) {
                stopListening()
                do { try takes.delete(current); dismiss() }
                catch { self.error = "Could not delete: \(error.localizedDescription)" }
            }
        } message: { Text("The recording and saved result will be permanently removed.") }
        .onAppear { preparePlayer() }
        .onDisappear { stopListening() }
        .task(id: listening) {
            while listening && !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                if !scrubbing { playbackTime = player?.currentTime ?? 0 }
                if player?.isPlaying != true { listening = false; playbackTime = duration }
            }
        }
        .navigationDestination(isPresented: Binding(get: { newReport != nil }, set: { if !$0 { newReport = nil } })) {
            if let newReport { ReportCardView(report: newReport, title: current.song.title, artist: current.song.artist) }
        }
    }

    private var takeMenu: some View {
        Menu {
            if current.report != nil {
                Button("Analyze again", systemImage: "arrow.clockwise", action: submit).disabled(uploading)
            }
            Button("Delete recording", systemImage: "trash", role: .destructive) { confirmDelete = true }
                .disabled(uploading)
        } label: {
            Image(systemName: "ellipsis").font(.headline).foregroundStyle(.white)
                .frame(width: 44, height: 44).background(MusicStyle.surface, in: Circle())
        }.accessibilityLabel("Recording options")
    }

    @ViewBuilder private var settings: some View {
        setting("\(mmss(current.plan.start))–\(mmss(current.plan.end))", icon: "clock")
        setting("\(Int(current.plan.rate * 100))% pace", icon: "metronome")
        setting(current.plan.transpose == 0 ? "Original key" : "\(current.plan.transpose > 0 ? "+" : "")\(current.plan.transpose) semitones", icon: "pianokeys")
    }
    private func setting(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.caption).foregroundStyle(MusicStyle.secondary)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(MusicStyle.surface, in: Capsule()).fixedSize()
    }

    private var recordingPlayer: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                Button(action: togglePlayback) {
                    Image(systemName: listening ? "pause.fill" : "play.fill")
                        .font(.title3).foregroundStyle(.black)
                        .frame(width: 56, height: 56).background(.white, in: Circle())
                }.buttonStyle(MusicPressStyle()).disabled(duration <= 0)
                    .accessibilityLabel(listening ? "Pause recording" : "Play recording")
                    .accessibilityIdentifier("take-playback")
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your recording").font(.headline)
                    Text(listening ? "Playing" : duration > 0 ? "Saved on this device" : "Audio unavailable")
                        .font(.subheadline).foregroundStyle(MusicStyle.secondary)
                }
                Spacer(minLength: 0)
            }
            VStack(spacing: 6) {
                Slider(value: Binding(get: { playbackTime }, set: { position in
                    playbackTime = position
                    player?.currentTime = position
                }), in: 0...max(duration, 0.01), onEditingChanged: { editing in
                    scrubbing = editing
                    if !editing { player?.currentTime = playbackTime }
                }).tint(.spotifyGreen).disabled(duration <= 0)
                    .accessibilityLabel("Recording position")
                    .accessibilityValue("\(mmss(playbackTime)) of \(mmss(duration))")
                HStack {
                    Text(mmss(playbackTime))
                    Spacer()
                    Text(duration > 0 ? mmss(duration) : "—")
                }.font(.caption).monospacedDigit().foregroundStyle(MusicStyle.secondary)
            }
        }.practiceCard()
    }

    private var scoring: some View {
        VStack(alignment: .leading, spacing: 16) {
            if uploading {
                HStack(spacing: 14) {
                    ProgressView().tint(.spotifyGreen).frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Analyzing your take").font(.headline)
                        Text("You can leave this page. Your recording is saved.")
                            .font(.subheadline).foregroundStyle(MusicStyle.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).practiceCard()
                    .accessibilityElement(children: .combine).accessibilityIdentifier("take-scoring")
            } else if let report = current.report {
                HStack {
                    Label("Result ready", systemImage: "checkmark.circle.fill").font(.headline)
                    Spacer()
                    Text(report.displayScore, format: .percent.precision(.fractionLength(0)))
                        .font(.title2.bold()).foregroundStyle(Color.spotifyGreen)
                }
                Text(report.scoreLabel.capitalized).font(.subheadline).foregroundStyle(MusicStyle.secondary)
                NavigationLink { ReportCardView(report: report, title: current.song.title, artist: current.song.artist) } label: {
                    primaryLabel("View result", icon: "arrow.right")
                }.buttonStyle(MusicPressStyle())
            } else {
                Button(action: submit) { primaryLabel(error == nil ? "Analyze recording" : "Try analysis again", icon: "waveform.path") }
                    .buttonStyle(MusicPressStyle()).disabled(duration <= 0)
                    .accessibilityIdentifier("take-analyze")
                Text("Uploads this take to analyze your chords and timing.")
                    .font(.caption).foregroundStyle(MusicStyle.secondary)
            }
        }
    }

    private func primaryLabel(_ title: String, icon: String) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Image(systemName: icon).font(.headline)
        }.foregroundStyle(.black).padding(.horizontal, 20).frame(minHeight: 54)
            .background(Color.spotifyGreen, in: RoundedRectangle(cornerRadius: 16))
    }

    private func submit() {
        stopListening()
        error = nil
        Task {
            do { newReport = try await takes.score(current) }
            catch {
                self.error = "Your recording is saved. " + (error is URLError
                    ? MusicLoadError.message(error) : error.localizedDescription)
            }
        }
    }

    private func preparePlayer() {
        guard player == nil else { return }
        do {
            player = try AVAudioPlayer(contentsOf: takes.audioURL(current))
            duration = player?.duration ?? 0
            player?.currentTime = min(playbackTime, duration)
        } catch { self.error = "Could not open this recording: \(error.localizedDescription)" }
    }
    private func togglePlayback() {
        if listening { player?.pause(); listening = false; return }
        preparePlayer()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            playbackSessionActive = true
            if playbackTime >= duration { playbackTime = 0 }
            player?.currentTime = playbackTime
            guard player?.play() == true else { throw CocoaError(.fileReadCorruptFile) }
            listening = true
        } catch { self.error = "Could not play this recording: \(error.localizedDescription)"; stopListening() }
    }
    private func stopListening() {
        player?.stop(); player = nil; listening = false
        if playbackSessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            playbackSessionActive = false
        }
    }
}

struct MainTabsView: View {
    enum Tab: Hashable { case home, search, practice, library }
    @State private var selection: Tab = .home
    var body: some View {
        TabView(selection: $selection) {
            HomeView(openSearch: { selection = .search }, openLibrary: { selection = .library },
                     openPractice: { selection = .practice })
                .tabItem { Label("Home", systemImage: "house") }.tag(Tab.home)
            NavigationStack { SearchView(isRoot: true) }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(Tab.search)
            NavigationStack { PracticeHubView() }
                .tabItem { Label("Practice", systemImage: "guitars") }.tag(Tab.practice)
            NavigationStack { LibraryView(isRoot: true, findSong: { selection = .search }) }
                .tabItem { Label("Library", systemImage: "music.note.list") }.tag(Tab.library)
        }
        .tint(selection == .practice ? .spotifyGreen : MusicStyle.accent)
    }
}

#if DEBUG
/// Isolated authored audio and injected scoring; never reads account takes.
@MainActor private final class SavedTakePreviewModel: ObservableObject {
    let store: PracticeTakeStore
    let take: PracticeTake
    init() {
        let args = ProcessInfo.processInfo.arguments
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SavedTakePreview-\(UUID().uuidString)")
        let store = PracticeTakeStore(directory: root) { _, _ in
            if args.contains("--saved-take-error") { throw URLError(.notConnectedToInternet) }
            if args.contains("--saved-take-scoring") { try await Task.sleep(for: .seconds(3600)) }
            return PracticeReportPreview.report
        }
        let song = SongDescriptor(trackID: "preview-take", title: "Sola Sistim", artist: "Underworld · sample take")
        let plan = try! PracticePlan(start: 0, end: 12, rate: 0.75)
        var take = try! store.prepare(song: song, plan: plan)
        take.note = nil
        if args.contains("--saved-take-ready") { take.report = PracticeReportPreview.report }
        let rate = 16000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let audio = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 16))!
        audio.frameLength = audio.frameCapacity
        for i in 0..<Int(audio.frameLength) {
            let time = Double(i) / rate
            audio.floatChannelData![0][i] = Float(sin(2 * .pi * 220 * time) * 0.035)
        }
        let file = try! AVAudioFile(forWriting: store.audioURL(take), settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate, AVNumberOfChannelsKey: 1])
        try! file.write(from: audio)
        self.take = take
        self.store = store
    }
}

struct SavedTakePreview: View {
    @StateObject private var model = SavedTakePreviewModel()
    private let args = ProcessInfo.processInfo.arguments
    var body: some View {
        NavigationStack {
            ScrollView { SavedTakeView(take: model.take, takes: model.store) }
                .background(Color.black)
        }
        .environment(\.dynamicTypeSize, args.contains("--practice-large-type") ? .accessibility3 : .large)
        .task {
            if args.contains("--saved-take-scoring") { _ = try? await model.store.score(model.take) }
        }
    }
}
#endif
