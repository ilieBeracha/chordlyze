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

/// Wake Spotify after an explicit play request. Discovery on return is
/// read-only; only casual play-along opts into automatically continuing.
struct SpotifyDeviceRecoveryView: View {
    let trackID: String
    var retryTitle = "Retry playback"
    var onRetry: () -> Void
    var automaticallyOpen = false
    var continueWhenReady = false
    @StateObject private var recovery: SpotifyDeviceRecovery
    @State private var didAutomaticallyOpen = false
    @State private var launchID: UUID?
    @State private var spotifyNotInstalled = false
    @Environment(\.scenePhase) private var scenePhase

    @MainActor init(nowPlaying: SpotifyNowPlaying, trackID: String, retryTitle: String,
                    automaticallyOpen: Bool = false, continueWhenReady: Bool = false, onRetry: @escaping () -> Void) {
        self.trackID = trackID
        self.retryTitle = retryTitle
        self.onRetry = onRetry
        self.automaticallyOpen = automaticallyOpen
        self.continueWhenReady = continueWhenReady
        _recovery = StateObject(wrappedValue: SpotifyDeviceRecovery(checkDevice: {
            try await nowPlaying.checkPracticeDevice(afterAppSwitch: true)
        }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            #if targetEnvironment(simulator)
            Label("Use a physical iPhone", systemImage: "iphone")
                .font(.headline)
            Text("The iOS Simulator cannot run the Spotify app. To play on your phone, run Chordlyze there and open Spotify using the same account.")
                .font(.subheadline).foregroundStyle(.secondary)
            #else
            Label("Connect Spotify", systemImage: "iphone.and.arrow.forward")
                .font(.headline)
            Text("Spotify will open with this song and return you here. Allow Chordlyze to connect if asked. Use the same Spotify account in both apps.")
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
                if spotifyNotInstalled {
                    Link("Install Spotify", destination: URL(string: "https://apps.apple.com/app/spotify-music-and-podcasts/id324684580")!)
                        .buttonStyle(.borderedProminent)
                }
            case .waitingForSpotify:
                Text(continueWhenReady ? "Opening Spotify… Your song will continue here once connected." : "Opening Spotify… Your settings are kept. Return here and tap \(retryTitle) when you’re ready.")
                    .font(.footnote).foregroundStyle(.secondary)
            case .awaitingAuthorization:
                ProgressView("Finishing Spotify connection…")
            case .idle: EmptyView()
            }
            if case .ready = recovery.state { } else {
                #if !targetEnvironment(simulator)
                Button("Open Spotify", systemImage: "arrow.up.forward.app", action: openSpotify)
                .buttonStyle(.borderedProminent)
                .disabled(recovery.state == .checking || recovery.state == .waitingForSpotify || recovery.state == .awaitingAuthorization)
                .accessibilityIdentifier("open-spotify-recovery")
                #endif
                Button("Check connection again") {
                    cancelLaunch()
                    recovery.retry()
                }
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
        .task {
            #if !targetEnvironment(simulator)
            guard automaticallyOpen, !didAutomaticallyOpen else { return }
            didAutomaticallyOpen = true
            openSpotify()
            #endif
        }
        .task(id: recovery.authorizationWaitID) {
            guard let attempt = recovery.authorizationWaitID else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            recovery.authorizationTimedOut(attempt: attempt)
            cancelLaunch()
        }
        .onChange(of: recovery.state) { _, state in
            if continueWhenReady, case .ready = state { onRetry() }
        }
        .onChange(of: scenePhase) { _, phase in recovery.sceneChanged(active: phase == .active) }
        .onDisappear { recovery.cancel(); cancelLaunch() }
    }

    private func openSpotify() {
        cancelLaunch()
        spotifyNotInstalled = false
        let attempt = recovery.openRequested(expectsAuthorization: true)
        launchID = SpotifyAppLauncher.shared.open(trackID: trackID, opened: {
            spotifyNotInstalled = !$0
            recovery.openCompleted($0, attempt: attempt)
        }, authorized: {
            recovery.authorizationCompleted(error: $0, attempt: attempt)
        })
    }

    private func cancelLaunch() {
        if let launchID { SpotifyAppLauncher.shared.cancel(launchID) }
        launchID = nil
    }
}
