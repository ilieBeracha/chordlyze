import Foundation

struct SongDescriptor: Codable, Hashable, Identifiable {
    let trackID: String
    var title: String
    var artist: String
    var album: String? = nil
    var duration: Double? = nil
    var isrc: String? = nil
    var artwork: String? = nil
    var itunesID: Int? = nil
    var id: String { trackID }
    enum CodingKeys: String, CodingKey {
        case trackID = "track_id", title, artist, album, duration, isrc, artwork
        case itunesID = "itunes_id"
    }
}

struct SongStatus: Decodable {
    struct Metadata: Decodable {
        let title: String?
        let artist: String?
        let album: String?
        let duration: Double?
    }
    struct Job: Decodable {
        let state: String
        let stage: String?
        let message: String?
        let workerOnline: Bool
        /// Earlier requests still waiting, while queued.
        let ahead: Int?
        enum CodingKeys: String, CodingKey {
            case state, stage, message, ahead, workerOnline = "worker_online"
        }
    }
    let song: Metadata?
    let analysis: ChordAnalysis?
    /// Word-timed lyrics aligned to the analyzed recording, when the worker made them.
    let lyrics: BackendClient.LyricsResult?
    let job: Job
    var lyricsJob: Job? = nil
    let libraryGeneration: String
    /// Whether this song is in the signed-in account's library.
    let saved: Bool?
    /// This account's calibration of the chart to the Spotify recording.
    let timing: TimingMap?
    var timingRevision: String? = nil
    enum CodingKeys: String, CodingKey {
        case timingRevision = "timing_revision"
        case lyricsJob = "lyrics_job"
        case song, analysis, lyrics, job, saved, timing, libraryGeneration = "library_generation"
    }
}

struct Difficulty: Decodable, Equatable {
    let score: Double  // 1…10
    let level: String  // "easy" | "medium" | "hard"
}

struct ChordAnalysis: Decodable, Equatable {
    let key: String?
    let keyConfidence: Double?
    let chords: [ChordSegment]
    /// "itunes_preview" | "youtube"; nil on entries saved before it existed.
    let source: String?
    /// Seconds of audio the chords describe; nil on entries saved before the field.
    let analyzedEnd: Double?
    let difficulty: Difficulty?
    /// Beat grid on the chord timeline; nil for analyses made before beat tracking.
    let tempo: Tempo?
    let audioDuration: Double?
    let songDuration: Double?
    let album: String?
    /// Identity of the analyzed recording; a calibration is tied to it.
    let audioSha256: String?
    var chartRevision: String? = nil
    var correctionsStale: Bool? = nil
    var canUndo: Bool? = nil
    var boundariesEdited: Bool? = nil
    var chordReview: [ChordReview]? = nil

    struct Tempo: Decodable, Equatable {
        let bpm: Double
        let beats: [Double]
        var beatPositions: [Int]? = nil
        var bars: [Bar]? = nil
        var sections: [Section]? = nil
        var rhythmVersion: Int? = nil
        var rhythmModel: String? = nil
        var structureModel: String? = nil

        enum CodingKeys: String, CodingKey {
            case bpm, beats, bars, sections
            case beatPositions = "beat_positions", rhythmVersion = "rhythm_version"
            case rhythmModel = "rhythm_model", structureModel = "structure_model"
        }
        struct Bar: Decodable, Equatable {
            let start: Double
            let end: Double
            let beats: Int
        }
        struct Section: Decodable, Equatable, Identifiable {
            let start: Double
            let end: Double
            let startBar: Int
            let endBar: Int
            let label: String
            let occurrence: Int
            var id: Double { start }
            var title: String { "Section \(label) · \(occurrence)" }
            enum CodingKeys: String, CodingKey {
                case start, end, label, occurrence
                case startBar = "start_bar", endBar = "end_bar"
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case key
        case keyConfidence = "key_confidence"
        case analyzedEnd = "analyzed_end"
        case audioDuration = "audio_duration", songDuration = "song_duration", audioSha256 = "audio_sha256"
        case chords, source, difficulty, tempo, album
        case chartRevision = "chart_revision", correctionsStale = "corrections_stale"
        case canUndo = "can_undo", boundariesEdited = "boundaries_edited", chordReview = "chord_review"
    }

    /// Last second the chords cover. Playback past it has no chord information.
    var coverageEnd: Double { audioDuration ?? analyzedEnd ?? chords.last?.end ?? 0 }
    /// 30 s excerpt at an unknown offset in the song: its chords cannot be
    /// placed on the song's timeline at all.
    var isPreview: Bool { source == "itunes_preview" }
}

struct ChordReview: Decodable, Equatable {
    let start: Double
    let end: Double
    let label: String
    let alternatives: [String]
    let needsReview: Bool
    let reason: String
    enum CodingKeys: String, CodingKey {
        case start, end, label, alternatives, reason, needsReview = "needs_review"
    }
    func matches(_ segment: ChordSegment) -> Bool {
        abs(start - segment.start) < 0.000001 && abs(end - segment.end) < 0.000001 && label == segment.label
    }
}

struct PassageJob: Decodable, Equatable {
    let id: String
    let state: String
    let message: String?
    let start: Double
    let end: Double
    let chartRevision: String
    let segments: [ChordSegment]?
    let protectedCount: Int?
    let applied: Bool?
    var pending: Bool { state == "queued" || state == "processing" }
    enum CodingKeys: String, CodingKey {
        case id, state, message, start, end, segments, applied
        case chartRevision = "chart_revision", protectedCount = "protected_count"
    }
}

struct WordStamp: Decodable, Equatable {
    let time: Double
    let text: String
    /// When the word stops sounding; nil when the transcript did not hear it.
    var end: Double? = nil
    /// Interpolated transcript words preserve layout, but cannot establish a
    /// sung-word highlight, a chord anchor, or a vocal rest.
    var estimated: Bool? = nil
    var hasMeasuredOnset: Bool { estimated == false || (estimated == nil && end != nil) }
    var measuredEnd: Double? { estimated == true ? nil : end }
}

struct LyricLine: Decodable, Identifiable, Equatable {
    let time: Double
    let text: String
    /// Per-word timestamps when the lyrics source has enhanced (A2) LRC.
    let words: [WordStamp]?
    var id: Double { time }
}

struct ChordSegment: Decodable, Identifiable, Equatable {
    let start: Double
    let end: Double
    let label: String
    let roman: String?
    var originalLabel: String? = nil
    enum CodingKeys: String, CodingKey {
        case start, end, label, roman, originalLabel = "original_label"
    }

    var id: Double { start }
    var duration: Double { end - start }

    /// Parsed label; nil for "N" (no chord).
    var chord: Chord? { Chord(label: label) }

    /// "C:maj" -> "C", "A:min7" -> "Am7", "N" -> "N.C." An unparsable label
    /// shows as-is rather than as some other chord.
    var displayName: String {
        chord?.display ?? (label == "N" ? "N.C." : label)
    }
}

/// The backend said no (anything but 200/404) or could not be reached.
/// Callers retry these; a 404 is a plain `nil` result, never an error.
struct BackendError: LocalizedError {
    let status: Int
    let detail: String
    var errorDescription: String? { "Backend returned \(status): \(detail)" }
}

enum BackendClient {
    struct LibraryItem: Decodable, Identifiable {
        let trackId: String
        let title: String?
        let artist: String?
        let key: String?
        let artwork: String?
        let difficulty: Difficulty?
        let album: String?
        let duration: Double?
        let isrc: String?
        /// iTunes primary genre, when the catalog matched the recording.
        let genre: String?
        let tempoBpm: Double?
        /// Distinct chords in the chart.
        let chordCount: Int?
        var id: String { trackId }
        enum CodingKeys: String, CodingKey {
            case trackId = "track_id", title, artist, key, artwork, difficulty, album, duration, isrc, genre
            case tempoBpm = "tempo_bpm", chordCount = "chord_count"
        }

        /// iTunes thumb upscaled for retina 46pt rows.
        var artworkURL: URL? {
            artwork.map { $0.replacingOccurrences(of: "100x100", with: "200x200") }
                .flatMap(URL.init)
        }
    }

    /// Every backend call carries the account's Spotify access token; the
    /// backend verifies it with Spotify and scopes libraries to that account.
    /// Set once at launch. nil means signed out: calls fail explicitly.
    static var tokenProvider: (() async throws -> String)?

    private static func authorized(_ request: URLRequest) async throws -> URLRequest {
        guard let tokenProvider else { throw BackendError(status: 401, detail: "Sign in with Spotify to use Chordlyze.") }
        var request = request
        request.setValue("Bearer \(try await tokenProvider())", forHTTPHeaderField: "Authorization")
        return request
    }

    private struct LibraryPage: Decodable { let items: [LibraryItem] }

    /// The account's songs: requested, saved or practiced. Newest first.
    static func library() async throws -> [LibraryItem] {
        let url = Config.backendBaseURL.appendingPathComponent("library")
        let page: LibraryPage? = try await fetch(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        return page?.items ?? []
    }

    /// Every chart on the server, from any account. Charts are per song, so
    /// a song someone else analyzed is ready for everyone.
    static func catalog() async throws -> [LibraryItem] {
        let url = Config.backendBaseURL.appendingPathComponent("catalog")
        let page: LibraryPage? = try await fetch(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        return page?.items ?? []
    }

    /// Saves or clears the account's timing calibration for a song.
    static func setTiming(trackID: String, _ timing: TimingMap?) async throws {
        struct Result: Decodable { let trackId: String; enum CodingKeys: String, CodingKey { case trackId = "track_id" } }
        var request = URLRequest(url: Config.backendBaseURL.appendingPathComponent("library/\(trackID)/timing"),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = timing == nil ? "DELETE" : "PUT"
        if let timing {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(timing)
        }
        guard let _: Result = try await fetch(request) else {
            throw BackendError(status: 404, detail: "This song has no chart to calibrate yet.")
        }
    }

    /// Adds or removes one song in the account's library; the chart itself stays.
    static func setSaved(trackID: String, _ saved: Bool) async throws {
        struct Result: Decodable { let saved: Bool }
        var request = URLRequest(url: Config.backendBaseURL.appendingPathComponent("library/\(trackID)"),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = saved ? "POST" : "DELETE"
        guard let result: Result = try await fetch(request), result.saved == saved else {
            throw BackendError(status: 404, detail: "This song has no chart to save yet.")
        }
    }

    struct LyricsResult: Decodable, Equatable {
        let lines: [LyricLine]
        /// False when line times were synthesized from unsynced lyrics.
        let synced: Bool
        /// "exact" | "fuzzy" — how the song was matched on the lyrics source.
        let matched: String?
        let instrumental: Bool?
        var timingNote: String? = nil
        enum CodingKeys: String, CodingKey {
            case lines, synced, matched, instrumental
            case timingNote = "timing_note"
        }

        /// Barely-visible disclosure for non-exact lyrics (beta).
        var betaNote: String? {
            if let timingNote { return timingNote }
            if !synced { return "Lyrics timing is approximate." }
            if matched == "fuzzy" { return "Lyrics matched by song, artist and duration." }
            return nil
        }
    }

    /// Time-synced lyrics; nil when the song has none. `duration` is the
    /// length of the recording the chords sit on (Spotify's, else the
    /// analyzed audio's) and gates the match to that edition of the song;
    /// the sheet and the live view must ask with the same values or they
    /// get different answers.
    static func lyrics(title: String, artist: String,
                       duration: Double?, album: String?) async throws -> LyricsResult? {
        var comps = URLComponents(url: Config.backendBaseURL.appendingPathComponent("lyrics"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "title", value: title), .init(name: "artist", value: artist)]
        if let duration, duration.isFinite, duration > 0 {
            comps.queryItems?.append(.init(name: "duration", value: String(duration)))
        }
        if let album { comps.queryItems?.append(.init(name: "album", value: album)) }
        return try await fetch(URLRequest(url: comps.url!, cachePolicy: .reloadIgnoringLocalCacheData,
                                          timeoutInterval: 50))
    }

    /// nil on 404; throws BackendError on any other non-200 response.
    private static func fetch<T: Decodable>(_ request: URLRequest) async throws -> T? {
        let (data, response) = try await URLSession.shared.data(for: authorized(request))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200 else {
            throw BackendError(status: status, detail: String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func requestSong(_ song: SongDescriptor, retry: Bool = false) async throws -> SongStatus {
        var request = URLRequest(url: Config.backendBaseURL.appendingPathComponent("song/request"),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(song)) as! [String: Any]
        payload["retry"] = retry
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        guard let result: SongStatus = try await fetch(request) else {
            throw BackendError(status: 404, detail: "Song request unavailable")
        }
        return result
    }

    static func songStatus(trackID: String) async throws -> SongStatus {
        let request = URLRequest(url: Config.backendBaseURL.appendingPathComponent("song/\(trackID)"),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        guard let result: SongStatus = try await fetch(request) else {
            throw BackendError(status: 404, detail: "Song request unavailable")
        }
        return result
    }

    static func requestLyricTiming(trackID: String) async throws -> SongStatus {
        var request = URLRequest(url: Config.backendBaseURL.appendingPathComponent("song/\(trackID)/lyrics/request"),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["retry": true])
        guard let result: SongStatus = try await fetch(request) else {
            throw BackendError(status: 404, detail: "Lyric timing is not available on this service yet.")
        }
        return result
    }

    static func correctChord(trackID: String, segment: ChordSegment, name: String?, revision: String) async throws -> SongStatus {
        var request = URLRequest(url: Config.backendBaseURL.appendingPathComponent("library/\(trackID)/chords"),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "chart_revision": revision, "start": segment.start, "end": segment.end,
            "name": name.map { $0 as Any } ?? NSNull()])
        guard let result: SongStatus = try await fetch(request) else {
            throw BackendError(status: 404, detail: "This song has no chart to correct yet.")
        }
        return result
    }

    private struct PassageEnvelope: Decodable { let job: PassageJob? }

    static func passage(trackID: String, start: Double? = nil, end: Double? = nil, revision: String? = nil) async throws -> PassageJob? {
        var request = URLRequest(url: Config.backendBaseURL.appendingPathComponent("library/\(trackID)/passage-analysis"),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        if let start, let end, let revision {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["start": start, "end": end, "chart_revision": revision])
        }
        guard let result: PassageEnvelope = try await fetch(request) else {
            throw BackendError(status: 404, detail: "Passage analysis is unavailable on this server.")
        }
        return result.job
    }

    static func cancelPassage(trackID: String, id: String) async throws -> PassageJob? {
        var request = URLRequest(url: Config.backendBaseURL.appendingPathComponent("library/\(trackID)/passage-analysis/\(id)"), timeoutInterval: 20)
        request.httpMethod = "DELETE"
        guard let result: PassageEnvelope = try await fetch(request) else {
            throw BackendError(status: 404, detail: "This preparation is no longer available.")
        }
        return result.job
    }

    static func applyPassage(trackID: String, job: PassageJob) async throws -> SongStatus {
        var request = URLRequest(url: Config.backendBaseURL.appendingPathComponent("library/\(trackID)/passage-analysis/apply"), timeoutInterval: 25)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["id": job.id, "chart_revision": job.chartRevision])
        guard let result: SongStatus = try await fetch(request) else {
            throw BackendError(status: 404, detail: "This passage result is no longer available.")
        }
        return result
    }

    struct BoundaryEdit: Encodable {
        enum Operation: String, Encodable { case move, split, merge, undo, restore }
        let operation: Operation
        var start: Double? = nil
        var end: Double? = nil
        var at: Double? = nil
        var edge = "end"
        var name: String? = nil
        var chartRevision: String
        enum CodingKeys: String, CodingKey {
            case operation, start, end, at, edge, name, chartRevision = "chart_revision"
        }
    }

    static func editBoundary(trackID: String, edit: BoundaryEdit) async throws -> SongStatus {
        var request = URLRequest(url: Config.backendBaseURL.appendingPathComponent("library/\(trackID)/chords/boundary"), timeoutInterval: 20)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(edit)
        guard let result: SongStatus = try await fetch(request) else {
            throw BackendError(status: 404, detail: "No chart to edit yet.")
        }
        return result
    }

    struct SyncClip {
        let file: URL
        let spotifyStart: Double
    }

    static func synchronizationRequest(trackID: String, clips: [SyncClip], chartRevision: String, timingRevision: String) throws -> URLRequest {
        let boundary = "chordlyze-sync-\(UUID().uuidString)"
        var request = URLRequest(url: Config.backendBaseURL.appendingPathComponent("library/\(trackID)/synchronize"), timeoutInterval: 240)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var data = Data()
        func append(_ text: String) { data.append(Data(text.utf8)) }
        let positions = String(data: try JSONEncoder().encode(clips.map(\.spotifyStart)), encoding: .utf8)!
        for (name, value) in [("positions", positions), ("chart_revision", chartRevision), ("timing_revision", timingRevision)] {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        for clip in clips {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"sample.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n")
            data.append(try Data(contentsOf: clip.file))
            append("\r\n")
        }
        append("--\(boundary)--\r\n")
        request.httpBody = data
        return request
    }

    static func synchronize(trackID: String, clips: [SyncClip], chartRevision: String, timingRevision: String) async throws -> SongStatus {
        guard let result: SongStatus = try await fetch(synchronizationRequest(trackID: trackID, clips: clips, chartRevision: chartRevision, timingRevision: timingRevision)) else {
            throw BackendError(status: 404, detail: "No chart to synchronize yet.")
        }
        return result
    }

    // MARK: - Practice

    struct PracticeReport: Codable, Identifiable {
        struct ChordScore: Codable, Identifiable {
            let name: String
            let accuracy: Double
            let count: Int
            var id: String { name }
        }
        struct Transition: Codable, Identifiable {
            let from: String
            let to: String
            let avgLag: Double?
            let avgOffset: Double?
            let avgTimingError: Double?
            let misses: Int
            let count: Int
            var id: String { "\(from)>\(to)" }
            var timingError: Double? { avgTimingError ?? avgLag }
            var timingLabel: String? {
                guard let error = timingError else { return nil }
                if error < 0.05 { return "on time" }
                let offset = avgOffset ?? avgLag ?? 0
                // Opposing early/late changes can cancel in the signed mean.
                if error - abs(offset) > 0.05 {
                    return String(format: "%.1fs off", error)
                }
                return String(format: offset < 0 ? "%.1fs early" : "%.1fs late", error)
            }
            enum CodingKeys: String, CodingKey {
                case from, to, misses, count
                case avgLag = "avg_lag"
                case avgOffset = "avg_offset"
                case avgTimingError = "avg_timing_error"
            }
        }
        struct Section: Codable {
            let start: Double
            let end: Double
            let accuracy: Double?
        }
        let takeId: String
        let accuracy: Double
        let avgLag: Double?
        let avgTimingError: Double?
        let comparison: String?
        let transpose: Int?
        let playbackRate: Double?
        let timingScale: Double?
        var referenceChartRevision: String? = nil
        let matchedChanges: Int?
        let totalChanges: Int?
        let consistentOffset: ConsistentOffset?
        struct ConsistentOffset: Codable {
            let seconds: Double
            let spread: Double
            let samples: Int
        }
        var changeMatchRate: Double? {
            guard let matchedChanges, let totalChanges, totalChanges > 0 else { return nil }
            return Double(matchedChanges) / Double(totalChanges)
        }
        var displayScore: Double { changeMatchRate ?? accuracy }
        var scoreLabel: String { changeMatchRate == nil ? "time matching chart" : "chord changes matched" }
        let perChord: [ChordScore]
        let transitions: [Transition]
        let sections: [Section]
        var id: String { takeId }
        enum CodingKeys: String, CodingKey {
            case accuracy, transitions, sections, comparison, transpose
            case playbackRate = "playback_rate"
            case timingScale = "timing_scale"
            case referenceChartRevision = "reference_chart_revision"
            case matchedChanges = "matched_changes", totalChanges = "total_changes"
            case consistentOffset = "consistent_offset"
            case takeId = "take_id"
            case avgLag = "avg_lag"
            case avgTimingError = "avg_timing_error"
            case perChord = "per_chord"
        }
    }

    /// Upload a practice recording; the backend scores it against the track's chart.
    /// `offset`: song second that take second 0 corresponds to (Spotify sync).
    static func submitPracticeTake(fileURL: URL, trackID: String, offset: Double, transpose: Int = 0, playbackRate: Double = 1, timingScale: Double = 1, chartRevision: String? = nil) async throws -> PracticeReport {
        let request = try await authorized(practiceTakeRequest(fileURL: fileURL, trackID: trackID, offset: offset,
            transpose: transpose, playbackRate: playbackRate, timingScale: timingScale, chartRevision: chartRevision))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw BackendError(status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                detail: "Scoring failed: \(detail)")
        }
        return try practiceReport(data, transpose: transpose, playbackRate: playbackRate, timingScale: timingScale, chartRevision: chartRevision)
    }

    static func practiceTakeRequest(fileURL: URL, trackID: String, offset: Double,
                                    transpose: Int, playbackRate: Double, timingScale: Double = 1, chartRevision: String? = nil) throws -> URLRequest {
        let boundary = "chordlyze-\(UUID().uuidString)"
        var req = URLRequest(url: Config.backendBaseURL.appendingPathComponent("practice_take"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 600
        let fileData = try Data(contentsOf: fileURL)
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"track_id\"\r\n\r\n\(trackID)\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"offset\"\r\n\r\n\(offset)\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"transpose\"\r\n\r\n\(transpose)\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"playback_rate\"\r\n\r\n\(playbackRate)\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"timing_scale\"\r\n\r\n\(timingScale)\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        if let chartRevision {
            body.append("Content-Disposition: form-data; name=\"chart_revision\"\r\n\r\n\(chartRevision)\r\n".data(using: .utf8)!)
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
        }
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"take.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        return req
    }

    static func practiceReport(_ data: Data, transpose: Int, playbackRate: Double, timingScale: Double = 1, chartRevision: String? = nil) throws -> PracticeReport {
        let report = try JSONDecoder().decode(PracticeReport.self, from: data)
        if let chartRevision, report.referenceChartRevision != chartRevision {
            throw BackendError(status: 409, detail: "The service did not score the chart used for this take. Your audio is saved.")
        }
        guard ((report.transpose ?? 0) == transpose),
              ((report.playbackRate ?? 1) == playbackRate), ((report.timingScale ?? 1) == timingScale) else {
            throw BackendError(status: 409, detail: "Scoring needs a service update for this key or pace. Your take is saved; retry after the service is updated.")
        }
        return report
    }
}
