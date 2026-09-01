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

/// Home screen, "cover-led" (design 4d): the now-playing song is the anchor,
/// its artwork color bleeds behind the header; library counts and the playlist
/// grid sit below.
struct PlaylistsView: View {
    @EnvironmentObject var auth: SpotifyAuth
    @ObservedObject private var nowPlaying = SpotifyNowPlaying.shared
    @ObservedObject private var artColor = ArtworkColor.shared
    @State private var playlists: [Playlist] = []
    @State private var analyzedCount: Int?
    @State private var likedCount: Int?
    @State private var topCount: Int?
    @State private var error: String?

    private let grid2 = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    private var currentTrack: Track? { nowPlaying.playing?.track }
    private var washColor: Color? {
        currentTrack.flatMap { artColor.color(for: $0.id) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if let track = currentTrack {
                        nowPlayingBlock(track)
                            .padding(.top, 22)
                        actionRow
                            .padding(.top, 18)
                    }
                    statTiles
                        .padding(.top, 24)
                    Text("PLAYLISTS")
                        .font(.system(size: 12, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(Color(hex: 0x8E8E93))
                        .padding(.top, 26)
                        .padding(.bottom, 10)
                    playlistGrid
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(Palette.destructive).padding(.top, 16)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 62)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .top) { wash }
            }
            .ignoresSafeArea(edges: .top)
            .background(Color.black.ignoresSafeArea())
            .navigationDestination(for: TrackSource.self) { source in
                TracksView(api: SpotifyAPI(auth: auth), source: source)
            }
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await reload() }
            .task {
                nowPlaying.start(api: SpotifyAPI(auth: auth))
                await reload()
            }
            .task(id: currentTrack?.id) {
                if let track = currentTrack {
                    await artColor.load(trackID: track.id,
                                        url: (track.album.images?.first?.url).flatMap(URL.init))
                }
            }
        }
    }

    // MARK: - Artwork color wash

    private var wash: some View {
        let top = washColor ?? Color(hex: 0x1C1C1E)
        let mid = washColor.map { $0.opacity(0.55) } ?? Color(hex: 0x1C1C1E).opacity(0.5)
        return LinearGradient(stops: [.init(color: top, location: 0),
                                      .init(color: mid, location: 0.55),
                                      .init(color: .black, location: 1)],
                              startPoint: UnitPoint(x: 0.58, y: 0),
                              endPoint: UnitPoint(x: 0.42, y: 1))
            .frame(height: 380)
            .animation(.easeInOut(duration: 0.4), value: washColor)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 0) {
            Text("Your Music")
                .font(.system(size: 30, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(.white)
            Spacer()
            NavigationLink {
                SearchView()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            NavigationLink {
                ProfileView()
            } label: {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .padding(.trailing, -10)
        }
    }

    // MARK: - Now playing

    private func nowPlayingBlock(_ track: Track) -> some View {
        HStack(alignment: .bottom, spacing: 14) {
            NavigationLink {
                chordSheetDestination(track)
            } label: {
                AsyncImage(url: (track.album.images?.first?.url).flatMap(URL.init)) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Palette.elevated
                }
                .frame(width: 104, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 17, y: 14)
            }
            .buttonStyle(.plain)
            .disabled(nowPlaying.analysis == nil)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Circle().fill(Color.spotifyGreen).frame(width: 6, height: 6)
                    Text("NOW PLAYING")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(Color.spotifyGreen)
                }
                NavigationLink {
                    chordSheetDestination(track)
                } label: {
                    Text(track.name)
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                        .tracking(-0.5)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .disabled(nowPlaying.analysis == nil)
                .padding(.top, 4)
                Text(track.artistNames)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Group {
                    if let key = nowPlaying.analysis?.key {
                        Text(key.uppercased())
                            .font(.system(size: 12, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color.spotifyGreen)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 10)
                            .background(Capsule().fill(Color.black.opacity(0.35)))
                    } else if !nowPlaying.analysisFailed {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.top, 8)
            }
            .padding(.bottom, 2)
            Spacer(minLength: 0)
        }
    }

    private func chordSheetDestination(_ track: Track) -> some View {
        Group {
            if let analysis = nowPlaying.analysis {
                AnalysisTabsView(analysis: analysis, title: track.name, artist: track.artistNames)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            NavigationLink {
                SpotifyLiveView()
            } label: {
                Text("Follow live")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Capsule().fill(Color.spotifyGreen))
            }
            .buttonStyle(.plain)
            NavigationLink {
                if let track = currentTrack { chordSheetDestination(track) }
            } label: {
                Text("Chord sheet")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .disabled(nowPlaying.analysis == nil)
            .opacity(nowPlaying.analysis == nil ? 0.5 : 1)
        }
    }

    // MARK: - Stats

    private var statTiles: some View {
        HStack(spacing: 8) {
            NavigationLink { LibraryView() } label: {
                statTile(count: analyzedCount, label: "Analyzed")
            }.buttonStyle(.plain)
            NavigationLink(value: TrackSource.liked) {
                statTile(count: likedCount, label: "Liked")
            }.buttonStyle(.plain)
            NavigationLink(value: TrackSource.top) {
                statTile(count: topCount, label: "Top")
            }.buttonStyle(.plain)
        }
    }

    private func statTile(count: Int?, label: String) -> some View {
        VStack(spacing: 0) {
            Text(count.map(String.init) ?? "—")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color(hex: 0x98989F))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(Color.white.opacity(0.07)))
    }

    // MARK: - Playlists

    private var playlistGrid: some View {
        LazyVGrid(columns: grid2, spacing: 12) {
            ForEach(playlists) { playlist in
                NavigationLink(value: TrackSource.playlist(id: playlist.id, name: playlist.name)) {
                    VStack(alignment: .leading, spacing: 7) {
                        AsyncImage(url: (playlist.images?.first?.url).flatMap(URL.init)) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Palette.elevated
                        }
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Text(playlist.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func reload() async {
        let api = SpotifyAPI(auth: auth)
        async let lib = try? BackendClient.library()
        async let liked = try? api.savedTracksTotal()
        async let top = try? api.topTracksTotal()
        do { playlists = try await api.myPlaylists() }
        catch { self.error = "Could not load playlists: \(error.localizedDescription)" }
        analyzedCount = (await lib)?.count
        likedCount = await liked
        topCount = await top
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
