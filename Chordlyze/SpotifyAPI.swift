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
    private let auth: SpotifyAuth
    init(auth: SpotifyAuth) { self.auth = auth }

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
    func likedTracks() async throws -> [Track] {
        struct Item: Decodable { let track: Track }
        struct Page: Decodable { let items: [Item]; let next: String? }
        var all: [Track] = []
        var path: String? = "me/tracks?limit=50"
        while let p = path, all.count < 500 {
            let page: Page = try await get(p)
            all += page.items.map(\.track)
            path = page.next.map { $0.replacingOccurrences(of: "https://api.spotify.com/v1/", with: "") }
        }
        return all
    }

    func topTracks() async throws -> [Track] {
        struct Page: Decodable { let items: [Track] }
        let page: Page = try await get("me/top/tracks?limit=50&time_range=medium_term")
        return page.items
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

        enum CodingKeys: String, CodingKey {
            case progressMs = "progress_ms"
            case isPlaying = "is_playing"
            case item
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            progressMs = try c.decodeIfPresent(Int.self, forKey: .progressMs)
            isPlaying = try c.decode(Bool.self, forKey: .isPlaying)
            // Podcast episodes don't decode as Track — treat as nothing playing.
            item = try? c.decodeIfPresent(Track.self, forKey: .item)
        }
    }

    /// What the account is playing right now, on any device. nil when idle.
    func currentlyPlaying() async throws -> CurrentlyPlaying? {
        let token = try await auth.validToken()
        var req = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/currently-playing")!)
        req.timeoutInterval = 12
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 204 { return nil }
        guard status == 200 else {
            throw NSError(domain: "SpotifyAPI", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "Spotify returned \(status)",
                                     "retryAfter": Double((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5])
        }
        return try JSONDecoder().decode(CurrentlyPlaying.self, from: data)
    }

    /// Seek the account's active playback. Needs Premium + playback scope.
    func seek(toMs ms: Int) async throws {
        let token = try await auth.validToken()
        var req = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/seek?position_ms=\(ms)")!)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 204 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "SpotifyAPI", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "Spotify returned \(status): \(body)"])
        }
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let token = try await auth.validToken()
        var req = URLRequest(url: URL(string: "https://api.spotify.com/v1/\(path)")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "SpotifyAPI", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Spotify returned \(http.statusCode): \(body)"])
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
