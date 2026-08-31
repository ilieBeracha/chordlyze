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
    struct Artist: Decodable { let name: String }
    struct Album: Decodable { let name: String; let images: [SpotifyImage]? }
    struct ExternalIds: Decodable { let isrc: String? }

    var artistNames: String { artists.map(\.name).joined(separator: ", ") }
    var isrc: String? { externalIds?.isrc }

    enum CodingKeys: String, CodingKey {
        case id, name, artists, album
        case externalIds = "external_ids"
    }
}

@MainActor
final class SpotifyAPI: ObservableObject {
    private let auth: SpotifyAuth
    init(auth: SpotifyAuth) { self.auth = auth }

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
