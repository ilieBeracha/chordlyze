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
                if ProcessInfo.processInfo.arguments.contains("--spotify-device-recovery-preview"), mode != "Practice" {
                    ScrollView {
                        SpotifyDeviceRecoveryView(nowPlaying: player, trackID: store.song.id, retryTitle: "Retry practice") {
                            mode = "Practice"
                        }.padding(24)
                    }.observes(store)
                } else if ProcessInfo.processInfo.arguments.contains("--chord-corrections-preview") {
                    ChordCorrectionsView(store: store)
                } else if mode == "Live" {
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
        .dynamicTypeSize(ProcessInfo.processInfo.arguments.contains("--song-map-large-type") ? .accessibility3 : .large)
    }

    private func position() -> Double {
        paused ? offset : offset + anchor.duration(to: .now).seconds
    }

    private static func decode<T: Decodable>(_ object: Any) -> T {
        try! JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @MainActor private static func makePlayer(sheet: SongSheetStore) -> SpotifyNowPlaying {
        var device: (anchor: ContinuousClock.Instant, offset: Double, playing: Bool)?
        var discoveryCalls = 0
        let item: [String: Any] = ["id": sheet.song.id, "name": sheet.song.title, "artists": [["name": sheet.song.artist]],
                                   "album": ["name": "Preview"], "duration_ms": 40000]
        let player = SpotifyNowPlaying(service: .init(
            current: {
                guard let device else { return nil }
                let position = device.offset + (device.playing ? device.anchor.duration(to: .now).seconds : 0)
                if position >= 40 { return nil }
                return decode(["progress_ms": Int(position * 1000), "is_playing": device.playing, "item": item,
                               "device": ["id": "sim", "name": "Simulator", "type": "Smartphone", "is_active": true]])
            },
            seek: { device = (.now, $0, true) },
            play: { _, at, _ in device = (.now, at, true) },
            devices: {
                discoveryCalls += 1
                if ProcessInfo.processInfo.arguments.contains("--spotify-device-recovery-preview"), discoveryCalls <= 3 {
                    return [decode(["id": "mac", "name": "Preview Mac", "type": "Computer", "is_active": true])]
                }
                return [decode(["id": "sim", "name": "Simulator phone", "type": "Smartphone", "is_active": true])]
            }),
            sheetProvider: { _ in sheet })
        player.resume()
        return player
    }

    @MainActor private static func makeStore() -> SongSheetStore {
        let mapPreview = ProcessInfo.processInfo.arguments.contains("--song-map-preview")
        let meter = 3
        let sampleBars: [[String: Any]] = (0..<26).map { index in
            let start = Double(index)*1.5
            return ["start": start, "end": start+1.5, "beats": 3]
        }
        let tempo: [String: Any] = mapPreview ? [
            "bpm": 120, "beats": (0..<80).map { Double($0)*0.5 },
            "rhythm_version": 1, "beat_positions": (0..<80).map { $0 % meter + 1 },
            "bars": sampleBars,
            "sections": [
                ["start": 0, "end": 12, "start_bar": 1, "end_bar": 8, "label": "A", "occurrence": 1],
                ["start": 12, "end": 24, "start_bar": 9, "end_bar": 16, "label": "B", "occurrence": 1],
                ["start": 24, "end": 39, "start_bar": 17, "end_bar": 26, "label": "A", "occurrence": 2]]
        ] : ["bpm": 120, "beats": (0..<80).map { Double($0)*0.5 }]
        let chart: ChordAnalysis = decode([
            "chords": [["start": 0, "end": 6, "label": "C:maj"],
                       ["start": 6, "end": 12, "label": "G:7"],
                       ["start": 12, "end": 20, "label": "A:min"],
                       ["start": 20, "end": 40, "label": "F:maj7"]],
            "source": "youtube", "audio_duration": 40, "song_duration": 40, "key": "C major",
            "tempo": tempo
        ])
        var status: SongStatus = decode([
            "job": ["state": "ready", "worker_online": true], "library_generation": "preview",
            "analysis": ["chords": [["start": 0, "end": 6, "label": "C:maj"],
                                     ["start": 6, "end": 12, "label": "G:7"],
                                     ["start": 12, "end": 20, "label": "A:min"],
                                     ["start": 20, "end": 40, "label": "F:maj7"]],
                         "source": "youtube", "audio_duration": 40, "song_duration": 40, "key": "C major",
                         "tempo": tempo, "chart_revision": "preview-original"]
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
        let song = SongDescriptor(trackID: "offline-preview", title: mapPreview ? "Song map · sample" : "Song sheet preview",
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
        var history: [[[String: Any]]] = []
        func raw(_ chart: ChordAnalysis) -> [[String: Any]] {
            chart.chords.map { ["start": $0.start, "end": $0.end, "label": $0.label] }
        }
        func fixtureLabel(_ name: String) -> String {
            guard let chord = Chord(display: name) else { return "N" }
            let degrees = ["1", "b2", "2", "b3", "3", "4", "b5", "5", "b6", "6", "b7", "7"]
            return Chord.names[chord.root] + ":" + chord.quality.harte
                + (chord.bass.map { "/" + degrees[($0 - chord.root + 12) % 12] } ?? "")
        }
        func publish(_ segments: [[String: Any]]) -> SongStatus {
            status = decode(["job": ["state": "ready", "worker_online": true], "library_generation": "preview", "saved": true,
                "analysis": ["chords": segments, "source": "youtube", "audio_duration": 40,
                    "song_duration": 40, "key": "C major", "tempo": tempo, "chart_revision": UUID().uuidString,
                    "can_undo": !history.isEmpty, "boundaries_edited": segments.count != chart.chords.count || zip(segments, chart.chords).contains {
                        $0.0["start"] as? Double != $0.1.start || $0.0["end"] as? Double != $0.1.end
                    }]])
            return status
        }
        return SongSheetStore(song: song, analysis: chart,
                              service: .init(request: { _ in status }, status: { _ in status }, lyrics: { _ in words },
                                             save: { _, _ in }, saveTiming: { _, _ in },
                                             editBoundary: { _, edit in
            guard edit.chartRevision == status.analysis?.chartRevision else { throw BackendError(status: 409, detail: "Reopen the chord.") }
            var segments = raw(status.analysis!)
            if edit.operation == .undo {
                guard let prior = history.popLast() else { throw BackendError(status: 409, detail: "Nothing to undo.") }
                return publish(prior)
            }
            history.append(segments)
            if edit.operation == .restore { return publish(raw(chart)) }
            guard let index = status.analysis?.chords.firstIndex(where: { $0.start == edit.start && $0.end == edit.end }) else {
                throw BackendError(status: 409, detail: "Reopen the chord.")
            }
            switch edit.operation {
            case .move:
                let left = edit.edge == "start" ? index - 1 : index
                guard let at = edit.at, left >= 0, left + 1 < segments.count else { throw BackendError(status: 422, detail: "No neighboring chord.") }
                segments[left]["end"] = at; segments[left + 1]["start"] = at
            case .split:
                guard let at = edit.at else { throw BackendError(status: 422, detail: "Choose a split time.") }
                var right = segments[index]
                segments[index]["end"] = at; right["start"] = at
                right["label"] = fixtureLabel(edit.name ?? "N.C.")
                segments.insert(right, at: index + 1)
            case .merge:
                guard index + 1 < segments.count else { throw BackendError(status: 422, detail: "No next chord.") }
                segments[index]["end"] = segments[index + 1]["end"]
                if let name = edit.name { segments[index]["label"] = fixtureLabel(name) }
                segments.remove(at: index + 1)
            case .undo, .restore: break
            }
            return publish(segments)
        },
                                             correctChord: { _, segment, name, revision in
            guard revision == status.analysis?.chartRevision else {
                throw BackendError(status: 409, detail: "The chart changed. Reopen the chord.")
            }
            let label: String
            if let name, let chord = Chord(display: name) {
                let degrees = ["1", "b2", "2", "b3", "3", "4", "b5", "5", "b6", "6", "b7", "7"]
                label = Chord.names[chord.root] + ":" + chord.quality.harte
                    + (chord.bass.map { "/" + degrees[($0 - chord.root + 12) % 12] } ?? "")
            } else { label = name == nil ? segment.originalLabel ?? segment.label : "N" }
            let segments: [[String: Any]] = status.analysis!.chords.map { item in
                let changed = item.start == segment.start
                let original = item.originalLabel ?? item.label
                var result: [String: Any] = ["start": item.start, "end": item.end,
                    "label": changed ? label : item.label]
                if changed ? label != original : item.originalLabel != nil { result["original_label"] = original }
                return result
            }
            history.append(raw(status.analysis!))
            return publish(segments)
        }))
    }
}
#endif
