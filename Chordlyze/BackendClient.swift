import Foundation

struct ChordAnalysis: Decodable {
    let key: String?
    let keyConfidence: Double?
    let chords: [ChordSegment]
    let source: String?  // "itunes_preview" when analyzed from a preview excerpt

    enum CodingKeys: String, CodingKey {
        case key
        case keyConfidence = "key_confidence"
        case chords, source
    }
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

    /// "C:maj" -> "C", "A:min" -> "Am", "N" -> "N.C."
    var displayName: String {
        if label == "N" { return "N.C." }
        let parts = label.split(separator: ":")
        let root = String(parts[0])
        let quality = parts.count > 1 ? String(parts[1]) : "maj"
        switch quality {
        case "maj": return root
        case "min": return root + "m"
        case "dim": return root + "°"
        default: return root + quality
        }
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
        var id: String { trackId }
        enum CodingKeys: String, CodingKey {
            case trackId = "track_id", title, artist, key, artwork
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

    /// Server-side analysis from the song's public iTunes preview — no audio needed
    /// from the device. Returns nil if the song isn't on iTunes.
    static func analyzeTrack(trackID: String, isrc: String?,
                             title: String?, artist: String?) async -> ChordAnalysis? {
        var req = URLRequest(url: Config.backendBaseURL.appendingPathComponent("analyze_track"))
        req.httpMethod = "POST"
        let boundary = "chordlyze-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 180
        var body = Data()
        let fields: [(String, String?)] = [("track_id", trackID), ("isrc", isrc),
                                           ("title", title), ("artist", artist)]
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
