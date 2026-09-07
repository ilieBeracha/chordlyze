#if DEBUG
import SwiftUI

/// Offline regression fixture, only enabled by an explicit Debug launch arg.
/// Uses authored sample words; never requests or publishes a real song.
struct SongSheetPreview: View {
    @StateObject private var store: SongSheetStore
    /// Practice preview: a fake Spotify device that starts wherever it is told
    /// and reports its position like the real poller, without any network.
    @StateObject private var player: SpotifyNowPlaying
    @State private var mode = ProcessInfo.processInfo.arguments.contains("--song-sheet-preview-live") ? "Live" : "Sheet"
    @State private var paused = false
    @State private var anchor = ContinuousClock.now
    @State private var offset = 0.0

    init() {
        let store = Self.makeStore()
        _store = StateObject(wrappedValue: store)
        _player = StateObject(wrappedValue: Self.makePlayer(sheet: store))
    }

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
                    LiveSongView(store: store, playbackNote: paused ? "Playback paused" : nil) { position() }
                } else if mode == "Practice", let chart = store.analysis {
                    PracticeView(analysis: chart, title: store.song.title, artist: store.song.artist,
                                 trackID: store.song.id, songStore: store, nowPlaying: player)
                } else {
                    AnalysisTabsView(song: store.song, store: store, nowPlaying: player)
                        .task {
                            // `--song-sheet-preview-playing`: the fake device starts at once, so
                            // the sheet lighting up in place can be checked without a tap.
                            guard ProcessInfo.processInfo.arguments.contains("--song-sheet-preview-playing") else { return }
                            try? await player.play(trackID: store.song.id, at: 0)
                        }
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

    private static func decode<T: Decodable>(_ object: Any) -> T {
        try! JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @MainActor private static func makePlayer(sheet: SongSheetStore) -> SpotifyNowPlaying {
        var device: (anchor: ContinuousClock.Instant, offset: Double, playing: Bool)?
        let item: [String: Any] = ["id": sheet.song.id, "name": sheet.song.title, "artists": [["name": sheet.song.artist]],
                                   "album": ["name": "Preview"], "duration_ms": 40000]
        let player = SpotifyNowPlaying(service: .init(
            current: {
                guard let device else { return nil }
                let position = device.offset + (device.playing ? device.anchor.duration(to: .now).seconds : 0)
                if position >= 40 { return nil }
                return decode(["progress_ms": Int(position * 1000), "is_playing": device.playing, "item": item])
            },
            seek: { device = (.now, $0, true) },
            play: { _, at, _ in device = (.now, at, true) },
            devices: { [decode(["id": "sim", "name": "Simulator", "type": "Smartphone", "is_active": true])] }),
            sheetProvider: { _ in sheet })
        player.resume()
        return player
    }

    @MainActor private static func makeStore() -> SongSheetStore {
        let chart: ChordAnalysis = decode([
            "chords": [["start": 0, "end": 6, "label": "C:maj"],
                       ["start": 6, "end": 12, "label": "G:7"],
                       ["start": 12, "end": 20, "label": "A:min"],
                       ["start": 20, "end": 40, "label": "F:maj7"]],
            "source": "youtube", "audio_duration": 40, "song_duration": 40, "key": "C major",
            "tempo": ["bpm": 120, "beats": (0..<80).map { Double($0) * 0.5 }]
        ])
        let status: SongStatus = decode([
            "job": ["state": "ready", "worker_online": true], "library_generation": "preview",
            "analysis": ["chords": [["start": 0, "end": 6, "label": "C:maj"],
                                     ["start": 6, "end": 12, "label": "G:7"],
                                     ["start": 12, "end": 20, "label": "A:min"],
                                     ["start": 20, "end": 40, "label": "F:maj7"]],
                         "source": "youtube", "audio_duration": 40, "song_duration": 40, "key": "C major",
                         "tempo": ["bpm": 120, "beats": (0..<80).map { Double($0) * 0.5 }]]
        ])
        let arguments = ProcessInfo.processInfo.arguments
        // "estimated": catalog lyrics without timing, spread over the song as the backend does.
        let estimated = arguments.contains("--song-sheet-preview-estimated")
        let words: BackendClient.LyricsResult = decode([
            "synced": !estimated, "lines": estimated ? [
                ["time": 2, "text": "Sample words follow every chord"],
                ["time": 10.7, "text": "A held chord is not repeated on this line"],
                ["time": 22.4, "text": "שרים יחד בקצב של הלב"],
                ["time": 28.4, "text": "The final line keeps its harmony"]
            ] : [
                ["time": 0, "text": "Sample words follow every chord"],
                ["time": 8, "text": "A held chord is not repeated on this line",
                 "words": [["time": 8.4, "text": "A"], ["time": 8.7, "text": "held"], ["time": 9.2, "text": "chord"], ["time": 9.8, "text": "is"],
                           ["time": 10.1, "text": "not"], ["time": 10.6, "text": "repeated"], ["time": 11.4, "text": "on"],
                           ["time": 11.7, "text": "this"], ["time": 12.1, "text": "line"]]],
                ["time": 16, "text": ""],
                ["time": 20, "text": "שרים יחד בקצב של הלב"],
                ["time": 30, "text": "The final line keeps its harmony"]
            ]
        ])
        let song = SongDescriptor(trackID: "offline-preview", title: "Song sheet preview",
                                  artist: "Offline regression fixture", duration: 40)
        if arguments.contains("--song-sheet-preview-delayed") || arguments.contains("--song-sheet-preview-missing") {
            // Chart arrives after three polls, as it does for a fresh song.
            // "missing": nothing happens until Analyze is tapped, as in the app.
            let processing: SongStatus = decode([
                "job": ["state": "processing", "stage": "downloading", "worker_online": true],
                "library_generation": "preview"])
            let missing: SongStatus = decode([
                "job": ["state": "missing", "worker_online": true], "library_generation": "preview"])
            var requested = !arguments.contains("--song-sheet-preview-missing")
            var polls = 0
            return SongSheetStore(song: song, service: .init(
                request: { _ in requested = true; return processing },
                status: { _ in
                    guard requested else { return missing }
                    polls += 1; return polls < 3 ? processing : status
                },
                lyrics: { _ in words }))
        }
        return SongSheetStore(song: song, analysis: chart,
                              service: .init(request: { _ in status }, status: { _ in status }, lyrics: { _ in words },
                                             save: { _, _ in }, saveTiming: { _, _ in }))
    }
}
#endif
