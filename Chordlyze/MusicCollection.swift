import Combine
import Foundation

/// Personal and global collections never share a loader or fall back to one another.
@MainActor final class MusicCollection: ObservableObject {
    @Published private(set) var items: [BackendClient.LibraryItem] = []
    @Published private(set) var loading = true
    @Published private(set) var error: String?
    private var revision = 0
    private let fetch: () async throws -> [BackendClient.LibraryItem]

    init(fetch: @escaping () async throws -> [BackendClient.LibraryItem]) { self.fetch = fetch }

    func load() async {
        revision += 1
        let request = revision
        loading = true
        defer { if request == revision { loading = false } }
        do {
            let result = try await fetch()
            guard request == revision, !Task.isCancelled else { return }
            items = result
            error = nil
        } catch {
            guard request == revision, !Task.isCancelled else { return }
            // Preserve the last successful contents during a failed refresh.
            self.error = MusicLoadError.message(error)
        }
    }
}

enum MusicFilter: String, CaseIterable, Identifiable {
    case all = "All songs", easy = "Easy", fewChords = "4 chords or fewer"
    var id: String { rawValue }
}

enum MusicSort: String, CaseIterable, Identifiable {
    case recent = "Recently added", title = "Title", artist = "Artist", key = "Key"
    var id: String { rawValue }
    static func restored(_ stored: String) -> MusicSort {
        if let current = MusicSort(rawValue: stored) { return current }
        switch stored {
        case "alpha": return .title
        case "key": return .key
        default: return .recent
        }
    }
}

enum MusicQuery {
    static func normalized(_ query: String) -> String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func apply(_ items: [BackendClient.LibraryItem], query: String = "",
                      filter: MusicFilter = .all, sort: MusicSort = .recent) -> [BackendClient.LibraryItem] {
        let terms = normalized(query).split(whereSeparator: \.isWhitespace).map(String.init)
        let matches = items.filter { item in
            let fields = [item.title, item.artist, item.album, item.genre, item.key].compactMap { $0 }
            let textMatches = terms.allSatisfy { term in fields.contains { $0.localizedStandardContains(term) } }
            let filterMatches: Bool
            switch filter {
            case .all: filterMatches = true
            case .easy: filterMatches = item.difficulty?.level == "easy"
            case .fewChords: filterMatches = item.chordCount.map { (1...4).contains($0) } ?? false
            }
            return textMatches && filterMatches
        }
        guard sort != .recent else { return matches }
        func field(_ item: BackendClient.LibraryItem) -> String? {
            switch sort {
            case .recent: return nil
            case .title: return item.title
            case .artist: return item.artist
            case .key: return item.key
            }
        }
        return matches.enumerated().sorted { lhs, rhs in
            let left = field(lhs.element).flatMap { $0.isEmpty ? nil : $0 }
            let right = field(rhs.element).flatMap { $0.isEmpty ? nil : $0 }
            if left == nil, right != nil { return false }
            if left != nil, right == nil { return true }
            let order = (left ?? "").localizedStandardCompare(right ?? "")
            return order == .orderedSame ? lhs.offset < rhs.offset : order == .orderedAscending
        }.map(\.element)
    }
}

struct DiscoveredSong: Decodable, Identifiable {
    let trackId: Int
    let trackName: String
    let artistName: String
    let artworkUrl100: String?
    let collectionName: String?
    let trackTimeMillis: Int?
    var id: Int { trackId }
    var artworkURL: URL? { artworkUrl100.flatMap(URL.init) }
}

/// A new query invalidates the previous request immediately, including when cleared.
@MainActor final class SongDiscovery: ObservableObject {
    @Published private(set) var results: [DiscoveredSong] = []
    @Published private(set) var searching = false
    @Published private(set) var error: String?
    @Published private(set) var completedQuery: String?
    private var revision = 0
    private var request: Task<Void, Never>?
    private let fetch: (String) async throws -> [DiscoveredSong]
    private let delay: Duration

    init(delay: Duration = .milliseconds(280), fetch: @escaping (String) async throws -> [DiscoveredSong] = SongDiscovery.fetch) {
        self.delay = delay
        self.fetch = fetch
    }

    func search(_ query: String, immediately: Bool = false) {
        revision += 1
        let version = revision
        request?.cancel()
        results = []; error = nil; completedQuery = nil
        let term = MusicQuery.normalized(query)
        searching = !term.isEmpty
        guard !term.isEmpty else { return }
        request = Task {
            defer { if version == revision { searching = false } }
            do {
                if !immediately { try await Task.sleep(for: delay) }
                let songs = try await fetch(term)
                guard version == revision, !Task.isCancelled else { return }
                results = songs
                completedQuery = term
            } catch {
                guard version == revision, !Task.isCancelled else { return }
                self.error = MusicLoadError.message(error)
            }
        }
    }

    nonisolated private static func fetch(_ term: String) async throws -> [DiscoveredSong] {
        var url = URLComponents(string: "https://itunes.apple.com/search")!
        url.queryItems = [.init(name: "term", value: term), .init(name: "entity", value: "song"), .init(name: "limit", value: "30")]
        let (data, response) = try await URLSession.shared.data(from: url.url!)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        struct Response: Decodable { let results: [DiscoveredSong] }
        let songs = try JSONDecoder().decode(Response.self, from: data).results
        var seen = Set<Int>()
        return songs.filter { seen.insert($0.id).inserted }
    }
}

/// Keep the fallback stable while browsing; choose a recent cover once per visit.
struct HomeArtwork: Equatable {
    let id: String
    let url: URL?

    static func active(playing: HomeArtwork?, isPlaying: Bool, fallback: HomeArtwork?) -> HomeArtwork? {
        if isPlaying, let playing, playing.url != nil { return playing }
        return fallback
    }

    static func fallback(current: HomeArtwork?, recent: [HomeArtwork], saved: [HomeArtwork]) -> HomeArtwork? {
        let recentCovers = recent.filter { $0.url != nil }
        let candidates = recentCovers.isEmpty ? saved.filter { $0.url != nil } : recentCovers
        if let current, candidates.contains(current) { return current }
        return candidates.randomElement()
    }
}

/// Keep transport diagnostics out of the browsing UI.
enum MusicLoadError {
    static func message(_ error: Error) -> String {
        if let network = error as? URLError {
            switch network.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "Check your internet connection and try again."
            case .timedOut:
                return "This is taking longer than expected. Please try again."
            default:
                return "The music service couldn’t be reached. Please try again."
            }
        }
        if let backend = error as? BackendError { return backend.detail }
        return "Your music couldn’t be loaded. Please try again."
    }
}
