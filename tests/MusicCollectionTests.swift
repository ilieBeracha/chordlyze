import Foundation

enum Config { static let backendBaseURL = URL(string: "http://127.0.0.1:1")! }

private func decode<T: Decodable>(_ object: Any) -> T {
    try! JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
}
@MainActor private var count = 0
@MainActor private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    count += 1
    precondition(condition(), message)
}
@MainActor private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    fatalError("Timed out")
}

@main struct MusicCollectionTests {
    @MainActor static func main() async throws {
        check(MusicSort.restored("alpha") == .title, "Preserve legacy alphabetical preference")
        check(MusicSort.restored("key") == .key, "Preserve legacy key preference")
        check(MusicSort.restored("unknown") == .recent, "Unknown preferences use recent order")
        let items: [BackendClient.LibraryItem] = decode([
            ["track_id": "one", "title": "Été", "artist": "Zebra", "key": "C major", "chord_count": 4, "difficulty": ["level": "easy", "score": 2]],
            ["track_id": "two", "title": "Alpha", "artist": "Aria", "key": "A minor", "chord_count": 7, "difficulty": ["level": "hard", "score": 8]],
            ["track_id": "three", "title": "Alpha", "artist": "Aria", "chord_count": 0],
            ["track_id": "four", "album": "Night songs", "artist": "שלום"]
        ])
        check(MusicQuery.apply(items).map(\.id) == items.map(\.id), "Default retains backend recent order")
        check(MusicQuery.apply(items, query: " \n Ete Zebra ").map(\.id) == ["one"], "Whitespace, diacritics and mixed fields")
        check(MusicQuery.apply(items, query: "night").map(\.id) == ["four"], "Album search")
        check(MusicQuery.apply(items, query: "שלום").map(\.id) == ["four"], "Hebrew search")
        check(MusicQuery.apply(items, query: "C major").map(\.id) == ["one"], "Key search")
        check(MusicQuery.apply(items, filter: .easy).map(\.id) == ["one"], "Only explicit easy grades")
        check(MusicQuery.apply(items, filter: .fewChords).map(\.id) == ["one"], "Missing and zero chords are not easy charts")
        check(MusicQuery.apply(items, query: "Alpha", filter: .easy).isEmpty, "Search combines with filter")
        check(MusicQuery.apply(items, sort: .title).map(\.id) == ["two", "three", "one", "four"], "Stable title sort with unknowns last")
        check(MusicQuery.apply(items, sort: .key).map(\.id) == ["two", "one", "three", "four"], "Stable key sort with unknowns last")

        var fail = false
        let personal = MusicCollection(fetch: {
            if fail { throw URLError(.notConnectedToInternet) }
            return [items[0]]
        })
        let global = MusicCollection(fetch: { items })
        await personal.load(); await global.load()
        check(personal.items.count == 1 && global.items.count == 4, "Personal contents never widen to global contents")
        fail = true
        await personal.load()
        check(personal.items.map(\.id) == ["one"] && personal.error?.contains("internet connection") == true && !personal.loading, "Failed refresh retains personal songs and reports error")
        fail = false
        await personal.load()
        check(personal.error == nil, "Successful retry clears error")

        var replies: [CheckedContinuation<[BackendClient.LibraryItem], Error>] = []
        let racing = MusicCollection(fetch: { try await withCheckedThrowingContinuation { replies.append($0) } })
        let first = Task { await racing.load() }
        try await waitFor { replies.count == 1 }
        let second = Task { await racing.load() }
        try await waitFor { replies.count == 2 }
        replies[1].resume(returning: [items[1]])
        await second.value
        replies[0].resume(returning: [items[0]])
        await first.value
        check(racing.items.map(\.id) == ["two"], "Old refresh cannot overwrite newer result")

        let song: DiscoveredSong = decode(["trackId": 1, "trackName": "Sample", "artistName": "Artist"])
        var searches: [String: CheckedContinuation<[DiscoveredSong], Error>] = [:]
        let discovery = SongDiscovery(delay: .zero, fetch: { term in
            try await withCheckedThrowingContinuation { searches[term] = $0 }
        })
        discovery.search("old")
        try await waitFor { searches["old"] != nil }
        discovery.search("new")
        try await waitFor { searches["new"] != nil }
        searches["new"]!.resume(returning: [song])
        try await waitFor { !discovery.searching }
        searches["old"]!.resume(throwing: URLError(.timedOut))
        try await Task.sleep(for: .milliseconds(20))
        check(discovery.results.count == 1 && discovery.completedQuery == "new" && discovery.error == nil, "Late failure cannot replace new results")
        discovery.search("clear")
        try await waitFor { searches["clear"] != nil }
        discovery.search(" \n ")
        searches["clear"]!.resume(returning: [song])
        try await Task.sleep(for: .milliseconds(20))
        check(discovery.results.isEmpty && !discovery.searching && discovery.completedQuery == nil, "Clearing query invalidates in-flight response")
        discovery.search("failure")
        try await waitFor { searches["failure"] != nil }
        searches["failure"]!.resume(throwing: URLError(.notConnectedToInternet))
        try await waitFor { !discovery.searching }
        check(discovery.error != nil && discovery.results.isEmpty, "Current failure is visible")
        discovery.search("empty", immediately: true)
        try await waitFor { searches["empty"] != nil }
        searches["empty"]!.resume(returning: [])
        try await waitFor { !discovery.searching }
        check(discovery.completedQuery == "empty" && discovery.error == nil, "Empty success is distinct from failure")
        let cover = HomeArtwork(id: "recent", url: URL(string: "https://example.com/recent.jpg"))
        let savedCover = HomeArtwork(id: "saved", url: URL(string: "https://example.com/saved.jpg"))
        let noCover = HomeArtwork(id: "missing", url: nil)
        check(HomeArtwork.fallback(current: nil, recent: [cover], saved: [savedCover]) == cover, "Recent cover takes priority")
        check(HomeArtwork.fallback(current: nil, recent: [noCover], saved: [savedCover]) == savedCover, "Personal artwork supplies fallback when recent artwork is missing")
        check(HomeArtwork.fallback(current: cover, recent: [cover, savedCover], saved: []) == cover, "Chosen color source stays stable across refreshes")
        check(HomeArtwork.fallback(current: nil, recent: [noCover], saved: []) == nil, "Empty collections do not invent an artwork source")
        check(HomeArtwork.active(playing: cover, isPlaying: true, fallback: savedCover) == cover, "Playing song controls Home color")
        check(HomeArtwork.active(playing: cover, isPlaying: false, fallback: savedCover) == savedCover, "Idle playback uses a recent song")
        check(HomeArtwork.active(playing: noCover, isPlaying: true, fallback: savedCover) == savedCover, "Missing current cover uses available recent artwork")
        print("Music collection and search: \(count)/\(count) checks passed")
    }
}
