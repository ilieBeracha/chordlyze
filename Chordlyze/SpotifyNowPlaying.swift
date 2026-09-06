import Combine
import Foundation

/// Spotify state polling is independent of lyric fetching and recognition.
/// Restarts invalidate old requests; transient failures recover in place.
@MainActor
final class SpotifyNowPlaying: ObservableObject {
    static let shared = SpotifyNowPlaying()
    struct Playing: Equatable {
        let track: Track
        let isPlaying: Bool
        static func == (l: Playing, r: Playing) -> Bool {
            l.track.id == r.track.id && l.isPlaying == r.isPlaying
        }
    }
    struct Service {
        var current: () async throws -> SpotifyAPI.CurrentlyPlaying?
        var seek: (Double) async throws -> Void
        var play: (String, Double, String?) async throws -> Void = { _, _, _ in throw PlayError.notConnected }
        var devices: () async throws -> [SpotifyAPI.Device] = { throw PlayError.notConnected }
        var sleep: (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    }
    enum PlayError: LocalizedError, Equatable {
        case notConnected, noDevice, onlyElsewhere(String), premiumRequired, notConfirmed, failed(Int)
        var errorDescription: String? {
            switch self {
            case .notConnected: return "Spotify is not connected. Reconnect it in Profile."
            case .noDevice: return "Spotify is not open on this phone. Open the Spotify app once, then try again."
            case .onlyElsewhere(let name): return "Spotify is only available on \(name) right now. Open the Spotify app on this phone once, then try again."
            case .premiumRequired: return "Starting playback from Chordlyze needs Spotify Premium. Play the song in Spotify instead."
            case .notConfirmed: return "Spotify did not report the song playing from the requested position. Try again."
            case .failed(let code): return "Spotify returned \(code)."
            }
        }
    }
    @Published private(set) var playing: Playing?
    @Published private(set) var analysis: ChordAnalysis?
    @Published private(set) var analysisFailed = false
    @Published private(set) var needsReauth = false
    @Published private(set) var connectionMessage: String?
    /// Name of the phone Spotify device the last practice start targeted.
    @Published private(set) var playbackDevice: String?
    private var anchor: (offset: Double, at: ContinuousClock.Instant)?
    private var lastSuccess: ContinuousClock.Instant?
    private var pollTask: Task<Void, Never>?
    private var sheetTask: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var sheetID: String?
    private var service: Service?
    private var generation = 0
    private var now: () -> ContinuousClock.Instant
    private var sheetProvider: @MainActor (Track) -> SongSheetStore

    init(service: Service? = nil, now: @escaping () -> ContinuousClock.Instant = { .now },
         sheetProvider: @escaping @MainActor (Track) -> SongSheetStore = { SongSheetStore.shared(for: SongDescriptor(track: $0)) }) {
        self.service = service
        self.now = now
        self.sheetProvider = sheetProvider
    }
    var playbackNote: String? {
        if needsReauth { return "Reconnect Spotify in Profile to resume live follow." }
        if let connectionMessage { return connectionMessage }
        if playing?.isPlaying == false { return "Playback paused" }
        return nil
    }
    func start(api: SpotifyAPI) {
        service = Service(current: { try await api.currentlyPlaying() },
                          seek: { try await api.seek(toMs: Int($0 * 1000)) },
                          play: { try await api.play(trackID: $0, positionMs: Int($1 * 1000), deviceID: $2) },
                          devices: { try await api.devices() })
        restart()
    }
    func resume() {
        guard service != nil else { return }
        restart()
    }
    func stop() {
        generation += 1
        pollTask?.cancel(); pollTask = nil
        sheetTask?.cancel(); sheetTask = nil
        subscriptions.removeAll()
        sheetID = nil
    }
    func reset() {
        stop()
        service = nil
        playing = nil
        anchor = nil
        lastSuccess = nil
        analysis = nil
        analysisFailed = false
        needsReauth = false
        connectionMessage = nil
    }
    private func restart() {
        stop()
        guard let service else { return }
        needsReauth = false
        let token = generation
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, generation == token else { return }
                let delay = await poll(service: service, token: token)
                guard generation == token, !Task.isCancelled else { return }
                do { try await service.sleep(delay) } catch { return }
            }
        }
    }
    func livePosition() -> TimeInterval? { position(at: now()) }
    private func position(at instant: ContinuousClock.Instant) -> Double? {
        guard let anchor, let playing else { return nil }
        let bound = playing.track.durationMs.map { Double($0) / 1000 } ?? .infinity
        guard playing.isPlaying else { return min(bound, max(0, anchor.offset)) }
        // Do not manufacture unbounded playback during a connection loss.
        let reliableUntil = lastSuccess?.advanced(by: .seconds(15)) ?? instant
        let elapsed = anchor.at.duration(to: min(instant, reliableUntil)).seconds
        return min(bound, max(0, anchor.offset + elapsed))
    }
    private func poll(service: Service, token: Int) async -> Double {
        do {
            let sent = now()
            let current = try await service.current()
            let received = now()
            guard !Task.isCancelled, token == generation else { return 2 }
            lastSuccess = received
            connectionMessage = nil
            guard let current, let track = current.item else {
                playing = nil
                anchor = nil
                analysis = nil
                analysisFailed = false
                sheetTask?.cancel(); sheetTask = nil
                subscriptions.removeAll(); sheetID = nil
                return 3
            }
            let sampledAt = sent.advanced(by: sent.duration(to: received) / 2)
            let next = Playing(track: track, isPlaying: current.isPlaying)
            if let ms = current.progressMs {
                let reported = max(0, Double(ms) / 1000)
                let predicted = playing == next ? position(at: sampledAt) : nil
                if predicted == nil || abs(predicted! - reported) >= 0.4 {
                    anchor = (reported, sampledAt)
                }
            } else if playing?.track.id != track.id {
                anchor = nil
            } else if playing?.isPlaying != current.isPlaying, let position = position(at: sampledAt) {
                // Spotify occasionally omits progress during pause/resume.
                // Freeze/resume the current estimate, never the old sample.
                anchor = (position, sampledAt)
            }
            playing = next
            observeSheet(track)
            return 2
        } catch {
            guard !Task.isCancelled, token == generation else { return 2 }
            let error = error as NSError
            if error.code == 401 || error.code == 403 {
                needsReauth = true
                stop()
                return 30
            }
            if error.code == 429 {
                connectionMessage = "Spotify is limiting requests. Live follow will reconnect automatically."
                return max(1, error.userInfo["retryAfter"] as? Double ?? 5)
            }
            connectionMessage = "Playback connection interrupted. Reconnecting…"
            return 3
        }
    }
    /// Follows the playing song's document. This only reads its status; the
    /// song is analyzed when the user taps Analyze, never because it played.
    private func observeSheet(_ track: Track) {
        guard sheetID != track.id else { return }
        sheetTask?.cancel()
        subscriptions.removeAll()
        sheetID = track.id
        analysis = nil
        analysisFailed = false
        let sheet = sheetProvider(track)
        sheet.$analysis.sink { [weak self] value in
            guard self?.playing?.track.id == track.id else { return }
            self?.analysis = value
        }.store(in: &subscriptions)
        sheet.$state.sink { [weak self] value in
            guard self?.playing?.track.id == track.id else { return }
            self?.analysisFailed = ["failed", "unavailable"].contains(value)
        }.store(in: &subscriptions)
        sheetTask = Task { await sheet.observe() }
    }
    /// The phone in the account's device list: the active smartphone, else
    /// any smartphone. Practice must play where the headphones are, never on
    /// whatever device Spotify last used (a laptop across the room counts as
    /// "active" and the phone hears nothing).
    static func practiceDevice(_ devices: [SpotifyAPI.Device]) throws -> SpotifyAPI.Device {
        let phones = devices.filter { $0.type.caseInsensitiveCompare("Smartphone") == .orderedSame && $0.id != nil }
        if let phone = phones.first(where: \.isActive) ?? phones.first { return phone }
        if let other = devices.first(where: \.isActive) ?? devices.first { throw PlayError.onlyElsewhere(other.name) }
        throw PlayError.noDevice
    }

    /// Start `trackID` at `seconds` on this phone's Spotify, then wait until
    /// a fresh poll reports it playing near that position. The playhead is
    /// never assumed from the request: it comes from Spotify's own report.
    func play(trackID: String, at seconds: Double) async throws {
        guard let service else { throw PlayError.notConnected }
        let issued = now()
        let target = max(0, seconds)
        do {
            let device = try Self.practiceDevice(try await service.devices())
            playbackDevice = device.name
            try await service.play(trackID, target, device.id)
        } catch let error as PlayError {
            throw error
        } catch {
            switch (error as NSError).code {
            case 404: throw PlayError.noDevice
            case 403: throw PlayError.premiumRequired
            case 401: needsReauth = true; stop(); throw PlayError.notConnected
            case let code: throw PlayError.failed(code)
            }
        }
        restart()
        for _ in 0..<40 {
            try await service.sleep(0.1)
            guard let lastSuccess, lastSuccess > issued, let playing, playing.track.id == trackID, playing.isPlaying,
                  let position = livePosition(), abs(position - seconds) < 3 else { continue }
            return
        }
        throw PlayError.notConfirmed
    }
    func seek(to seconds: Double) async -> Bool {
        guard let service, let trackID = playing?.track.id, seconds.isFinite else { return false }
        let target = max(0, min(seconds, playing?.track.durationMs.map { Double($0) / 1000 } ?? seconds))
        do {
            try await service.seek(target)
            guard playing?.track.id == trackID else { return false }
            anchor = (target, now())
            lastSuccess = now()
            return true
        } catch { return false }
    }
}

extension Duration {
    var seconds: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
