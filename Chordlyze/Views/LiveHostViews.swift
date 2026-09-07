import SwiftUI

/// Live follow-along bound to the Spotify poller: when the song changes, the
/// view swaps to the new track (fresh lyrics, chords, position) instead of
/// staying stuck on the one it was opened with.
struct SpotifyLiveView: View {
    @ObservedObject private var nowPlaying = SpotifyNowPlaying.shared

    var body: some View {
        Group {
            if let playing = nowPlaying.playing {
                AnalysisTabsView(song: SongDescriptor(track: playing.track))
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
    /// Calibrated chart time, no display lead.
    let chartPosition: () -> TimeInterval?

    var body: some View {
        if store.canPractice {
            LiveNowView(store: store, onSeek: onSeek, playbackNote: playbackNote, chartPosition: chartPosition)
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
        .toolbar(.hidden, for: .tabBar)
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
        .toolbar(.hidden, for: .tabBar)
    }
}

/// Shared by practice and automatic synchronization when Connect can't see
/// the phone. Opening Spotify is explicit; returning only checks its device.
struct SpotifyDeviceRecoveryView: View {
    let trackID: String
    var retryTitle = "Retry playback"
    var onRetry: () -> Void
    @StateObject private var recovery: SpotifyDeviceRecovery
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @MainActor init(nowPlaying: SpotifyNowPlaying, trackID: String, retryTitle: String, onRetry: @escaping () -> Void) {
        self.trackID = trackID
        self.retryTitle = retryTitle
        self.onRetry = onRetry
        _recovery = StateObject(wrappedValue: SpotifyDeviceRecovery(checkDevice: { try await nowPlaying.checkPracticeDevice() }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            #if targetEnvironment(simulator)
            Label("Use a physical iPhone", systemImage: "iphone")
                .font(.headline)
            Text("The iOS Simulator cannot run the Spotify app. To play on your phone, run Chordlyze there and open Spotify using the same account.")
                .font(.subheadline).foregroundStyle(.secondary)
            #else
            Label("Connect Spotify on this phone", systemImage: "iphone.and.arrow.forward")
                .font(.headline)
            Text("In Spotify, select this phone in the device picker and start the song. Then return here. Use the same Spotify account in both apps.")
                .font(.subheadline).foregroundStyle(.secondary)
            #endif
            switch recovery.state {
            case .checking:
                ProgressView("Looking for this phone…")
            case .ready(let name):
                Label("Ready on \(name)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).accessibilityIdentifier("spotify-device-ready")
                Button(retryTitle, action: onRetry).buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("spotify-retry-playback")
            case .failed(let message):
                Text(message).font(.footnote).foregroundStyle(.orange)
                    .accessibilityIdentifier("spotify-device-error")
            case .waitingForSpotify:
                Text("Return from Spotify when this phone is selected. We’ll check the connection without starting a recording.")
                    .font(.footnote).foregroundStyle(.secondary)
            case .idle: EmptyView()
            }
            if case .ready = recovery.state { } else {
                #if !targetEnvironment(simulator)
                Button("Open Spotify", systemImage: "arrow.up.forward.app") {
                    let attempt = recovery.openRequested()
                    openURL(URL(string: "spotify:track:\(trackID)")!) { opened in
                        recovery.openCompleted(opened, attempt: attempt)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(recovery.state == .checking)
                .accessibilityIdentifier("open-spotify-recovery")
                #endif
                Button("Check connection again") { recovery.retry() }
                    .disabled(recovery.state == .checking)
                    .accessibilityIdentifier("check-spotify-device")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.06)))
        .task(id: recovery.state == .checking) {
            if recovery.state == .checking { await recovery.check() }
        }
        .onChange(of: scenePhase) { _, phase in recovery.sceneChanged(active: phase == .active) }
        .onDisappear { recovery.cancel() }
    }
}
