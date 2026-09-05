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
                                Text(take.report.map { "\(Int(($0.accuracy * 100).rounded()))% on target" } ?? "Saved · ready to score")
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
    @ObservedObject private var takes = PracticeTakeStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVAudioPlayer?
    @State private var listening = false
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var newReport: BackendClient.PracticeReport?
    private var current: PracticeTake { takes.takes.first { $0.id == take.id } ?? take }
    private var uploading: Bool { takes.uploading.contains(take.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            BackCircle()
            Text(current.song.title).font(.title.bold())
            Text(current.song.artist).foregroundStyle(Palette.secondary)
            Text(current.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.subheadline).foregroundStyle(Palette.secondary)
            Text("From \(mmss(current.plan.start)) · \(Int(current.plan.rate * 100))% pace · \(current.plan.transpose > 0 ? "+" : "")\(current.plan.transpose) semitones")
                .font(.subheadline)
            if let note = current.note { Text(note).foregroundStyle(Palette.warning) }
            if let report = current.report {
                NavigationLink { ReportCardView(report: report, title: current.song.title, artist: current.song.artist) } label: {
                    Label("View result · \(Int((report.accuracy * 100).rounded()))%", systemImage: "chart.bar")
                }.buttonStyle(.borderedProminent).tint(.spotifyGreen)
            } else {
                Button {
                    stopListening()
                    error = nil
                    Task {
                        do { newReport = try await takes.score(current) }
                        catch { self.error = "Your take is still saved. \(error.localizedDescription)" }
                    }
                } label: {
                    if uploading { ProgressView("Scoring…") }
                    else { Label("Submit for scoring", systemImage: "arrow.up.circle") }
                }.buttonStyle(.borderedProminent).tint(.spotifyGreen).disabled(uploading)
                Text("Scoring uploads this recording to Chordlyze. You can return here while it processes.")
                    .font(.footnote).foregroundStyle(Palette.secondary)
            }
            Button {
                if listening { stopListening() }
                else {
                    do {
                        let session = AVAudioSession.sharedInstance()
                        try session.setCategory(.playback, mode: .default)
                        try session.setActive(true)
                        player = try AVAudioPlayer(contentsOf: takes.audioURL(current))
                        guard player?.play() == true else { throw CocoaError(.fileReadCorruptFile) }
                        listening = true
                    } catch { self.error = "Could not play this recording: \(error.localizedDescription)"; stopListening() }
                }
            } label: { Label(listening ? "Stop listening" : "Listen to recording", systemImage: listening ? "stop.fill" : "play.fill") }
                .frame(minHeight: 44).disabled(uploading)
            NavigationLink { AnalysisTabsView(song: current.song) } label: {
                Label("Open song sheet", systemImage: "music.note.list")
            }.frame(minHeight: 44)
            if let error { Text(error).font(.subheadline).foregroundStyle(Palette.warning) }
            Button("Delete recording and result", role: .destructive) { confirmDelete = true }
                .frame(minHeight: 44).disabled(uploading)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .toolbar(.hidden, for: .navigationBar)
        .confirmationDialog("Delete this take from this device?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete take", role: .destructive) {
                stopListening()
                do { try takes.delete(current); dismiss() }
                catch { self.error = "Could not delete: \(error.localizedDescription)" }
            }
        } message: { Text("The recording and saved result will be permanently removed.") }
        .onDisappear { stopListening() }
        .task(id: listening) {
            while listening && !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                if player?.isPlaying != true { stopListening() }
            }
        }
        .navigationDestination(isPresented: Binding(get: { newReport != nil }, set: { if !$0 { newReport = nil } })) {
            if let newReport { ReportCardView(report: newReport, title: current.song.title, artist: current.song.artist) }
        }
    }

    private func stopListening() {
        guard player != nil else { return }
        player?.stop(); player = nil; listening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

struct MainTabsView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house") }
            NavigationStack { SearchView(isRoot: true) }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            NavigationStack { PracticeHubView() }
                .tabItem { Label("Practice", systemImage: "guitars") }
            NavigationStack { LibraryView(isRoot: true) }
                .tabItem { Label("Library", systemImage: "music.note.list") }
        }
    }
}
