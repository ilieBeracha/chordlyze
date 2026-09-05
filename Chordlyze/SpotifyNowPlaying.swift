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
        var sleep: (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    }
    @Published private(set) var playing: Playing?
    @Published private(set) var analysis: ChordAnalysis?
    @Published private(set) var analysisFailed = false
    @Published private(set) var needsReauth = false
    @Published private(set) var connectionMessage: String?
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
                          seek: { try await api.seek(toMs: Int($0 * 1000)) })
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
