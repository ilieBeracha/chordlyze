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
                    if nowPlaying.needsReauth {
                        reauthBanner
                            .padding(.top, 22)
                    }
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
                        .foregroundStyle(Palette.secondary)
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
            .task { await reload() }
            // Every token grant (launch refresh, reconnect) restarts the
            // poller; a no-op while it is already running.
            .task(id: auth.grants) {
                nowPlaying.start(api: SpotifyAPI(auth: auth))
            }
            .task(id: currentTrack?.id) {
                if let track = currentTrack {
                    await artColor.load(trackID: track.id, url: track.album.artworkURL)
                }
            }
        }
    }

    // MARK: - Artwork color wash

    private var wash: some View {
        let top = washColor ?? Palette.elevated
        let mid = washColor.map { $0.opacity(0.55) } ?? Palette.elevated.opacity(0.5)
        return VStack(spacing: 0) {
            // Headroom so the rubber-band overscroll shows color, not black.
            top.frame(height: 600)
            LinearGradient(stops: [.init(color: top, location: 0),
                                   .init(color: mid, location: 0.55),
                                   .init(color: .black, location: 1)],
                           startPoint: UnitPoint(x: 0.58, y: 0),
                           endPoint: UnitPoint(x: 0.42, y: 1))
                .frame(height: 380)
        }
        .offset(y: -600)
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

    /// The poller stopped on a 401/403: the token lacks a scope this build
    /// needs, or Spotify revoked it. Said here instead of a silent blank.
    private var reauthBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.warning)
            Text("Spotify stopped answering. Reconnect to see what's playing.")
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
    }

    // MARK: - Now playing

    private func nowPlayingBlock(_ track: Track) -> some View {
        let paused = nowPlaying.playing?.isPlaying == false
        return NavigationLink {
            chordSheetDestination(track)
        } label: {
            HStack(alignment: .bottom, spacing: 14) {
                AsyncImage(url: track.album.artworkURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Palette.elevated
                }
                .frame(width: 104, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 17, y: 14)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Circle().fill(paused ? Palette.secondary : Color.spotifyGreen).frame(width: 6, height: 6)
                        Text(paused ? "PAUSED" : "NOW PLAYING")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1.2)
                            .foregroundStyle(paused ? Palette.secondary : Color.spotifyGreen)
                    }
                    Text(track.name)
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                        .tracking(-0.5)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
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
                        } else if nowPlaying.analysisFailed {
                            Text("NO CHORDS")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(1.0)
                                .foregroundStyle(.white.opacity(0.5))
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .padding(.top, 8)
                }
                .padding(.bottom, 2)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
    }

    private func chordSheetDestination(_ track: Track) -> some View {
        ChordView(track: track)
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
                .foregroundStyle(Palette.secondaryAlt)
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
        do {
            playlists = try await api.myPlaylists()
            error = nil
        } catch {
            self.error = "Could not load playlists: \(error.localizedDescription)"
        }
        analyzedCount = (await lib)?.count
        likedCount = await liked
        topCount = await top
    }
}

/// One source's tracks (liked, top, or a playlist), each with its saved key
/// when the library has it.
struct TracksView: View {
    let api: SpotifyAPI
    let source: TrackSource
    @State private var tracks: [Track] = []
    @State private var libraryByTrack: [String: BackendClient.LibraryItem] = [:]
    @State private var error: String?
    /// Spotify refuses playlist contents to apps in development mode (403).
    @State private var locked = false
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    BackCircle()
                    Spacer()
                    if !tracks.isEmpty {
                        let analyzed = tracks.filter { libraryByTrack[$0.id] != nil }.count
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
                } else if locked {
                    ContentUnavailableView {
                        Label("Playlist locked by Spotify", systemImage: "lock")
                    } description: {
                        Text("Spotify blocks playlist contents for apps in development mode. Use Liked Songs or Top Tracks.")
                    }
                } else if let error {
                    Text(error).foregroundStyle(Palette.destructive).padding(20)
                }

                ForEach(tracks) { track in
                    NavigationLink {
                        ChordView(track: track)
                    } label: {
                        SongRow(artworkURL: track.album.artworkURL,
                                title: track.name, artist: track.artistNames) {
                            if let saved = libraryByTrack[track.id], let key = saved.key {
                                KeyBadge(key: key, difficulty: saved.difficulty?.level)
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Palette.chevron)
                            }
                        }
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
                if case .playlist = source, (error as NSError).code == 403 {
                    locked = true
                } else {
                    self.error = error.localizedDescription
                }
            }
            if let items = await lib {
                libraryByTrack = Dictionary(items.map { ($0.trackId, $0) }, uniquingKeysWith: { a, _ in a })
            }
        }
    }
}
