import SwiftUI

/// Search any song (iTunes catalog) and analyze its chords. With no query the
/// page browses the account's own music: recent plays, top tracks, liked
/// songs, and the easy songs already in the library.
struct SearchView: View {
    var isRoot = false
    @EnvironmentObject var auth: SpotifyAuth
    @State private var query = ""
    @State private var results: [ITunesSong] = []
    @State private var searching = false
    /// Last search failed (network) or found nothing; nil before any search.
    @State private var note: String?
    @FocusState private var focused: Bool

    private enum Browse: String, CaseIterable, Identifiable {
        case recent = "Recently played", top = "Top tracks", liked = "Liked songs", easy = "Easy to play"
        var id: String { rawValue }
    }
    @State private var browse: Browse = .recent
    @State private var browseTracks: [Browse: [Track]] = [:]
    @State private var loadingBrowse = false
    @State private var browseNote: String?
    /// The token predates the recently-played scope; a reconnect grants it.
    @State private var needsReconnect = false
    @State private var library: [String: BackendClient.LibraryItem] = [:]
    @State private var easyItems: [BackendClient.LibraryItem] = []

    struct ITunesSong: Decodable, Identifiable {
        let trackId: Int
        let trackName: String
        let artistName: String
        let artworkUrl100: String?
        let collectionName: String?
        let trackTimeMillis: Int?
        var id: Int { trackId }
        var artworkURL: URL? { artworkUrl100.flatMap(URL.init) }
    }

    private var browsing: Bool { query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { if !isRoot { BackCircle() }; Spacer() }
                .padding(.horizontal, 20)

            Text("Search")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 14)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Palette.secondary)
                TextField("Song or artist", text: $query)
                    .foregroundStyle(.white)
                    .focused($focused)
                    .submitLabel(.search)
                    .onSubmit { Task { await search() } }
                if searching { ProgressView().controlSize(.small) }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.elevated))
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: 0) {
                    if browsing {
                        browseSection
                    } else {
                        if let note {
                            Text(note)
                                .font(.system(size: 13))
                                .foregroundStyle(Palette.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        }
                        ForEach(results) { song in
                            NavigationLink {
                                SearchAnalysisView(song: song)
                            } label: {
                                SongRow(artworkURL: song.artworkURL, title: song.trackName,
                                        artist: song.artistName) {
                                    chevron
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { if !isRoot { focused = true } }
        .onChange(of: query) { _, value in
            if value.trimmingCharacters(in: .whitespaces).isEmpty { results = []; note = nil }
        }
        .task(id: auth.grants) { await loadLibrary() }
        .task(id: "\(browse.rawValue)-\(auth.grants)") { await loadBrowse(browse) }
    }

    // MARK: - Browse

    @ViewBuilder private var browseSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Browse.allCases) { mode in
                    Button { browse = mode } label: {
                        Text(mode.rawValue)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(browse == mode ? .black : .white)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 14)
                            .background(Capsule().fill(browse == mode ? Color.spotifyGreen : Color.white.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.top, 4)
        .padding(.bottom, 10)

        if browse == .recent, needsReconnect {
            reconnectRow
        } else if let browseNote {
            message(browseNote)
        } else if browse == .easy {
            if easyItems.isEmpty {
                message("Analyze a few songs and the easy ones show up here.")
            }
            ForEach(easyItems) { item in
                NavigationLink {
                    SavedAnalysisView(item: item)
                } label: {
                    SongRow(artworkURL: item.artworkURL, title: item.title ?? "Unknown song",
                            artist: item.artist ?? "") {
                        if let key = item.key { KeyBadge(key: key, difficulty: item.difficulty?.level) } else { chevron }
                    }
                }
                .buttonStyle(.plain)
            }
        } else if let tracks = browseTracks[browse] {
            if tracks.isEmpty {
                message("Nothing here yet.")
            }
            ForEach(tracks) { track in
                NavigationLink {
                    ChordView(track: track)
                } label: {
                    SongRow(artworkURL: track.album.artworkURL, title: track.name, artist: track.artistNames) {
                        if let saved = library[track.id], let key = saved.key {
                            KeyBadge(key: key, difficulty: saved.difficulty?.level)
                        } else {
                            chevron
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        } else if loadingBrowse {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.chevron)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Palette.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
            .padding(.horizontal, 20)
    }

    private var reconnectRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
            Text("Reconnect Spotify to see what you played.")
                .font(.system(size: 13))
                .foregroundStyle(.white)
            Spacer()
            Button("Reconnect") { auth.login() }
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.black)
                .padding(.vertical, 7)
                .padding(.horizontal, 12)
                .background(Capsule().fill(Color.spotifyGreen))
                .buttonStyle(.plain)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.08)))
        .padding(.horizontal, 20)
    }

    private func loadLibrary() async {
        // Every chart counts here: a song anyone analyzed is ready to play.
        guard let items = try? await BackendClient.catalog() else { return }
        library = Dictionary(items.map { ($0.trackId, $0) }, uniquingKeysWith: { a, _ in a })
        easyItems = items.filter { $0.difficulty?.level == "easy" }
    }

    private func loadBrowse(_ mode: Browse) async {
        guard mode != .easy else { return }
        loadingBrowse = true
        defer { loadingBrowse = false }
        let api = SpotifyAPI(auth: auth)
        do {
            switch mode {
            case .recent: browseTracks[mode] = RecentPlays.songs(try await api.recentlyPlayed()).map(\.track)
            case .top: browseTracks[mode] = try await api.topTracks()
            case .liked: browseTracks[mode] = try await api.likedTracks(max: 50)
            case .easy: break
            }
            browseNote = nil
            if mode == .recent { needsReconnect = false }
        } catch {
            let code = (error as NSError).code
            if mode == .recent, code == 401 || code == 403 {
                needsReconnect = true
            } else {
                browseNote = "Could not load: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Search

    private func search() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        searching = true
        defer { searching = false }
        struct Response: Decodable { let results: [ITunesSong] }
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [.init(name: "term", value: term),
                            .init(name: "entity", value: "song"),
                            .init(name: "limit", value: "20")]
        do {
            let (data, _) = try await URLSession.shared.data(from: comps.url!)
            results = try JSONDecoder().decode(Response.self, from: data).results
            note = results.isEmpty ? "Nothing found for “\(term)”." : nil
        } catch {
            results = []
            note = "Search failed: \(error.localizedDescription)"
        }
    }
}

/// Search uses the same complete song sheet as library, live and practice.
struct SearchAnalysisView: View {
    let song: SearchView.ITunesSong
    var body: some View {
        AnalysisTabsView(song: SongDescriptor(trackID: "itunes-\(song.trackId)",
            title: song.trackName, artist: song.artistName, album: song.collectionName,
            duration: song.trackTimeMillis.map { Double($0) / 1000 },
            artwork: song.artworkUrl100, itunesID: song.trackId))
    }
}
