import Foundation

/// The native connection identifies this physical Spotify player. It is not
/// a Spotify Connect device ID and must never be sent to the Web API.
@MainActor
protocol SpotifyNativeTransport: AnyObject {
    var isConnected: Bool { get }
    func connect(token: String, completion: @escaping (Result<Void, Error>) -> Void)
    func disconnect()
    func current() async throws -> SpotifyAPI.CurrentlyPlaying?
    func playURI(_ trackID: String) async throws
    func seek(_ seconds: Double) async throws
}

@MainActor
final class SpotifyNativeSession {
    static let device = SpotifyAPI.Device(id: "chordlyze-local-spotify", name: "This iPhone",
                                          type: "Smartphone", isActive: true, isRestricted: false)
    private let transport: SpotifyNativeTransport
    private let sleep: (Double) async throws -> Void
    private var token: String?
    private var active = true
    private var attempt: UUID?
    private var timeout: Task<Void, Never>?
    private var completion: ((String?) -> Void)?

    init(transport: SpotifyNativeTransport,
         sleep: @escaping (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.transport = transport
        self.sleep = sleep
    }
    var isConnected: Bool { active && token != nil && transport.isConnected }

    /// Authorization alone does not establish App Remote. Only its connection
    /// delegate may complete the handoff. The token is kept in memory only.
    func authorize(token: String, completion: @escaping (String?) -> Void) {
        disconnect()
        self.token = token
        self.completion = completion
        reconnect()
    }
    func sceneChanged(active: Bool) {
        guard self.active != active else { return }
        self.active = active
        if active { reconnect() } else { disconnect() }
    }
    func reconnect() {
        guard active, let token, attempt == nil else { return }
        if transport.isConnected { finish(nil); return }
        let id = UUID()
        attempt = id
        timeout = Task { [weak self, sleep] in
            do { try await sleep(10) } catch { return }
            guard let self, attempt == id else { return }
            disconnect()
            finish("Spotify did not finish connecting. Open Spotify and try again.")
        }
        transport.connect(token: token) { [weak self] result in
            guard let self, attempt == id, active else { return }
            attempt = nil
            timeout?.cancel(); timeout = nil
            switch result {
            case .success where transport.isConnected: finish(nil)
            default:
                transport.disconnect()
                finish("Spotify could not finish connecting. Open Spotify and try again.")
            }
        }
    }
    private func finish(_ error: String?) {
        let notify = completion
        completion = nil
        notify?(error)
    }
    private func disconnect() {
        attempt = nil
        timeout?.cancel(); timeout = nil
        transport.disconnect()
    }
    func reset() {
        token = nil
        completion = nil
        disconnect()
    }

    /// Select a transport once a command has a device. A native reconnect
    /// during a Web API command cannot change that command's confirmation
    /// source, and a native disconnect cannot redirect a command elsewhere.
    func service(fallback: SpotifyNowPlaying.Service) -> SpotifyNowPlaying.Service {
        SpotifyNowPlaying.Service(
            current: { [self] in
                if isConnected { return try await transport.current() }
                return try await fallback.current()
            },
            seek: fallback.seek,
            play: { [self] track, position, device in
                if device == Self.device.id { try await playNative(track, at: position) }
                else { try await fallback.play(track, position, device) }
            },
            devices: { [self] in
                if isConnected { return [Self.device] }
                return try await fallback.devices()
            },
            seekOnDevice: { [self] position, device in
                if device == Self.device.id {
                    guard isConnected else { throw SpotifyNowPlaying.PlayError.connectionLost }
                    try await transport.seek(position)
                } else if let seek = fallback.seekOnDevice { try await seek(position, device) }
                else { try await fallback.seek(position) }
            },
            currentOnDevice: { [self] device in
                if device == Self.device.id {
                    guard isConnected else { throw SpotifyNowPlaying.PlayError.connectionLost }
                    return try await transport.current()
                }
                if let current = fallback.currentOnDevice { return try await current(device) }
                return try await fallback.current()
            },
            sleep: fallback.sleep)
    }
    private func playNative(_ track: String, at position: Double) async throws {
        guard isConnected else { throw SpotifyNowPlaying.PlayError.connectionLost }
        try await transport.playURI(track)
        guard position > 0 else { return }
        // An accepted play callback can precede the actual track change.
        // Seeking before that change would seek the previous song.
        for index in 0..<12 {
            try Task.checkCancellation()
            guard isConnected else { throw SpotifyNowPlaying.PlayError.connectionLost }
            let current = try await transport.current()
            try Task.checkCancellation()
            guard isConnected else { throw SpotifyNowPlaying.PlayError.connectionLost }
            if current?.item?.id == track {
                try await transport.seek(position)
                return
            }
            if index < 11 { try await sleep(0.25) }
        }
        throw SpotifyNowPlaying.PlayError.notConfirmed
    }
}
