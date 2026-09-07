import Foundation

struct Playlist: Identifiable, Decodable {
    let id: String
    let name: String
    let images: [SpotifyImage]?
    let tracks: TrackRef?  // Spotify omits/nulls this on some playlist objects
    struct TrackRef: Decodable { let total: Int }
}

struct SpotifyImage: Decodable { let url: String }

struct Track: Identifiable, Decodable {
    let id: String
    let name: String
    let artists: [Artist]
    let album: Album
    let externalIds: ExternalIds?
    let durationMs: Int?
    struct Artist: Decodable { let name: String }
    struct Album: Decodable {
        let name: String
        let images: [SpotifyImage]?
        /// Largest image Spotify lists first.
        var artworkURL: URL? { (images?.first?.url).flatMap(URL.init) }
    }
    struct ExternalIds: Decodable { let isrc: String? }

    enum CodingKeys: String, CodingKey {
        case id, name, artists, album
        case externalIds = "external_ids"
        case durationMs = "duration_ms"
    }

    var artistNames: String { artists.map(\.name).joined(separator: ", ") }
    var isrc: String? { externalIds?.isrc }
}

@MainActor
final class SpotifyAPI: ObservableObject {
    private let token: () async throws -> String
    private let refreshRejectedToken: (String) async throws -> String
    private let session: URLSession

    init(auth: SpotifyAuth) {
        token = { try await auth.validToken() }
        refreshRejectedToken = { try await auth.validToken(rejecting: $0) }
        session = .shared
    }

    /// Inject transport and token handling to exercise real HTTP contracts offline.
    init(session: URLSession, token: @escaping () async throws -> String,
         refreshRejectedToken: @escaping (String) async throws -> String) {
        self.session = session
        self.token = token
        self.refreshRejectedToken = refreshRejectedToken
    }

    struct Profile: Decodable {
        let id: String
        let displayName: String?
        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
        }
    }

    func me() async throws -> Profile {
        try await get("me")
    }

    func myPlaylists() async throws -> [Playlist] {
        // items can contain null entries (deleted/unavailable playlists)
        struct Page: Decodable { let items: [Playlist?] }
        let page: Page = try await get("me/playlists?limit=50")
        return page.items.compactMap { $0 }
    }

    func tracks(playlistID: String) async throws -> [Track] {
        struct Item: Decodable {
            let track: Track?
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                // Local files / unavailable tracks have null ids — skip them.
                track = try? c.decode(Track.self, forKey: .track)
            }
            enum CodingKeys: CodingKey { case track }
        }
        struct Page: Decodable { let items: [Item]; let next: String? }
        var all: [Track] = []
        var path: String? = "playlists/\(playlistID)/tracks?limit=100"
        while let p = path {
            let page: Page = try await get(p)
            all += page.items.compactMap(\.track)
            path = page.next.map { $0.replacingOccurrences(of: "https://api.spotify.com/v1/", with: "") }
        }
        return all
    }

    /// Liked Songs — available to dev-mode apps (unlike playlist contents).
    func likedTracks(max: Int = 500) async throws -> [Track] {
        struct Item: Decodable { let track: Track }
        struct Page: Decodable { let items: [Item]; let next: String? }
        var all: [Track] = []
        var path: String? = "me/tracks?limit=50"
        while let p = path, all.count < max {
            let page: Page = try await get(p)
            all += page.items.map(\.track)
            path = page.next.map { $0.replacingOccurrences(of: "https://api.spotify.com/v1/", with: "") }
        }
        return Array(all.prefix(max))
    }

    func topTracks() async throws -> [Track] {
        struct Page: Decodable { let items: [Track] }
        let page: Page = try await get("me/top/tracks?limit=50&time_range=medium_term")
        return page.items
    }

    struct RecentPlay {
        let track: Track
        let playedAt: Date
    }

    /// The account's last plays, newest first. Needs `user-read-recently-played`;
    /// an older token gets 403 until the user reconnects. Episodes are skipped.
    func recentlyPlayed(limit: Int = 50) async throws -> [RecentPlay] {
        struct Item: Decodable {
            let track: Track?
            let playedAt: String
            enum CodingKeys: String, CodingKey { case track, playedAt = "played_at" }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                track = try? container.decode(Track.self, forKey: .track)
                playedAt = try container.decode(String.self, forKey: .playedAt)
            }
        }
        struct Page: Decodable { let items: [Item] }
        let page: Page = try await get("me/player/recently-played?limit=\(limit)")
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter()
        return page.items.compactMap { item in
            guard let track = item.track,
                  let date = fractional.date(from: item.playedAt) ?? whole.date(from: item.playedAt) else { return nil }
            return RecentPlay(track: track, playedAt: date)
        }
    }

    func savedTracksTotal() async throws -> Int {
        struct Page: Decodable { let total: Int }
        let page: Page = try await get("me/tracks?limit=1")
        return page.total
    }

    func topTracksTotal() async throws -> Int {
        struct Page: Decodable { let total: Int }
        let page: Page = try await get("me/top/tracks?limit=1&time_range=medium_term")
        return page.total
    }

    struct CurrentlyPlaying: Decodable {
        let progressMs: Int?
        let isPlaying: Bool
        let item: Track?
        let device: Device?

        enum CodingKeys: String, CodingKey {
            case progressMs = "progress_ms"
            case isPlaying = "is_playing"
            case item, device
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            device = try c.decodeIfPresent(Device.self, forKey: .device)
            progressMs = try c.decodeIfPresent(Int.self, forKey: .progressMs)
            isPlaying = try c.decode(Bool.self, forKey: .isPlaying)
            // Podcast episodes don't decode as Track — treat as nothing playing.
            item = try? c.decodeIfPresent(Track.self, forKey: .item)
        }
    }

    /// Full playback state also identifies the device we are controlling.
    func currentlyPlaying() async throws -> CurrentlyPlaying? {
        let data = try await request("me/player", allowEmpty: true)
        return data.isEmpty ? nil : try JSONDecoder().decode(CurrentlyPlaying.self, from: data)
    }

    func seek(toMs ms: Int, deviceID: String? = nil) async throws {
        var query = [URLQueryItem(name: "position_ms", value: String(max(0, ms)))]
        if let deviceID { query.append(.init(name: "device_id", value: deviceID)) }
        _ = try await request("me/player/seek", method: "PUT", query: query)
    }

    struct Device: Decodable {
        let id: String?
        let name: String
        /// Spotify's device class: "Smartphone", "Computer", "Speaker", ...
        let type: String
        let isActive: Bool
        let isRestricted: Bool?
        enum CodingKeys: String, CodingKey {
            case id, name, type, isActive = "is_active", isRestricted = "is_restricted"
        }
    }

    /// Devices Spotify can start playback on, including an idle phone app.
    func devices() async throws -> [Device] {
        struct Page: Decodable { let devices: [Device] }
        let page: Page = try await get("me/player/devices")
        return page.devices
    }

    func play(trackID: String, positionMs: Int, deviceID: String? = nil) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "uris": ["spotify:track:\(trackID)"], "position_ms": max(0, positionMs)])
        let query = deviceID.map { [URLQueryItem(name: "device_id", value: $0)] } ?? []
        _ = try await request("me/player/play", method: "PUT", query: query, body: body)
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await JSONDecoder().decode(T.self, from: request(path))
    }

    /// A rejected access token gets one refresh/retry. Commands are never
    /// blindly replayed after a timeout: Spotify may already have applied them.
    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [],
                         body: Data? = nil, allowEmpty: Bool = false) async throws -> Data {
        var components = URLComponents(string: "https://api.spotify.com/v1/\(path)")!
        if !query.isEmpty { components.queryItems = query }
        var bearer = try await token()
        for attempt in 0...1 {
            try Task.checkCancellation()
            var req = URLRequest(url: components.url!)
            req.httpMethod = method
            req.httpBody = body
            req.timeoutInterval = 12
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let (data, response) = try await session.data(for: req)
            try Task.checkCancellation()
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if status == 401, attempt == 0 {
                bearer = try await refreshRejectedToken(bearer)
                continue
            }
            if status == 200 || (status == 204 && (allowEmpty || method != "GET")) { return data }
            let error = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let detail = error?["error"] as? [String: Any]
            throw NSError(domain: "SpotifyAPI", code: status, userInfo: [
                NSLocalizedDescriptionKey: detail?["message"] as? String ?? "Spotify returned \(status).",
                "reason": detail?["reason"] as? String ?? "",
                "retryAfter": max(1, Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5)])
        }
        throw URLError(.userAuthenticationRequired)
    }

}

/// What Home says about recent plays: one row per song, newest first.
enum RecentPlays {
    struct Song: Identifiable {
        let track: Track
        let lastPlayed: Date
        let count: Int
        var id: String { track.id }
    }

    /// Plays per calendar day for the last `days` days, oldest first, with
    /// how many were of analyzed songs. Spotify returns at most 50 plays, so
    /// earlier days may be partial; the caller labels the window honestly.
    struct Day: Equatable {
        let date: Date
        let total: Int
        let analyzed: Int
    }

    static func daily(_ plays: [SpotifyAPI.RecentPlay], analyzed: Set<String>, days: Int = 7,
                      calendar: Calendar = .current, now: Date = .now) -> [Day] {
        let today = calendar.startOfDay(for: now)
        return (0..<days).reversed().map { back in
            let date = calendar.date(byAdding: .day, value: -back, to: today)!
            let inDay = plays.filter { calendar.isDate($0.playedAt, inSameDayAs: date) }
            return Day(date: date, total: inDay.count, analyzed: inDay.filter { analyzed.contains($0.track.id) }.count)
        }
    }

    static func songs(_ plays: [SpotifyAPI.RecentPlay]) -> [Song] {
        var order: [String] = []
        var byID: [String: Song] = [:]
        for play in plays.sorted(by: { $0.playedAt > $1.playedAt }) {
            if let seen = byID[play.track.id] {
                byID[play.track.id] = Song(track: seen.track, lastPlayed: seen.lastPlayed, count: seen.count + 1)
            } else {
                byID[play.track.id] = Song(track: play.track, lastPlayed: play.playedAt, count: 1)
                order.append(play.track.id)
            }
        }
        return order.compactMap { byID[$0] }
    }

    /// "now", "12m ago", "3h ago", "yesterday", a weekday within the week, else a short date.
    static func relativeTime(_ date: Date, calendar: Calendar = .current, now: Date = .now) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h ago" }
        if calendar.isDateInYesterday(date) { return "yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        if days < 7 { return calendar.shortWeekdaySymbols[calendar.component(.weekday, from: date) - 1] }
        return date.formatted(.dateTime.month(.abbreviated).day().locale(calendar.locale ?? .current))
    }
}
