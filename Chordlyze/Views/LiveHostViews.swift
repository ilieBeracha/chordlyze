import SwiftUI

/// Live follow-along bound to the Spotify poller: when the song changes, the
/// view swaps to the new track (fresh lyrics, chords, position) instead of
/// staying stuck on the one it was opened with.
struct SpotifyLiveView: View {
    @ObservedObject private var nowPlaying = SpotifyNowPlaying.shared

    var body: some View {
        Group {
            if let playing = nowPlaying.playing {
                LiveSongView(store: SongSheetStore.shared(for: SongDescriptor(track: playing.track)),
                             onSeek: { await nowPlaying.seek(to: $0) },
                             playbackNote: nowPlaying.playbackNote) {
                    nowPlaying.livePosition()
                }
                .id(playing.track.id)
            } else {
                WaitingView(title: nowPlaying.needsReauth ? "Reconnect Spotify" : "Nothing playing",
                            subtitle: "", message: nowPlaying.playbackNote ?? "Play something on Spotify.", spinning: false)
            }
        }
        .onAppear { nowPlaying.resume() }
    }
}

/// Live follows only an analyzed song. Until the chart is ready the screen is
/// a compact card, never a sheet of pending rows.
struct LiveSongView: View {
    @ObservedObject var store: SongSheetStore
    var onSeek: ((Double) async -> Bool)? = nil
    var playbackNote: String? = nil
    let livePosition: () -> TimeInterval?

    var body: some View {
        if store.canPractice {
            LiveNowView(store: store, onSeek: onSeek, playbackNote: playbackNote, livePosition: livePosition)
        } else {
            LiveAnalyzingView(store: store, playbackNote: playbackNote)
        }
    }
}

/// Artwork, one line of state, and a Retry when analysis stopped.
struct LiveAnalyzingView: View {
    @ObservedObject var store: SongSheetStore
    var playbackNote: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            SongSheetHeader(store: store)
            Spacer()
            VStack(spacing: 18) {
                AsyncImage(url: store.song.artwork.flatMap(URL.init)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(Palette.card)
                }
                .frame(width: 168, height: 168)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                HStack(spacing: 8) {
                    if store.busy { ProgressView().controlSize(.small) }
                    Text(store.message).font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.nearWhite)
                }
                .accessibilityIdentifier("live-analyzing-state")
                if let title = store.actionTitle {
                    Button(title) { store.retry() }
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(.black)
                        .padding(.vertical, 9).padding(.horizontal, 22)
                        .background(Capsule().fill(Color.spotifyGreen))
                }
                if let playbackNote {
                    Text(playbackNote).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
            }
            .padding(.horizontal, 30)
            Spacer()
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .observes(store)
    }
}

/// Song header over a centered status line: shown while a song's chords are
/// loading, and in their place when there are none.
struct WaitingView: View {
    let title: String
    let subtitle: String
    let message: String
    let spinning: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                BackCircle(size: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            Spacer()
            VStack(spacing: 14) {
                if spinning { ProgressView() }
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 30)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 34)
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}
