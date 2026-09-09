import SpotifyiOS
import UIKit

/// Own the complete native session, not just its authorization URL. The
/// foreground connection reads and controls the Spotify app on this phone;
/// PKCE credentials remain exclusively owned by SpotifyAuth.
@MainActor
final class SpotifyAppLauncher {
    static let shared = SpotifyAppLauncher()
    private let authorizer = SPTAppRemote(configuration: SPTConfiguration(
        clientID: Config.spotifyClientID, redirectURL: URL(string: Config.redirectURI)!), logLevel: .none)
    private let session = SpotifyNativeSession(transport: SpotifySDKTransport())
    private var pending: (id: UUID, connected: (String?) -> Void)?
    private var detachedTimeout: Task<Void, Never>?

    func playbackService(fallback: SpotifyNowPlaying.Service) -> SpotifyNowPlaying.Service {
        session.service(fallback: fallback)
    }
    func sceneChanged(active: Bool) { session.sceneChanged(active: active) }

    @discardableResult
    func open(trackID: String, opened: @escaping (Bool) -> Void,
              authorized: @escaping (String?) -> Void) -> UUID {
        let id = UUID()
        detachedTimeout?.cancel(); detachedTimeout = nil
        pending = nil
        if session.isConnected {
            opened(true)
            authorized(nil)
            return id
        }
        pending = (id, authorized)
        authorizer.authorizeAndPlayURI("spotify:track:\(trackID)") { [weak self] installed in
            Task { @MainActor in
                guard self?.pending?.id == id else { return }
                if !installed { self?.pending = nil }
                opened(installed)
            }
        }
        return id
    }
    func handle(_ url: URL) {
        guard let pending,
              SpotifyLaunchCallback.matches(url, redirectURI: Config.redirectURI),
              let parameters = authorizer.authorizationParameters(from: url),
              let result = SpotifyLaunchCallback.result(accessToken: parameters[SPTAppRemoteAccessTokenKey],
                                                         error: parameters[SPTAppRemoteErrorDescriptionKey]) else { return }
        switch result {
        case .success:
            guard let token = parameters[SPTAppRemoteAccessTokenKey] else { return }
            session.authorize(token: token) { [weak self] error in
                guard let self, let current = self.pending, current.id == pending.id else { return }
                self.pending = nil
                self.detachedTimeout?.cancel(); self.detachedTimeout = nil
                current.connected(error)
            }
        case .failure(let message):
            self.pending = nil
            detachedTimeout?.cancel(); detachedTimeout = nil
            session.reset()
            pending.connected(message)
        }
    }
    func cancel(_ id: UUID) {
        guard pending?.id == id else { return }
        pending = nil
        detachedTimeout?.cancel(); detachedTimeout = nil
        session.reset()
    }
    /// Playback is already being followed from fresh player state. Detach
    /// this UI handoff while preserving any native connection in progress.
    func finishHandoff(_ id: UUID) {
        guard pending?.id == id else { return }
        pending = (id, { _ in })
        detachedTimeout?.cancel()
        // Accept a late authorization URL for this same attempt so a useful
        // native connection can still establish. It cannot restore old UI.
        detachedTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.pending?.id == id else { return }
            self.pending = nil
            self.detachedTimeout = nil
        }
    }
    func reset() {
        pending = nil
        detachedTimeout?.cancel(); detachedTimeout = nil
        session.reset()
    }
}

/// SDK callbacks identify their connection instance. A delayed callback from
/// an old foreground session cannot revive it or finish a newer request.
@MainActor
private final class SpotifySDKTransport: NSObject, SpotifyNativeTransport, @preconcurrency SPTAppRemoteDelegate {
    private var remote: SPTAppRemote?
    private var connectionReply: ((Result<Void, Error>) -> Void)?
    private var replies: [UUID: (Result<Any, Error>) -> Void] = [:]
    var isConnected: Bool { remote?.isConnected == true }

    func connect(token: String, completion: @escaping (Result<Void, Error>) -> Void) {
        disconnect()
        let next = SPTAppRemote(configuration: SPTConfiguration(clientID: Config.spotifyClientID,
            redirectURL: URL(string: Config.redirectURI)!), logLevel: .none)
        next.connectionParameters.accessToken = token
        next.delegate = self
        remote = next
        connectionReply = completion
        next.connect()
    }
    func disconnect() {
        let old = remote
        remote = nil
        old?.delegate = nil
        old?.disconnect()
        let notify = connectionReply
        connectionReply = nil
        notify?(.failure(SpotifyNowPlaying.PlayError.connectionLost))
        for id in Array(replies.keys) { finish(id, .failure(SpotifyNowPlaying.PlayError.connectionLost)) }
    }
    func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        guard remote === appRemote else { return }
        let notify = connectionReply
        connectionReply = nil
        notify?(.success(()))
    }
    func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        guard remote === appRemote else { return }
        disconnect()
    }
    func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        guard remote === appRemote else { return }
        disconnect()
    }
    private func finish(_ id: UUID, _ result: Result<Any, Error>) {
        replies.removeValue(forKey: id)?(result)
    }
    private func request(_ send: @escaping (SPTAppRemote, @escaping SPTAppRemoteCallback) -> Void) async throws -> Any {
        try Task.checkCancellation()
        guard let current = remote, current.isConnected, current.playerAPI != nil else {
            throw SpotifyNowPlaying.PlayError.connectionLost
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    self?.finish(id, .failure(URLError(.timedOut)))
                }
                replies[id] = { result in
                    deadline.cancel()
                    continuation.resume(with: result)
                }
                guard !Task.isCancelled else { finish(id, .failure(CancellationError())); return }
                send(current) { [weak self, weak current] result, error in
                    Task { @MainActor in
                        guard let self, let current, self.remote === current else { return }
                        if error != nil { self.finish(id, .failure(SpotifyNowPlaying.PlayError.forbidden)) }
                        else if let result { self.finish(id, .success(result)) }
                        else { self.finish(id, .failure(SpotifyNowPlaying.PlayError.connectionLost)) }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, .failure(CancellationError())) }
        }
    }
    func current() async throws -> SpotifyAPI.CurrentlyPlaying? {
        let value = try await request { remote, reply in remote.playerAPI?.getPlayerState(reply) }
        guard let state = value as? SPTAppRemotePlayerState else { throw SpotifyNowPlaying.PlayError.connectionLost }
        let source = state.track
        let parts = source.uri.split(separator: ":")
        let track: Track?
        if parts.count == 3, parts[0] == "spotify", parts[1] == "track", !source.isAdvertisement, !source.isEpisode {
            track = Track(id: String(parts[2]), name: source.name, artists: [.init(name: source.artist.name)],
                          album: .init(name: source.album.name, images: nil), externalIds: nil,
                          durationMs: Int(clamping: source.duration))
        } else { track = nil }
        return .init(progressMs: max(0, state.playbackPosition), isPlaying: !state.isPaused,
                     item: track, device: SpotifyNativeSession.device)
    }
    func playURI(_ trackID: String) async throws {
        _ = try await request { remote, reply in remote.playerAPI?.play("spotify:track:\(trackID)", callback: reply) }
    }
    func seek(_ seconds: Double) async throws {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max / 1000) else {
            throw SpotifyNowPlaying.PlayError.invalidPosition
        }
        _ = try await request { remote, reply in remote.playerAPI?.seek(toPosition: Int(seconds * 1000), callback: reply) }
    }
}
