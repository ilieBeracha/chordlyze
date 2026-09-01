import SwiftUI

/// Home-screen Now Playing card. Automatically shows what the Spotify account
/// is playing (any device, no mic); tap opens the live follow-along view.
/// Mic identification remains as a fallback for non-Spotify audio.
struct NowPlayingCard: View {
    @EnvironmentObject var auth: SpotifyAuth
    @ObservedObject private var nowPlaying = SpotifyNowPlaying.shared
    @ObservedObject private var micSession = AutoSession.shared

    var body: some View {
        Group {
            if micSession.isRunning {
                micCard
            } else if let playing = nowPlaying.playing {
                spotifyCard(playing)
            } else if nowPlaying.needsReauth {
                reauthCard
            } else {
                idleCard
            }
        }
        .task { nowPlaying.start(api: SpotifyAPI(auth: auth)) }
    }

    // MARK: - Spotify (automatic)

    private func spotifyCard(_ playing: SpotifyNowPlaying.Playing) -> some View {
        let track = playing.track
        let analysis = nowPlaying.analysis
        let body = VStack(alignment: .leading, spacing: 14) {
            label(text: playing.isPlaying ? "NOW PLAYING" : "PAUSED",
                  color: playing.isPlaying ? Color.spotifyGreen : Palette.tertiary,
                  dot: playing.isPlaying ? Color.spotifyGreen : Palette.gray5)
            HStack(spacing: 14) {
                artwork(url: (track.album.images?.first?.url).flatMap(URL.init))
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.name)
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(track.artistNames.uppercased())
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                    statusText(analysis: analysis, failed: nowPlaying.analysisFailed)
                }
                Spacer()
                if analysis != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.secondary)
                } else if !nowPlaying.analysisFailed {
                    ProgressView().controlSize(.small)
                }
            }
            progressRail(duration: (track.durationMs).map { Double($0) / 1000 }
                            ?? analysis?.chords.last?.end ?? 0,
                         position: { nowPlaying.livePosition() ?? 0 })
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 18)
        .padding(.horizontal, 20)
        .background(cardShape)

        return Group {
            if let analysis {
                NavigationLink {
                    LiveNowView(title: track.name, artist: track.artistNames,
                                analysis: analysis) { nowPlaying.livePosition() }
                } label: {
                    body
                }
                .buttonStyle(.plain)
            } else {
                body
            }
        }
    }

    @ViewBuilder
    private func statusText(analysis: ChordAnalysis?, failed: Bool) -> some View {
        if let key = analysis?.key {
            Text("Key \(key) · Tap to follow live")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.spotifyGreen)
                .padding(.top, 3)
        } else if analysis != nil {
            Text("Tap to follow live")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.spotifyGreen)
                .padding(.top, 3)
        } else if failed {
            Text("Chords unavailable for this song")
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
                .padding(.top, 3)
        } else {
            Text("Analyzing chords…")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.secondary)
                .padding(.top, 3)
        }
    }

    private var reauthCard: some View {
        Button {
            nowPlaying.start(api: SpotifyAPI(auth: auth))
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                label(text: "NOW PLAYING", color: Palette.tertiary, dot: Palette.gray5)
                Text("Reconnect Spotify")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Log in again from Profile to show what you're playing automatically.")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.heroSub)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 22)
            .padding(.horizontal, 20)
            .background(cardShape)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Idle (nothing on Spotify)

    private var idleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            label(text: "NOW PLAYING", color: Color.spotifyGreen, dot: Color.spotifyGreen)
            Text("Nothing playing")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("Play something on Spotify — it appears here with live chords.")
                .font(.system(size: 14))
                .foregroundStyle(Palette.heroSub)
                .multilineTextAlignment(.leading)
            Button {
                Task { await micSession.start() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "mic.fill").font(.system(size: 12, weight: .bold))
                    Text("Listen with mic instead")
                        .font(.system(size: 13, weight: .bold))
                }
                .foregroundStyle(.black)
                .padding(.vertical, 9)
                .padding(.horizontal, 16)
                .background(Capsule().fill(Color.spotifyGreen))
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            if !micSession.statusLine.isEmpty, micSession.statusLine.contains("denied") {
                Text(micSession.statusLine)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.destructive)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 22)
        .padding(.horizontal, 20)
        .background(cardShape)
    }

    // MARK: - Mic fallback (running)

    @ViewBuilder
    private var micCard: some View {
        ZStack(alignment: .topTrailing) {
            if let entry = micSession.nowEntry {
                if let analysis = entry.analysis {
                    NavigationLink {
                        LiveNowView(title: entry.title, artist: entry.artist,
                                    analysis: analysis) { micSession.livePosition(for: entry.id) }
                    } label: {
                        micSongBody(entry, analysis: analysis)
                    }
                    .buttonStyle(.plain)
                } else {
                    micSongBody(entry, analysis: nil)
                }
            } else {
                listeningBody
            }
            stopButton
        }
    }

    private var listeningBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            label(text: "LISTENING", color: Color.spotifyGreen, dot: Color.spotifyGreen)
            Text("Waiting for a song…")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("Play your music out loud.")
                .font(.system(size: 14))
                .foregroundStyle(Palette.heroSub)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 22)
        .padding(.horizontal, 20)
        .background(cardShape)
    }

    private func micSongBody(_ entry: AutoSession.Entry, analysis: ChordAnalysis?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            label(text: "NOW PLAYING", color: Color.spotifyGreen, dot: Color.spotifyGreen)
            HStack(spacing: 14) {
                artwork(url: entry.artworkURL)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(entry.artist.uppercased())
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                    Text(analysis == nil ? "Analyzing chords…" : "Tap to follow live")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(analysis == nil ? Palette.secondary : Color.spotifyGreen)
                        .padding(.top, 3)
                }
                Spacer()
                if analysis != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            progressRail(duration: analysis?.chords.last?.end ?? 0,
                         position: { micSession.livePosition(for: entry.id) ?? 0 })
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 18)
        .padding(.horizontal, 20)
        .background(cardShape)
    }

    private var stopButton: some View {
        Button {
            micSession.stop()
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Palette.destructive)
                .padding(8)
                .background(Circle().fill(Palette.destructive.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .padding(10)
    }

    // MARK: - Shared pieces

    private func progressRail(duration: Double, position: @escaping () -> Double) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let pos = position()
            HStack(spacing: 10) {
                Text(timestamp(pos))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.spotifyGreen)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.elevated)
                        if duration > 0 {
                            Capsule()
                                .fill(Color.spotifyGreen)
                                .frame(width: geo.size.width * min(1, max(0, pos / duration)))
                        }
                    }
                }
                .frame(height: 4)
                if duration > 0 {
                    Text(timestamp(duration))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Palette.secondary)
                }
            }
        }
        .frame(height: 14)
    }

    @ViewBuilder
    private func artwork(url: URL?) -> some View {
        AsyncImage(url: url) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            ZStack {
                Palette.elevated
                Image(systemName: "music.note")
                    .font(.system(size: 20))
                    .foregroundStyle(Palette.secondary)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func label(text: String, color: Color, dot: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(dot).frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 12, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(color)
        }
    }

    private var cardShape: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Palette.heroBackground)
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.spotifyGreen.opacity(0.25), lineWidth: 1))
    }

    private func timestamp(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(max(0, seconds)) / 60, Int(max(0, seconds)) % 60)
    }
}
