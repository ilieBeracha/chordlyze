import SwiftUI

/// Live follow-along bound to the Spotify poller: when the song changes, the
/// view swaps to the new track (fresh lyrics, chords, position) instead of
/// staying stuck on the one it was opened with.
struct SpotifyLiveView: View {
    @ObservedObject private var nowPlaying = SpotifyNowPlaying.shared

    var body: some View {
        Group {
            if let playing = nowPlaying.playing {
                if let analysis = nowPlaying.analysis {
                    LiveNowView(title: playing.track.name, artist: playing.track.artistNames,
                                analysis: analysis,
                                trackDuration: (playing.track.durationMs).map { Double($0) / 1000 },
                                album: playing.track.album.name,
                                onSeek: { await nowPlaying.seek(to: $0) }) {
                        nowPlaying.livePosition()
                    }
                    .id(playing.track.id)  // rebuild per song
                } else {
                    WaitingView(title: playing.track.name,
                                subtitle: playing.track.artistNames.uppercased(),
                                message: nowPlaying.analysisFailed
                                    ? "Chords unavailable for this song."
                                    : "Analyzing chords…",
                                spinning: !nowPlaying.analysisFailed)
                }
            } else {
                WaitingView(title: "Nothing playing", subtitle: "",
                            message: "Play something on Spotify.", spinning: false)
            }
        }
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
