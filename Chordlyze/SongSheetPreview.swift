#if DEBUG
import SwiftUI

/// Offline regression fixture, only enabled by an explicit Debug launch arg.
/// Uses authored sample words; never requests or publishes a real song.
struct SongSheetPreview: View {
    @StateObject private var store = makeStore()
    @State private var mode = ProcessInfo.processInfo.arguments.contains("--song-sheet-preview-live") ? "Live" : "Sheet"
    @State private var paused = false
    @State private var anchor = ContinuousClock.now
    @State private var offset = 0.0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Display", selection: $mode) {
                    Text("Sheet").tag("Sheet")
                    Text("Live").tag("Live")
                    Text("Practice").tag("Practice")
                }.pickerStyle(.segmented).padding(12)
                if mode == "Live" {
                    Button(paused ? "Resume preview" : "Pause preview") {
                        offset = position(); anchor = .now; paused.toggle()
                    }
                    LiveNowView(store: store, playbackNote: paused ? "Playback paused" : nil) { position() }
                } else if mode == "Practice", let chart = store.analysis {
                    PracticeView(analysis: chart, title: store.song.title, artist: store.song.artist,
                                 trackID: store.song.id, songStore: store)
                } else {
                    AnalysisTabsView(song: store.song, store: store)
                }
            }.background(.black)
                .onChange(of: mode) { _, value in
                    if value == "Live" { offset = 0; anchor = .now; paused = false }
                }
        }
    }

    private func position() -> Double {
        paused ? offset : offset + anchor.duration(to: .now).seconds
    }

    @MainActor private static func makeStore() -> SongSheetStore {
        func decode<T: Decodable>(_ object: Any) -> T {
            try! JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let chart: ChordAnalysis = decode([
            "chords": [["start": 0, "end": 6, "label": "C:maj"],
                       ["start": 6, "end": 12, "label": "G:7"],
                       ["start": 12, "end": 20, "label": "A:min"],
                       ["start": 20, "end": 40, "label": "F:maj7"]],
            "source": "youtube", "audio_duration": 40, "song_duration": 40, "key": "C major"
        ])
        let status: SongStatus = decode([
            "job": ["state": "ready", "worker_online": true], "library_generation": "preview",
            "analysis": ["chords": [["start": 0, "end": 6, "label": "C:maj"],
                                     ["start": 6, "end": 12, "label": "G:7"],
                                     ["start": 12, "end": 20, "label": "A:min"],
                                     ["start": 20, "end": 40, "label": "F:maj7"]],
                         "source": "youtube", "audio_duration": 40, "song_duration": 40, "key": "C major"]
        ])
        let words: BackendClient.LyricsResult = decode([
            "synced": true, "lines": [
                ["time": 0, "text": "Sample words follow every chord"],
                ["time": 8, "text": "Held notes stay above this line"],
                ["time": 16, "text": ""],
                ["time": 20, "text": "שרים יחד בקצב של הלב"],
                ["time": 30, "text": "The final line keeps its harmony"]
            ]
        ])
        let song = SongDescriptor(trackID: "offline-preview", title: "Song sheet preview",
                                  artist: "Offline regression fixture", duration: 40)
        if ProcessInfo.processInfo.arguments.contains("--song-sheet-preview-delayed") {
            // Chart arrives after three polls, as it does for a fresh song.
            let processing: SongStatus = decode([
                "job": ["state": "processing", "stage": "downloading", "worker_online": true],
                "library_generation": "preview"])
            var polls = 0
            return SongSheetStore(song: song, service: .init(
                request: { _, _ in processing },
                status: { _ in polls += 1; return polls < 3 ? processing : status },
                lyrics: { _ in words }))
        }
        return SongSheetStore(song: song, analysis: chart,
                              service: .init(request: { _, _ in status }, status: { _ in status }, lyrics: { _ in words }))
    }
}
#endif
