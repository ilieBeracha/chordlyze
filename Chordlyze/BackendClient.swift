import Foundation

struct Difficulty: Decodable {
    let score: Double  // 1…10
    let level: String  // "easy" | "medium" | "hard"
}

struct ChordAnalysis: Decodable {
    let key: String?
    let keyConfidence: Double?
    let chords: [ChordSegment]
    /// "itunes_preview" | "youtube" | "upload"; nil on entries saved before it existed.
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

enum BackendClient {
    /// Instant result if this track was analyzed before — by any source; the
    /// ISRC lets the backend match analyses made via mic capture too.
    static func cachedAnalysis(trackID: String, isrc: String? = nil) async -> ChordAnalysis? {
        var comps = URLComponents(url: Config.backendBaseURL.appendingPathComponent("analysis/track/\(trackID)"),
                                  resolvingAgainstBaseURL: false)!
        if let isrc { comps.queryItems = [.init(name: "isrc", value: isrc)] }
        guard let (data, response) = try? await URLSession.shared.data(from: comps.url!),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(ChordAnalysis.self, from: data)
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

    struct LyricsResult {
        let lines: [LyricLine]
        /// False when line times were synthesized from unsynced lyrics.
        let synced: Bool
        /// "exact" | "fuzzy" — how the song was matched on the lyrics source.
        let matched: String?

        /// Barely-visible disclosure for non-exact lyrics (beta).
        var betaNote: String? {
            if !synced { return "lyrics not synced — not from Spotify · beta" }
            if matched == "fuzzy" { return "lyrics matched externally — not from Spotify · beta" }
            if matched == "aligned" { return "lyrics timed from song audio · beta" }
            return nil
        }
    }

    /// Time-synced lyrics; nil when the song has none. Duration/album narrow
    /// the match to the right version of the song.
    static func lyrics(title: String, artist: String,
                       duration: Double? = nil, album: String? = nil) async -> LyricsResult? {
        struct Response: Decodable { let lines: [LyricLine]; let synced: Bool?; let matched: String? }
        var comps = URLComponents(url: Config.backendBaseURL.appendingPathComponent("lyrics"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "title", value: title), .init(name: "artist", value: artist)]
        if let duration { comps.queryItems?.append(.init(name: "duration", value: String(Int(duration)))) }
        if let album { comps.queryItems?.append(.init(name: "album", value: album)) }
        guard let (data, response) = try? await URLSession.shared.data(from: comps.url!),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let parsed = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return LyricsResult(lines: parsed.lines, synced: parsed.synced ?? true,
                            matched: parsed.matched)
    }

    /// Server-side analysis, no audio needed from the device: the whole song
    /// from a matching upload when `durationMs` finds one, else the 30 s
    /// iTunes preview. Returns nil if the song is found nowhere.
    static func analyzeTrack(trackID: String, isrc: String?,
                             title: String?, artist: String?,
                             durationMs: Int? = nil) async -> ChordAnalysis? {
        var req = URLRequest(url: Config.backendBaseURL.appendingPathComponent("analyze_track"))
        req.httpMethod = "POST"
        let boundary = "chordlyze-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 180
        var body = Data()
        let fields: [(String, String?)] = [("track_id", trackID), ("isrc", isrc),
                                           ("title", title), ("artist", artist),
                                           ("duration", durationMs.map { String(Double($0) / 1000) })]
        for (name, value) in fields {
            guard let value else { continue }
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(ChordAnalysis.self, from: data)
    }

    /// Upload an audio file and get its chord analysis.
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
            let misses: Int
            let count: Int
            var id: String { "\(from)>\(to)" }
            enum CodingKeys: String, CodingKey {
                case from, to, misses, count
                case avgLag = "avg_lag"
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
        let perChord: [ChordScore]
        let transitions: [Transition]
        let sections: [Section]
        var id: String { takeId }
        enum CodingKeys: String, CodingKey {
            case accuracy, transitions, sections
            case takeId = "take_id"
            case avgLag = "avg_lag"
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

    static func analyze(fileURL: URL, trackID: String? = nil,
                        title: String? = nil, artist: String? = nil) async throws -> ChordAnalysis {
        let boundary = "chordlyze-\(UUID().uuidString)"
        var req = URLRequest(url: Config.backendBaseURL.appendingPathComponent("analyze"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 600

        let needsScopedAccess = fileURL.startAccessingSecurityScopedResource()
        defer { if needsScopedAccess { fileURL.stopAccessingSecurityScopedResource() } }
        let fileData = try Data(contentsOf: fileURL)

        var body = Data()
        let fields: [(String, String?)] = [("track_id", trackID), ("title", title), ("artist", artist)]
        for (name, value) in fields {
            guard let value else { continue }
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "Chordlyze", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Analysis failed: \(detail)"])
        }
        return try JSONDecoder().decode(ChordAnalysis.self, from: data)
    }
}
