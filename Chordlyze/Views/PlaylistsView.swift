import SwiftUI

enum TrackSource: Hashable {
    case liked
    case top
    case playlist(id: String, name: String)

    var title: String {
        switch self {
        case .liked: return "Liked Songs"
        case .top: return "Top Tracks"
        case .playlist(_, let name): return name
        }
    }
}

struct PlaylistsView: View {
    @EnvironmentObject var auth: SpotifyAuth
    @State private var playlists: [Playlist] = []
    @State private var analyzedCount: Int?
    @State private var error: String?

    private let grid2 = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    private let grid3 = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10),
                         GridItem(.flexible(), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Your Music")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(.white)
                        Spacer()
                        NavigationLink {
                            SearchView()
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 16)
                        NavigationLink {
                            ProfileView()
                        } label: {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 26))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }

                    // Auto Session hero card
                    NavigationLink {
                        AutoSessionView()
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Circle().fill(Color.spotifyGreen).frame(width: 8, height: 8)
                                Text("AUTO SESSION")
                                    .font(.system(size: 12, weight: .bold))
                                    .tracking(1.2)
                                    .foregroundStyle(Color.spotifyGreen)
                            }
                            Text("Chords while you listen")
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            Text("Play anything out loud — every song gets identified and analyzed.")
                                .font(.system(size: 14))
                                .foregroundStyle(Palette.heroSub)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 22)
                        .padding(.horizontal, 20)
                        .background(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(Palette.heroBackground)
                                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .stroke(Color.spotifyGreen.opacity(0.25), lineWidth: 1))
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 20)

                    // Library tiles
                    LazyVGrid(columns: grid3, spacing: 10) {
                        NavigationLink { LibraryView() } label: {
                            libraryTile(icon: "checkmark.seal.fill", label: "Analyzed",
                                        count: analyzedCount.map { "\($0) songs" })
                        }.buttonStyle(.plain)
                        NavigationLink(value: TrackSource.liked) {
                            libraryTile(icon: "heart.fill", label: "Liked", count: nil)
                        }.buttonStyle(.plain)
                        NavigationLink(value: TrackSource.top) {
                            libraryTile(icon: "chart.bar.fill", label: "Top Tracks", count: "last 6 mo")
                        }.buttonStyle(.plain)
                    }
                    .padding(.top, 14)

                    SectionLabel("Playlists")
                        .padding(.top, 26)
                        .padding(.bottom, 12)

                    LazyVGrid(columns: grid2, spacing: 12) {
                        ForEach(playlists) { playlist in
                            NavigationLink(value: TrackSource.playlist(id: playlist.id, name: playlist.name)) {
                                VStack(alignment: .leading, spacing: 8) {
                                    AsyncImage(url: (playlist.images?.first?.url).flatMap(URL.init)) { image in
                                        image.resizable().aspectRatio(contentMode: .fill)
                                    } placeholder: {
                                        Palette.elevated
                                    }
                                    .aspectRatio(1, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    Text(playlist.name)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if let error {
                        Text(error).font(.footnote).foregroundStyle(Palette.destructive).padding(.top, 16)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationDestination(for: TrackSource.self) { source in
                TracksView(api: SpotifyAPI(auth: auth), source: source)
            }
            .toolbar(.hidden, for: .navigationBar)
            .task {
                async let lib = try? BackendClient.library()
                do { playlists = try await SpotifyAPI(auth: auth).myPlaylists() }
                catch { self.error = "Could not load playlists: \(error.localizedDescription)" }
                analyzedCount = (await lib)?.count
            }
        }
    }

    private func libraryTile(icon: String, label: String, count: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(.white)
            Spacer().frame(height: 16)
            Text(label)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(count ?? " ")
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.card))
    }
}

struct TracksView: View {
    let api: SpotifyAPI
    let source: TrackSource
    @State private var tracks: [Track] = []
    @State private var keysByTrack: [String: String] = [:]
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    BackCircle()
                    Spacer()
                    if !tracks.isEmpty {
                        let analyzed = tracks.filter { keysByTrack[$0.id] != nil }.count
                        Text("\(tracks.count) songs · \(analyzed) analyzed")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.secondary)
                    }
                }
                .padding(.horizontal, 20)

                Text(source.title)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 10)

                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                } else if let error {
                    if case .playlist = source, error.contains("403") {
                        ContentUnavailableView {
                            Label("Playlist locked by Spotify", systemImage: "lock")
                        } description: {
                            Text("Spotify blocks playlist contents for apps in development mode. Use Liked Songs or Top Tracks.")
                        }
                    } else {
                        Text(error).foregroundStyle(Palette.destructive).padding(20)
                    }
                }

                ForEach(tracks) { track in
                    NavigationLink {
                        ChordView(track: track)
                    } label: {
                        HStack(spacing: 14) {
                            keyBadge(for: track)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.name)
                                    .font(.system(size: 17))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(track.artistNames)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Palette.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color(hex: 0x5A5A5E))
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 20)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task {
            defer { loading = false }
            async let lib = try? BackendClient.library()
            do {
                switch source {
                case .liked: tracks = try await api.likedTracks()
                case .top: tracks = try await api.topTracks()
                case .playlist(let id, _): tracks = try await api.tracks(playlistID: id)
                }
            } catch {
                self.error = "\(error.localizedDescription)"
            }
            if let items = await lib {
                keysByTrack = Dictionary(uniqueKeysWithValues:
                    items.compactMap { item in item.key.map { (item.trackId, $0) } })
            }
        }
    }

    @ViewBuilder
    private func keyBadge(for track: Track) -> some View {
        if let key = keysByTrack[track.id] {
            Text(key)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Color.spotifyGreen)
                .padding(.vertical, 6).padding(.horizontal, 10)
                .frame(minWidth: 64)
                .background(RoundedRectangle(cornerRadius: 9).fill(Palette.greenTintFill))
        } else {
            Text("—")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.faint)
                .padding(.vertical, 6).padding(.horizontal, 10)
                .frame(minWidth: 64)
                .background(RoundedRectangle(cornerRadius: 9).fill(Palette.elevated))
        }
    }
}
