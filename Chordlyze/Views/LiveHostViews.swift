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
                                trackDuration: (playing.track.durationMs).map { Double($0) / 1000 }) {
                        nowPlaying.livePosition()
                    }
                    .id(playing.track.id)  // rebuild per song
                } else {
                    LiveWaitingView(title: playing.track.name,
                                    subtitle: playing.track.artistNames.uppercased(),
                                    message: nowPlaying.analysisFailed
                                        ? "Chords unavailable for this song."
                                        : "Analyzing chords…",
                                    spinning: !nowPlaying.analysisFailed)
                }
            } else {
                LiveWaitingView(title: "Nothing playing", subtitle: "",
                                message: "Play something on Spotify.", spinning: false)
            }
        }
    }
}

/// Same, bound to the mic identification session.
struct MicLiveView: View {
    @ObservedObject private var session = AutoSession.shared

    var body: some View {
        Group {
            if let entry = session.nowEntry {
                if let analysis = entry.analysis {
                    LiveNowView(title: entry.title, artist: entry.artist,
                                analysis: analysis) { session.livePosition(for: entry.id) }
                        .id(entry.id)  // rebuild per song
                } else {
                    LiveWaitingView(title: entry.title, subtitle: entry.artist.uppercased(),
                                    message: "Analyzing chords…", spinning: true)
                }
            } else {
                LiveWaitingView(title: "Listening…", subtitle: "",
                                message: "Play your music out loud.", spinning: true)
            }
        }
    }
}

/// Placeholder shown while the current song has no analysis yet.
struct LiveWaitingView: View {
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
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 34)
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}
