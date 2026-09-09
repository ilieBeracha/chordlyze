#if DEBUG
import SwiftUI

/// Offline regression fixture, only enabled by an explicit Debug launch arg.
/// Uses authored sample words; never requests or publishes a real song.
struct SongSheetPreview: View {
    @StateObject private var store: SongSheetStore
    /// Practice preview: a fake Spotify device that starts wherever it is told
    /// and reports its position like the real poller, without any network.
    @StateObject private var player: SpotifyNowPlaying
    @State private var mode = ProcessInfo.processInfo.arguments.contains("--song-sheet-preview-live") ? "Live" : ProcessInfo.processInfo.arguments.contains("--practice-setup-preview") ? "Practice" : "Sheet"
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
                if ProcessInfo.processInfo.arguments.contains("--song-sheet-preview-controls") && !ProcessInfo.processInfo.arguments.contains("--practice-setup-preview") {
                Picker("Display", selection: $mode) {
                    Text("Sheet").tag("Sheet")
                    Text("Live").tag("Live")
                    Text("Practice").tag("Practice")
                }.pickerStyle(.segmented).padding(12)
                }
                if ProcessInfo.processInfo.arguments.contains("--song-developer-preview") {
                    SongDeveloperToolsView(store: store)
                        .task {
                            guard ProcessInfo.processInfo.arguments.contains("--song-developer-run") else { return }
                            try? await Task.sleep(for: .milliseconds(300))
                            await store.reanalyze()
                        }
                } else if ProcessInfo.processInfo.arguments.contains("--spotify-device-recovery-preview"), mode != "Practice" {
                    ScrollView {
                        SpotifyDeviceRecoveryView(nowPlaying: player, trackID: store.song.id, retryTitle: "Retry practice") {
                            mode = "Practice"
                        }.padding(24)
                    }.observes(store)
                } else if ProcessInfo.processInfo.arguments.contains("--passage-preview") {
                    PassageAnalysisView(store: store, range: 6...12, model: Self.passageModel())
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
                            let start = ProcessInfo.processInfo.arguments.contains("--independent-chords-vocal") ? 28.225 : 0
                            try? await player.play(trackID: store.song.id, at: start)
                        }
                }
            }.background(.black)
                .onChange(of: mode) { _, value in
                    if value == "Live" { offset = 0; anchor = .now; paused = false }
                }
        }
        .dynamicTypeSize(ProcessInfo.processInfo.arguments.contains("--song-map-large-type") ? .accessibility3 : .large)
    }

    @MainActor private static func passageModel() -> PassageAnalysisModel {
        let fixture: PassageJob = decode(["id": "preview-proposal", "state": "ready", "start": 6, "end": 12,
            "chart_revision": "preview-original", "protected_count": 0,
            "segments": [["start": 6, "end": 9, "label": "G:7"], ["start": 9, "end": 12, "label": "D:min7"]]])
        return PassageAnalysisModel(service: .init(read: { _ in fixture }, request: { _,_,_,_ in fixture }))
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
        let duration = sheet.song.duration ?? 40
        let item: [String: Any] = ["id": sheet.song.id, "name": sheet.song.title, "artists": [["name": sheet.song.artist]],
                                   "album": ["name": "Preview"], "duration_ms": Int(duration * 1000)]
        let player = SpotifyNowPlaying(service: .init(
            current: {
                guard let device else { return nil }
                let position = device.offset + (device.playing ? device.anchor.duration(to: .now).seconds : 0)
                if position >= duration { return nil }
                return decode(["progress_ms": Int(position * 1000), "is_playing": device.playing, "item": item,
                               "device": ["id": "sim", "name": "Simulator", "type": "Smartphone", "is_active": true]])
            },
            seek: { device = (.now, $0, true) },
            play: { _, at, _ in device = (.now, at, true) },
            devices: {
                discoveryCalls += 1
                let startupPreview = ProcessInfo.processInfo.arguments.contains("--spotify-startup-preview")
                if (ProcessInfo.processInfo.arguments.contains("--spotify-device-recovery-preview") || startupPreview), discoveryCalls <= 3 {
                    return [decode(["id": "mac", "name": "Preview Mac", "type": "Computer", "is_active": true])]
                }
                // Model Spotify already playing as its cold-start handoff
                // returns. The sheet must retain recovery across this change.
                if startupPreview, discoveryCalls == 4 { device = (.now, 0, true) }
                return [decode(["id": "sim", "name": "Simulator phone", "type": "Smartphone", "is_active": true])]
            }),
            sheetProvider: { _ in sheet })
        player.resume()
        return player
    }

    /// Authored words reproduce the reported phrase timings without embedding song lyrics.
    @MainActor private static func phraseBoundaryStore() -> SongSheetStore {
        let song = SongDescriptor(trackID: "phrase-preview", title: "Phrase boundaries · sample", artist: "Offline regression fixture", duration: 45)
        let payload: SongStatus = decode([
            "job": ["state": "ready", "worker_online": true], "library_generation": "preview",
            "analysis": ["source": "youtube", "audio_duration": 45, "song_duration": 45,
                "chords": [["start": 0, "end": 26.86, "label": "E:maj"],
                    ["start": 26.86, "end": 30.16, "label": "E:maj"],
                    ["start": 30.16, "end": 31.82, "label": "B:min"],
                    ["start": 31.82, "end": 34.9, "label": "D:maj"],
                    ["start": 34.9, "end": 36.74, "label": "F#:min"],
                    ["start": 36.74, "end": 45, "label": "E:maj"]]],
            "lyrics": ["synced": true, "matched": "aligned", "timing_note": "Some lyric timing is approximate; all catalog lines are included.",
                "lines": [
                    ["time": 18.37, "text": "The opening phrase stays here even when its word timing is missing"],
                    ["time": 26.8, "text": "We watched the evening clouds as the final note faded", "words": [
                        ["time": 26.8, "text": "We"], ["time": 27.52, "text": "watched"], ["time": 27.82, "text": "the"],
                        ["time": 28.24, "text": "evening"], ["time": 28.65, "text": "clouds"], ["time": 29.05, "text": "as"],
                        ["time": 29.46, "text": "the"], ["time": 29.76, "text": "final"], ["time": 29.98, "text": "note"],
                        ["time": 30.16, "text": "faded", "end": 30.62]]],
                    ["time": 31.88, "text": "Then a new phrase begins with a softly ringing chord", "words": [
                        ["time": 31.88, "text": "Then"], ["time": 32.08, "text": "a"], ["time": 32.2, "text": "new"],
                        ["time": 32.76, "text": "phrase"], ["time": 33.3, "text": "begins"], ["time": 34.02, "text": "with"],
                        ["time": 34.64, "text": "a"], ["time": 35.12, "text": "softly"], ["time": 35.36, "text": "ringing"],
                        ["time": 36.13, "text": "chord"]]],
                    ["time": 36.9, "text": "Every remaining word stays visible on the following line"]]]])
        return SongSheetStore(song: song, analysis: payload.analysis, service: .init(request: { _ in payload }, status: { _ in payload }, lyrics: { _ in nil }))
    }

    /// The reported intro/rest geometry, with authored replacement words.
    @MainActor private static func independentTimingStore() -> SongSheetStore {
        let song = SongDescriptor(trackID: "timing-preview", title: "Independent timing", artist: "Offline sample", duration: 60)
        let boundaries = [0.0, 3.808, 12.399, 21.037, 29.721, 31.927, 34.807, 41.285, 42.98, 47.067, 51.386, 53.545, 60]
        let labels = ["N", "E:min", "E:min7", "D:min7", "E:min7", "A:maj/5", "E:min7", "A:maj/5", "E:min7", "B:min7", "A:7", "F#:min7"]
        let segments: [[String: Any]] = labels.indices.map { ["start": boundaries[$0], "end": boundaries[$0+1], "label": labels[$0]] }
        let payload: SongStatus = decode([
            "job": ["state": "ready", "worker_online": true], "library_generation": "preview",
            "analysis": ["source": "youtube", "audio_duration": 60, "song_duration": 60, "chords": segments],
            "lyrics": ["synced": true, "matched": "aligned", "timing_note": "Some lyric timing is approximate.", "lines": [
                ["time": 28.225, "text": "The opening phrase"],
                ["time": 33.51, "text": "Another phrase follows", "words": [
                    ["time": 33.51, "text": "Another", "end": 34.0],
                    ["time": 37.2, "text": "phrase", "end": 37.76],
                    ["time": 41.65, "text": "follows", "end": 42.1]]],
                ["time": 45.54, "text": "We keep the rhythm moving"],
                ["time": 54.8, "text": "A final phrase"]]]])
        return SongSheetStore(song: song, analysis: payload.analysis, service: .init(request: { _ in payload }, status: { _ in payload }, lyrics: { _ in nil }))
    }

    /// Mixed measured/estimated timing from the reported geometry, with
    /// authored words. Exercises the real page without a backend connection.
    @MainActor private static func mixedWordTimingStore() -> SongSheetStore {
        let song = SongDescriptor(trackID: "mixed-timing-preview", title: "Word alignment", artist: "Offline regression sample", duration: 60)
        let starts = [0.0, 3.808, 12.492, 21.13, 29.791, 31.951, 34.644, 41.123, 42.98, 47.09, 51.409, 53.568, 54.637, 55.728, 60]
        let labels = ["N", "E:min", "E:min7", "D:min7", "E:min7", "A:maj/5", "E:min7", "A:maj/5", "E:min7", "B:min7", "A:7", "F#:min7", "B:min7", "E:min7"]
        let phrases: [(Double, String, [Double], [Double?])] = [
            (33.51, "We keep moving onward", [33.51, 37.2, 37.76, 41.65], [nil, 37.76, 38.34, nil]),
            (45.54, "These phrases remain together while all the changes play", [45.54, 45.84, 46.26, 47.56, 48.86, 50.16, 50.8, 51.62, 52.88], [45.84, 46.26, 46.78, nil, nil, 50.8, 51.62, 51.98, nil]),
            (54.14, "We follow every word in time", [54.14, 54.42, 54.48, 55.3, 55.7, 55.88], [54.42, 54.48, 55.3, 55.7, 55.88, 57.04])]
        var lines: [[String: Any]] = [["time": 28.225, "text": "The opening phrase"]]
        for (time, text, onsets, ends) in phrases {
            let words = text.split(separator: " ").enumerated().map { index, word -> [String: Any] in
                var stamp: [String: Any] = ["time": onsets[index], "text": String(word)]
                if let end = ends[index] { stamp["end"] = end }
                else { stamp["estimated"] = true }
                return stamp
            }
            lines.append(["time": time, "text": text, "words": words])
        }
        let payload: SongStatus = decode([
            "job": ["state": "ready", "worker_online": true], "library_generation": "preview",
            "analysis": ["source": "youtube", "audio_duration": 60, "song_duration": 60,
                "chords": labels.indices.map { ["start": starts[$0], "end": starts[$0+1], "label": labels[$0]] }],
            "lyrics": ["synced": true, "matched": "aligned", "timing_note": "Some lyric timing is approximate.", "lines": lines]])
        return SongSheetStore(song: song, analysis: payload.analysis, service: .init(request: { _ in payload }, status: { _ in payload }, lyrics: { _ in nil }))
    }

    /// Interactive, entirely offline reanalysis fixture for real settings UI checks.
    @MainActor private static func developerToolsStore() -> SongSheetStore {
        let args = ProcessInfo.processInfo.arguments
        let song = SongDescriptor(trackID: "developer-preview", title: "Evening light", artist: "Offline sample", duration: 40)
        var requestedAt: ContinuousClock.Instant?
        var completedAt: Double?
        func payload() -> SongStatus {
            let elapsed = requestedAt.map { $0.duration(to: .now).seconds } ?? -1
            let complete = elapsed >= 9 || args.contains("--song-developer-current")
            if complete && completedAt == nil { completedAt = Date().timeIntervalSince1970 }
            let jobState = args.contains("--song-developer-failed") ? "failed" :
                (elapsed < 0 || complete ? "ready" : elapsed < 3 ? "queued" : "processing")
            let version = complete ? 4 : 3
            let revision = complete ? "preview-new" : "preview-original"
            var info: [String: Any] = ["analysis_version": version, "current_analysis_version": 4,
                "versions_behind": 4 - version, "is_current": complete, "chart_revision": revision,
                "analyzed_at": completedAt ?? 1788714000, "model": "ismir2019",
                "model_revision": "preview-model-v1", "current_model_revision": "preview-model-v1",
                "source_title": "Evening light — official recording", "source_provider": "bandcamp"]
            if args.contains("--song-developer-unknown") && !complete {
                info.removeValue(forKey: "analyzed_at")
                info.removeValue(forKey: "analysis_version")
                info.removeValue(forKey: "versions_behind")
            }
            return decode(["job": ["state": "ready", "worker_online": true], "library_generation": "preview",
                "analysis_info": info,
                "analysis_job": ["state": jobState, "stage": elapsed < 6 ? "downloading" : "aligning", "worker_online": true,
                    "message": "The recording could not be downloaded. Your previous chart is still available."],
                "analysis": ["source": "bandcamp", "audio_duration": 40, "song_duration": 40,
                    "audio_sha256": complete ? "new-preview-recording" : "old-preview-recording", "chart_revision": revision,
                    "chords": [["start": 0, "end": 40, "label": complete ? "D:min" : "C:maj"]]]])
        }
        let initial = payload()
        return SongSheetStore(song: song, analysis: initial.analysis, service: .init(
            request: { _ in payload() }, status: { _ in payload() }, lyrics: { _ in nil },
            reanalyze: { _, _ in requestedAt = .now; return payload() }))
    }

    @MainActor private static func makeStore() -> SongSheetStore {
        if ProcessInfo.processInfo.arguments.contains("--song-developer-preview") { return developerToolsStore() }
        if ProcessInfo.processInfo.arguments.contains("--mixed-word-timing-preview") { return mixedWordTimingStore() }
        if ProcessInfo.processInfo.arguments.contains("--independent-chords-preview") { return independentTimingStore() }
        if ProcessInfo.processInfo.arguments.contains("--phrase-boundary-preview") { return phraseBoundaryStore() }

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
                         "tempo": tempo, "chart_revision": "preview-original", "chord_review": [
                             ["start": 6, "end": 12, "label": "G:7", "alternatives": ["G:maj", "D:min7"],
                              "needs_review": true, "reason": "Close alternatives"]]]
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
        let song = SongDescriptor(trackID: "offline-preview", title: arguments.contains("--practice-setup-preview") ? "Love by the Hour" : mapPreview ? "Song map · sample" : "Song sheet preview",
                                  artist: arguments.contains("--practice-setup-preview") ? "" : "Offline regression fixture", duration: 40)
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
        return SongSheetStore(song: song, analysis: arguments.contains("--practice-setup-preview") ? status.analysis : chart,
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
                                             applyPassage: { _, _ in
            history.append(raw(status.analysis!))
            return publish([["start": 0, "end": 6, "label": "C:maj"], ["start": 6, "end": 9, "label": "G:7"],
                            ["start": 9, "end": 12, "label": "D:min7"], ["start": 12, "end": 20, "label": "A:min"],
                            ["start": 20, "end": 40, "label": "F:maj7"]])
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
