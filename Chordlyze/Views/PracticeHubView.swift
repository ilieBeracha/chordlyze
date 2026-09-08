import AVFoundation
import SwiftUI

struct PracticeHubView: View {
    @ObservedObject private var takes: PracticeTakeStore
    private let fetchSongs: () async throws -> [BackendClient.LibraryItem]
    @AppStorage("practice-first-chord") private var firstChord = "C"
    @AppStorage("practice-second-chord") private var secondChord = "G"
    @Environment(\.dynamicTypeSize) private var typeSize
    private let chords = ["C", "D", "Dm", "E", "Em", "F", "G", "A", "Am", "B7"]

    init(takes: PracticeTakeStore? = nil,
         fetchSongs: @escaping () async throws -> [BackendClient.LibraryItem] = { try await BackendClient.library() }) {
        self.takes = takes ?? .shared
        self.fetchSongs = fetchSongs
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 20) {
                    MusicHeader(title: "Practice", subtitle: "Follow the chords. Record your take.")
                    songPractice
                }
                VStack(alignment: .leading, spacing: 14) {
                    SectionLabel("On your instrument")
                    recognition
                    changes
                }
                recordings
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 32)
        }
        .modifier(MusicSurface(ambient: Palette.heroBackground))
        .onAppear { takes.reload() }
    }

    private var songPractice: some View {
        NavigationLink { LibraryView(fetch: fetchSongs) } label: {
            HStack(spacing: 12) {
                Image(systemName: "play.fill")
                Text("Choose a song").font(MusicStyle.font(16, bold: true))
                Spacer()
                Image(systemName: "arrow.right")
            }.foregroundStyle(.black).padding(.horizontal, 20).padding(.vertical, 18)
                .frame(minHeight: 56)
                .background(Color.spotifyGreen, in: Capsule())
        }.buttonStyle(MusicPressStyle()).accessibilityIdentifier("practice-choose-song")
    }

    private var recognition: some View {
        NavigationLink { LiveChordRecognitionView() } label: {
            HStack(spacing: 14) {
                Image(systemName: "waveform").font(.system(size: 23, weight: .medium))
                    .foregroundStyle(Color.spotifyGreen).frame(width: 32).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Check a chord").font(MusicStyle.font(17, bold: true))
                    Text("Hear what you're playing.").font(MusicStyle.font(14))
                        .foregroundStyle(MusicStyle.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MusicStyle.secondary).accessibilityHidden(true)
            }.padding(20).background(MusicStyle.surface, in: RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(MusicPressStyle()).accessibilityIdentifier("practice-check-chord")
    }

    private var changes: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("Chord changes").font(MusicStyle.font(17, bold: true))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Label("60 sec", systemImage: "timer").font(MusicStyle.font(12))
                    .foregroundStyle(MusicStyle.secondary).fixedSize()
            }
            (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 14)) : AnyLayout(HStackLayout(spacing: 14))) {
                chordMenu("First chord", selection: $firstChord)
                Image(systemName: typeSize.isAccessibilitySize ? "arrow.up.arrow.down" : "arrow.left.arrow.right").font(.system(size: 15))
                    .foregroundStyle(MusicStyle.secondary).accessibilityHidden(true)
                chordMenu("Second chord", selection: $secondChord)
            }
            if firstChord == secondChord {
                Text("Choose two different chords.").font(.footnote).foregroundStyle(Palette.warning)
            }
            NavigationLink { DrillView(from: firstChord, to: secondChord) } label: {
                HStack {
                    Text("Start changes").font(MusicStyle.font(15, bold: true))
                    Spacer()
                    Image(systemName: "arrow.right")
                }.foregroundStyle(firstChord == secondChord ? MusicStyle.secondary : Color.spotifyGreen)
                    .frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(MusicPressStyle()).disabled(firstChord == secondChord)
                .accessibilityIdentifier("practice-start-changes")
        }.padding(20).background(MusicStyle.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private func chordMenu(_ title: String, selection: Binding<String>) -> some View {
        Menu {
            Picker(title, selection: selection) {
                ForEach(chords, id: \.self) { Text($0).tag($0) }
            }
        } label: {
            HStack(spacing: 8) {
                Text(selection.wrappedValue).font(MusicStyle.font(32, bold: true, relativeTo: .title))
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MusicStyle.secondary)
            }.foregroundStyle(.white).padding(.horizontal, 18).padding(.vertical, 14)
                .frame(maxWidth: .infinity, minHeight: 68)
                .background(Palette.elevated, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(MusicPressStyle()).accessibilityLabel(title).accessibilityValue(selection.wrappedValue)
    }

    private var recordings: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Your takes").font(MusicStyle.font(23, bold: true, relativeTo: .title2))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if !takes.takes.isEmpty {
                    Text("\(takes.takes.count)").font(MusicStyle.font(13)).foregroundStyle(MusicStyle.secondary)
                        .accessibilityLabel(takes.takes.count == 1 ? "1 saved recording" : "\(takes.takes.count) saved recordings")
                }
            }
            if let error = takes.error { Text(error).font(.footnote).foregroundStyle(Palette.warning) }
            if takes.takes.isEmpty {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "waveform.path").font(.title2).foregroundStyle(MusicStyle.secondary)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Your next take starts here").font(MusicStyle.font(15, bold: true))
                        Text("Record with a song, then listen back and review your chords.")
                            .font(MusicStyle.font(14)).foregroundStyle(MusicStyle.secondary)
                    }
                }.padding(.vertical, 8)
            }
            ForEach(takes.takes) { take in
                NavigationLink { ScrollView { SavedTakeView(take: take, takes: takes) } } label: {
                    (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                     : AnyLayout(HStackLayout(spacing: 14))) {
                        Image(systemName: "waveform").font(.system(size: 20))
                            .foregroundStyle(Color.spotifyGreen).frame(width: 48, height: 52)
                            .background(Palette.card, in: RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(take.song.title).font(MusicStyle.font(16, bold: true)).foregroundStyle(.white)
                            Text(take.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(MusicStyle.font(12)).foregroundStyle(MusicStyle.secondary)
                            Text(take.report.map { "\(Int(($0.displayScore * 100).rounded()))% \($0.scoreLabel)" } ?? "Ready to listen & review")
                                .font(MusicStyle.font(12)).foregroundStyle(MusicStyle.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(MusicStyle.secondary).accessibilityHidden(true)
                    }.padding(.vertical, 8).contentShape(Rectangle())
                }.buttonStyle(MusicPressStyle())
            }
        }
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

    init(take: PracticeTake, takes: PracticeTakeStore? = nil) {
        self.take = take
        self.takes = takes ?? .shared
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
        if !args.contains("--practice-empty") {
            let file = try! AVAudioFile(forWriting: store.audioURL(take), settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate, AVNumberOfChannelsKey: 1])
            try! file.write(from: audio)
        }
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

struct PracticeHubPreview: View {
    @StateObject private var model = SavedTakePreviewModel()
    var fetchSongs: () async throws -> [BackendClient.LibraryItem]
    var body: some View {
        NavigationStack {
            if ProcessInfo.processInfo.arguments.contains("--practice-feedback") { PracticeListeningPreview() }
            else { PracticeHubView(takes: model.store, fetchSongs: fetchSongs) }
        }
    }
}
#endif
