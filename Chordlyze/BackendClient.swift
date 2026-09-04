import Foundation

struct Difficulty: Decodable {
    let score: Double  // 1…10
    let level: String  // "easy" | "medium" | "hard"
}

struct ChordAnalysis: Decodable {
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

    struct Tempo: Decodable {
        let bpm: Double
        let beats: [Double]
    }

    enum CodingKeys: String, CodingKey {
        case key
        case keyConfidence = "key_confidence"
        case analyzedEnd = "analyzed_end"
        case chords, source, difficulty, tempo
    }

    /// Last second the chords cover. Playback past it has no chord information.
    var coverageEnd: Double { analyzedEnd ?? chords.last?.end ?? 0 }
    /// 30 s excerpt at an unknown offset in the song: its chords cannot be
    /// placed on the song's timeline at all.
    var isPreview: Bool { source == "itunes_preview" }
}

struct WordStamp: Decodable {
    let time: Double
    let text: String
}

struct LyricLine: Decodable, Identifiable {
    let time: Double
    let text: String
    /// Per-word timestamps when the lyrics source has enhanced (A2) LRC.
    let words: [WordStamp]?
    var id: Double { time }
}

struct ChordSegment: Decodable, Identifiable {
    let start: Double
    let end: Double
    let label: String
    let roman: String?

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
    /// Saved analysis for a track, by any source; the ISRC lets the backend
    /// find an analysis saved under another id for the same recording.
    /// nil when none is saved.
    static func cachedAnalysis(trackID: String, isrc: String? = nil) async throws -> ChordAnalysis? {
        var comps = URLComponents(url: Config.backendBaseURL.appendingPathComponent("analysis/track/\(trackID)"),
                                  resolvingAgainstBaseURL: false)!
        if let isrc { comps.queryItems = [.init(name: "isrc", value: isrc)] }
        return try await fetch(URLRequest(url: comps.url!))
    }

    struct LibraryItem: Decodable, Identifiable {
        let trackId: String
        let title: String?
        let artist: String?
        let key: String?
        let artwork: String?
        let difficulty: Difficulty?
        var id: String { trackId }
        enum CodingKeys: String, CodingKey {
            case trackId = "track_id", title, artist, key, artwork, difficulty
        }

        /// iTunes thumb upscaled for retina 46pt rows.
        var artworkURL: URL? {
            artwork.map { $0.replacingOccurrences(of: "100x100", with: "200x200") }
                .flatMap(URL.init)
        }
    }

    /// All analyses ever saved, newest first.
    static func library() async throws -> [LibraryItem] {
        struct Page: Decodable { let items: [LibraryItem] }
        let url = Config.backendBaseURL.appendingPathComponent("library")
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(Page.self, from: data).items
    }

    struct LyricsResult: Decodable {
        let lines: [LyricLine]
        /// False when line times were synthesized from unsynced lyrics.
        let synced: Bool
        /// "exact" | "fuzzy" — how the song was matched on the lyrics source.
        let matched: String?

        /// Barely-visible disclosure for non-exact lyrics (beta).
        var betaNote: String? {
            if !synced { return "lyrics not synced — not from Spotify · beta" }
            if matched == "fuzzy" { return "lyrics matched externally — not from Spotify · beta" }
            return nil
        }
    }

    /// Time-synced lyrics; nil when the song has none. `duration` is the
    /// length of the recording the chords sit on (Spotify's, else the
    /// analyzed audio's) and gates the match to that edition of the song;
    /// the sheet and the live view must ask with the same values or they
    /// get different answers.
    static func lyrics(title: String, artist: String,
                       duration: Double, album: String?) async throws -> LyricsResult? {
        var comps = URLComponents(url: Config.backendBaseURL.appendingPathComponent("lyrics"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "title", value: title), .init(name: "artist", value: artist),
                            .init(name: "duration", value: String(Int(duration)))]
        if let album { comps.queryItems?.append(.init(name: "album", value: album)) }
        return try await fetch(URLRequest(url: comps.url!))
    }

    /// Chords for a song with no audio from the device: the saved analysis
    /// when there is one, else a fresh one from the 30 s iTunes preview
    /// (the ingest worker upgrades it to the whole song later). nil when the
    /// song is found nowhere.
    static func analyzeTrack(trackID: String, isrc: String?,
                             title: String?, artist: String?,
                             durationMs: Int? = nil, itunesID: Int? = nil) async throws -> ChordAnalysis? {
        var req = URLRequest(url: Config.backendBaseURL.appendingPathComponent("analyze_track"))
        req.httpMethod = "POST"
        let boundary = "chordlyze-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 180
        var body = Data()
        let fields: [(String, String?)] = [("track_id", trackID), ("isrc", isrc),
                                           ("title", title), ("artist", artist),
                                           ("duration", durationMs.map { String(Double($0) / 1000) }),
                                           ("itunes_id", itunesID.map(String.init))]
        for (name, value) in fields {
            guard let value else { continue }
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        return try await fetch(req)
    }

    /// Same, for a Spotify track.
    static func analyzeTrack(_ track: Track) async throws -> ChordAnalysis? {
        try await analyzeTrack(trackID: track.id, isrc: track.isrc,
                               title: track.name, artist: track.artistNames,
                               durationMs: track.durationMs)
    }

    /// `operation` again on a transport or 5xx failure, with a short pause
    /// between tries; a nil (404) result returns at once.
    static func retrying<T>(attempts: Int = 3,
                            _ operation: () async throws -> T?) async throws -> T? {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if attempt >= attempts { throw error }
                attempt += 1
                try await Task.sleep(for: .seconds(2 * attempt))
            }
        }
    }

    /// nil on 404; throws BackendError on any other non-200 response.
    private static func fetch<T: Decodable>(_ request: URLRequest) async throws -> T? {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200 else {
            throw BackendError(status: status, detail: String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Practice

    struct PracticeReport: Decodable, Identifiable {
        struct ChordScore: Decodable, Identifiable {
            let name: String
            let accuracy: Double
            let count: Int
            var id: String { name }
        }
        struct Transition: Decodable, Identifiable {
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
        struct Section: Decodable {
            let start: Double
            let end: Double
            let accuracy: Double?
        }
        let takeId: String
        let accuracy: Double
        let avgLag: Double?
        let avgTimingError: Double?
        let comparison: String?
        let perChord: [ChordScore]
        let transitions: [Transition]
        let sections: [Section]
        var id: String { takeId }
        enum CodingKeys: String, CodingKey {
            case accuracy, transitions, sections, comparison
            case takeId = "take_id"
            case avgLag = "avg_lag"
            case avgTimingError = "avg_timing_error"
            case perChord = "per_chord"
        }
    }

    /// Upload a practice recording; the backend scores it against the track's chart.
    /// `offset`: song second that take second 0 corresponds to (Spotify sync).
    static func submitPracticeTake(fileURL: URL, trackID: String, offset: Double) async throws -> PracticeReport {
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
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"take.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "Chordlyze", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Scoring failed: \(detail)"])
        }
        return try JSONDecoder().decode(PracticeReport.self, from: data)
    }
}
