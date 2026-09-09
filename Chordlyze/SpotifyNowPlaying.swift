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
        var seekOnDevice: ((Double, String?) async throws -> Void)? = nil
        var currentOnDevice: ((String?) async throws -> SpotifyAPI.CurrentlyPlaying?)? = nil
        var sleep: (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    }
    enum PlayError: LocalizedError, Equatable {
        case notConnected, noDevice, onlyElsewhere(String), premiumRequired, notConfirmed, failed(Int)
        case ambiguousDevice, restrictedDevice, forbidden, rateLimited(Int), connectionLost, invalidPosition
        /// Only absence can be fixed by waking the app. Other device errors
        /// need a deliberate selection in Spotify, not another app switch.
        var canWakeApp: Bool {
            switch self {
            case .noDevice, .onlyElsewhere: return true
            default: return false
            }
        }
        var needsDeviceRecovery: Bool {
            switch self {
            case .noDevice, .onlyElsewhere, .ambiguousDevice, .restrictedDevice: return true
            default: return false
            }
        }
        var errorDescription: String? {
            switch self {
            case .notConnected: return "Spotify is not connected. Reconnect it in Profile."
            case .noDevice: return "Spotify is not available on this phone yet. Open the Spotify app, then try again."
            case .onlyElsewhere(let name): return "Spotify is only available on \(name) right now. Open the Spotify app on this phone once, then try again."
            case .premiumRequired: return "Starting playback from Chordlyze needs Spotify Premium. Play the song in Spotify instead."
            case .notConfirmed: return "Spotify did not report the song playing from the requested position. Try again."
            case .failed(let code): return "Spotify returned \(code). Try again."
            case .ambiguousDevice: return "More than one phone is available. Start playback on this phone in Spotify, then try again."
            case .restrictedDevice: return "Spotify cannot control this device. Select this phone in Spotify, then try again."
            case .forbidden: return "Spotify refused this control. Check the selected device and reconnect Spotify in Profile if it continues."
            case .rateLimited(let seconds): return "Spotify is limiting requests. Try again in \(seconds) seconds."
            case .connectionLost: return "Could not reach Spotify. Check your connection and try again."
            case .invalidPosition: return "This playback position is not valid."
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
    @Published private(set) var controlMessage: String?
    @Published private(set) var isControlling = false
    private var deviceID: String?
    private var deviceRestricted = false
    private var running = false
    private var commandEpoch = 0
    private var activeCommand: UUID?
    private var controlError: PlayError?
    private var controlRevision = 0
    private var followingHandoff = false
    private var seekIntent = 0
    private var retryUntil: ContinuousClock.Instant?
    private var handoffReadBlockedUntil: ContinuousClock.Instant?
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
    var playbackNote: String? { playbackNote(includingControlError: true) }
    var controlMessageRevision: Int { controlRevision }

    /// Device recovery already presents the failed command and its next step.
    /// Its live-status fallback must not repeat that command's earlier error.
    /// Polling success still cannot establish that a failed play or seek worked.
    func playbackNote(includingControlError: Bool) -> String? {
        if needsReauth { return "Reconnect Spotify in Profile to resume live follow." }
        if includingControlError, let controlMessage { return controlMessage }
        if isControlling { return "Waiting for Spotify…" }
        if let connectionMessage { return connectionMessage }
        if playing?.isPlaying == false { return "Playback paused" }
        return nil
    }
    func start(api: SpotifyAPI) {
        let web = Service(current: { try await api.currentlyPlaying() },
                          seek: { try await api.seek(toMs: Int($0 * 1000)) },
                          play: { try await api.play(trackID: $0, positionMs: Int($1 * 1000), deviceID: $2) },
                          devices: { try await api.devices() },
                          seekOnDevice: { try await api.seek(toMs: Int($0 * 1000), deviceID: $1) })
        #if canImport(SpotifyiOS)
        service = SpotifyAppLauncher.shared.playbackService(fallback: web)
        #else
        service = web
        #endif
        resume()
    }
    /// Screens and token refreshes may call this repeatedly. They must not
    /// cancel a command or restart the same poller halfway through startup.
    func resume() {
        guard service != nil else { return }
        running = true
        needsReauth = false
        startPolling()
    }
    private func pausePolling() {
        generation += 1
        pollTask?.cancel(); pollTask = nil
    }
    func stop() {
        running = false
        commandEpoch += 1
        seekIntent += 1
        pausePolling()
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
        setControlError(nil)
        playbackDevice = nil
        deviceID = nil
        retryUntil = nil
        handoffReadBlockedUntil = nil
    }
    private func startPolling() {
        guard running, !needsReauth, pollTask == nil, activeCommand == nil, let service else { return }
        let token = generation
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, generation == token else { return }
                if let retryUntil, retryUntil > now() {
                    do { try await service.sleep(now().duration(to: retryUntil).seconds) } catch { return }
                    // Do not clear a newer cooldown installed while waiting.
                    if self.retryUntil == retryUntil { self.retryUntil = nil }
                }
                guard generation == token, !Task.isCancelled else { return }
                let delay = await poll(service: service, token: token)
                guard generation == token, !Task.isCancelled else { return }
                let cooldown = retryUntil
                do { try await service.sleep(delay) } catch { return }
                if retryUntil == cooldown { retryUntil = nil }
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
            apply(current, sent: sent, received: received)
            return 2
        } catch {
            guard !Task.isCancelled, token == generation else { return 2 }
            let error = error as NSError
            if error.code == 401 {
                needsReauth = true
                pausePolling()
                return 30
            }
            if error.code == 403 {
                connectionMessage = "Spotify refused playback access. Reconnect Spotify in Profile if this continues."
                handoffReadBlockedUntil = now().advanced(by: .seconds(30))
                return 30
            }
            if error.code == 429 {
                connectionMessage = "Spotify is limiting requests. Live follow will reconnect automatically."
                let delay = max(1, error.userInfo["retryAfter"] as? Double ?? 5)
                retryUntil = now().advanced(by: .seconds(delay))
                return delay
            }
            connectionMessage = "Playback connection interrupted. Reconnecting…"
            return 3
        }
    }
    private func apply(_ current: SpotifyAPI.CurrentlyPlaying?, sent: ContinuousClock.Instant,
                       received: ContinuousClock.Instant) {
        lastSuccess = received
        connectionMessage = nil
        handoffReadBlockedUntil = nil
        guard let current, var track = current.item else {
            playing = nil
            deviceID = nil
            deviceRestricted = false
            playbackDevice = nil
            anchor = nil
            analysis = nil
            analysisFailed = false
            sheetTask?.cancel(); sheetTask = nil
            subscriptions.removeAll(); sheetID = nil
            return
        }
        // App Remote's live track omits catalog artwork and ISRC. Keep
        // metadata already loaded for the same song when changing transport.
        if track.album.images?.isEmpty != false, let previous = playing?.track,
           previous.id == track.id, previous.album.images?.isEmpty == false {
            track = previous
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
        deviceID = current.device?.id
        deviceRestricted = current.device?.isRestricted == true
        if let device = current.device { playbackDevice = device.displayName }
        playing = next
        observeSheet(track)
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
    /// Spotify's Web API cannot identify the physical handset. Prefer the
    /// active controllable phone; ask for a selection instead of guessing
    /// between several inactive phones or starting on a laptop.
    static func practiceDevice(_ devices: [SpotifyAPI.Device]) throws -> SpotifyAPI.Device {
        let phones = devices.filter { $0.type.caseInsensitiveCompare("Smartphone") == .orderedSame && $0.id != nil }
        let controllable = phones.filter { $0.isRestricted != true }
        if let active = controllable.first(where: \.isActive) { return active }
        if controllable.count == 1 { return controllable[0] }
        if controllable.count > 1 { throw PlayError.ambiguousDevice }
        if !phones.isEmpty { throw PlayError.restrictedDevice }
        if let other = devices.first(where: \.isActive) ?? devices.first { throw PlayError.onlyElsewhere(other.displayName) }
        throw PlayError.noDevice
    }

    /// Spotify Connect can take a moment to advertise a recently opened phone.
    /// Retry discovery only; never send playback to a different device as fallback.
    private func discoverPhone(service: Service, epoch: Int, afterAppSwitch: Bool = false) async throws -> SpotifyAPI.Device {
        let attempts = afterAppSwitch ? 12 : 3
        let deadline = now().advanced(by: .seconds(12))
        for attempt in 0..<attempts {
            let devices = try await service.devices()
            try checkCommand(epoch)
            do { return try Self.practiceDevice(devices) }
            catch let error as PlayError {
                guard attempt < attempts - 1, now() < deadline else { throw error }
                switch error {
                case .noDevice, .onlyElsewhere:
                    let delay = min(attempt == 0 ? 0.6 : 1.2, now().duration(to: deadline).seconds)
                    try await service.sleep(delay)
                    try checkCommand(epoch)
                default: throw error
                }
            }
        }
        throw PlayError.noDevice
    }

    /// Read-only recovery after visiting Spotify. This never starts audio or
    /// the microphone; the user explicitly retries the practice/sync session.
    func checkPracticeDevice(afterAppSwitch: Bool = false) async throws -> SpotifyAPI.Device {
        guard let service else { throw PlayError.notConnected }
        let epoch = commandEpoch
        do {
            let command = try await acquire(epoch)
            defer { release(command) }
            return try await discoverPhone(service: service, epoch: epoch, afterAppSwitch: afterAppSwitch)
        } catch {
            try checkCommand(epoch)
            let error = playbackError(error)
            setControlError(error)
            throw error
        }
    }

    private func checkCommand(_ epoch: Int) throws {
        try Task.checkCancellation()
        guard epoch == commandEpoch else { throw CancellationError() }
    }

    /// One network mutation at a time, including its confirmation. Polls
    /// issued before it are invalidated before any command leaves the app.
    private func acquire(_ epoch: Int) async throws -> UUID {
        while activeCommand != nil {
            try checkCommand(epoch)
            try await Task.sleep(for: .milliseconds(10))
        }
        try checkCommand(epoch)
        if let retryUntil, retryUntil > now() {
            throw PlayError.rateLimited(Int(ceil(now().duration(to: retryUntil).seconds)))
        }
        let id = UUID()
        activeCommand = id
        isControlling = true
        setControlError(nil)
        pausePolling()
        return id
    }

    private func release(_ id: UUID) {
        guard activeCommand == id else { return }
        activeCommand = nil
        isControlling = false
        startPolling()
    }

    private func setControlError(_ error: PlayError?) {
        controlRevision += 1
        controlError = error
        controlMessage = error?.localizedDescription
    }

    /// Follow the song already started by an app switch without issuing a
    /// second play/seek or claiming that native authorization has completed.
    /// Recovery owns the app-switch and authorization-state checks.
    func followPlayingTrackAfterHandoff(trackID: String, resumingAt seconds: Double,
                                       expectedControlRevision: Int) async -> Bool {
        guard let service, !needsReauth, activeCommand == nil, !followingHandoff,
              controlRevision == expectedControlRevision,
              controlError == nil || controlError?.canWakeApp == true else { return false }
        if let retryUntil, retryUntil > now() { return false }
        if let handoffReadBlockedUntil, handoffReadBlockedUntil > now() { return false }
        followingHandoff = true
        pausePolling()
        let epoch = commandEpoch
        let revision = expectedControlRevision
        let pollingGeneration = generation
        defer { followingHandoff = false; startPolling() }
        do {
            let sent = now()
            let current = try await service.current()
            let received = now()
            try checkCommand(epoch)
            guard !needsReauth, activeCommand == nil, controlRevision == revision,
                  generation == pollingGeneration, sent.duration(to: received).seconds <= 5,
                  Self.canFollowAfterHandoff(current, trackID: trackID, resumingAt: seconds) else { return false }
            apply(current, sent: sent, received: received)
            if controlError?.canWakeApp == true { setControlError(nil) }
            running = true
            return true
        } catch {
            // A read cannot repair authorization. Keep the ordinary reauth
            // indication; transient read failures leave recovery in charge.
            if !Task.isCancelled, epoch == commandEpoch, controlRevision == revision,
               generation == pollingGeneration {
                let failure = error as NSError
                switch failure.code {
                case 401:
                    needsReauth = true
                    pausePolling()
                case 403:
                    connectionMessage = "Spotify refused playback access. Reconnect Spotify in Profile if this continues."
                    handoffReadBlockedUntil = now().advanced(by: .seconds(30))
                case 429:
                    let delay = max(1, failure.userInfo["retryAfter"] as? Double ?? 5)
                    retryUntil = now().advanced(by: .seconds(delay))
                    connectionMessage = "Spotify is limiting requests. Live follow will reconnect automatically."
                default: break
                }
            }
            return false
        }
    }

    static func canFollowAfterHandoff(_ current: SpotifyAPI.CurrentlyPlaying?, trackID: String,
                                     resumingAt seconds: Double) -> Bool {
        guard seconds.isFinite, seconds >= 0, !trackID.isEmpty,
              let current, current.item?.id == trackID, current.isPlaying,
              let progress = current.progressMs, progress >= 0,
              seconds <= Double(progress) / 1000 + 1,
              current.device?.isActive != false, current.device?.isRestricted != true else { return false }
        // Unknown Connect clients may still supply valid read-only playback.
        // Explicitly identified other devices cannot finish a phone handoff.
        let otherDevices: Set<String> = ["computer", "tablet", "tv", "stb", "avr", "speaker",
            "audio_dongle", "audiodongle", "game_console", "gameconsole", "cast_video", "castvideo",
            "cast_audio", "castaudio", "automobile", "car"]
        let type = current.device?.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return !otherDevices.contains(type)
    }

    private func playbackError(_ error: Error) -> PlayError {
        if let error = error as? PlayError { return error }
        let failure = error as NSError
        switch failure.code {
        case 401:
            needsReauth = true
            pausePolling()
            return .notConnected
        case 403:
            if failure.userInfo["reason"] as? String == "PREMIUM_REQUIRED" { return .premiumRequired }
            return .forbidden
        case 404: return .noDevice
        case 429:
            let delay = max(1, failure.userInfo["retryAfter"] as? Double ?? 5)
            retryUntil = now().advanced(by: .seconds(delay))
            return .rateLimited(Int(ceil(delay)))
        default:
            if failure.domain == NSURLErrorDomain { return .connectionLost }
            return .failed(failure.code)
        }
    }

    private func mayHaveReachedSpotify(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSURLErrorDomain &&
            [URLError.timedOut.rawValue, URLError.networkConnectionLost.rawValue].contains(error.code)
    }

    /// A successful PUT only accepts the command; it doesn't prove playback
    /// moved. Read Spotify directly (without a competing poll) until the
    /// requested song/device/position is reported. Account for time spent
    /// waiting: a song can already be several seconds past the start point.
    private func confirm(service: Service, trackID: String, target: Double, device: String?,
                         requirePlaying: Bool, issued: ContinuousClock.Instant, epoch: Int,
                         intent: Int? = nil) async throws {
        let deadline = now().advanced(by: .seconds(12))
        for attempt in 0..<16 {
            try checkCommand(epoch)
            if let intent, intent != seekIntent { return }
            let sent = now()
            guard sent <= deadline else { break }
            do {
                let current: SpotifyAPI.CurrentlyPlaying?
                if let read = service.currentOnDevice { current = try await read(device) }
                else { current = try await service.current() }
                let received = now()
                try checkCommand(epoch)
                if let intent, intent != seekIntent { return }
                let elapsed = max(0, issued.duration(to: received).seconds)
                if let current, current.item?.id == trackID,
                   !requirePlaying || current.isPlaying,
                   device == nil || current.device?.id == device,
                   let ms = current.progressMs {
                    let reported = Double(ms) / 1000
                    let upper = target + (current.isPlaying ? elapsed : 0) + 2
                    if reported >= max(0, target - 1), reported <= upper {
                        apply(current, sent: sent, received: received)
                        return
                    }
                }
            } catch {
                try checkCommand(epoch)
                let code = (error as NSError).code
                // A read can safely be retried; replaying play/seek cannot.
                if code == 401 || code == 403 || code == 429 { throw error }
            }
            if attempt < 15 { try await service.sleep(attempt < 4 ? 0.5 : 1) }
        }
        throw PlayError.notConfirmed
    }

    /// Casual playing shares Spotify's confirmed transport, without a practice
    /// session. Keep an already playing song intact and resume a paused one.
    func playAlong(trackID: String, resumingAt seconds: Double? = nil) async throws {
        try await performPlay(trackID: trackID, at: seconds, preservePlaying: true)
    }

    func play(trackID: String, at seconds: Double) async throws {
        try await performPlay(trackID: trackID, at: seconds, preservePlaying: false)
    }

    private func performPlay(trackID: String, at seconds: Double?, preservePlaying: Bool) async throws {
        guard let service else { throw PlayError.notConnected }
        if let seconds, !seconds.isFinite || seconds >= Double(Int.max / 1000) { throw PlayError.invalidPosition }
        guard !trackID.isEmpty else { throw PlayError.invalidPosition }
        seekIntent += 1
        let epoch = commandEpoch
        do {
            let command = try await acquire(epoch)
            defer { release(command) }
            var target = max(0, seconds ?? 0)
            playbackDevice = nil
            let device = try await discoverPhone(service: service, epoch: epoch)
            try checkCommand(epoch)
            playbackDevice = device.displayName
            if preservePlaying {
                // The SDK can start audio while this app is backgrounded.
                // Cached state cannot decide whether to restart its queue.
                let sent = now()
                let current: SpotifyAPI.CurrentlyPlaying?
                if let read = service.currentOnDevice { current = try await read(device.id) }
                else { current = try await service.current() }
                try checkCommand(epoch)
                if let current, current.item?.id == trackID, current.device?.id == device.id {
                    let reported = current.progressMs.map { max(0, Double($0) / 1000) }
                    if current.isPlaying {
                        // Preserve audio already started in Spotify. Only a
                        // saved resume point ahead of it needs a seek.
                        if let reported, target > reported + 1 {
                            let issued = now()
                            do {
                                if let seek = service.seekOnDevice { try await seek(target, device.id) }
                                else { try await service.seek(target) }
                            } catch { if !mayHaveReachedSpotify(error) { throw error } }
                            try checkCommand(epoch)
                            try await confirm(service: service, trackID: trackID, target: target, device: device.id,
                                              requirePlaying: true, issued: issued, epoch: epoch)
                        } else if target == 0 || reported != nil {
                            apply(current, sent: sent, received: now())
                        } else { throw PlayError.notConfirmed }
                        running = true
                        return
                    }
                    target = max(0, seconds ?? reported ?? 0)
                }
            }
            let issued = now() // Device discovery is not playback time.
            do { try await service.play(trackID, target, device.id) }
            catch { if !mayHaveReachedSpotify(error) { throw error } }
            try checkCommand(epoch)
            try await confirm(service: service, trackID: trackID, target: target, device: device.id,
                              requirePlaying: true, issued: issued, epoch: epoch)
            running = true
        } catch {
            try checkCommand(epoch)
            let error = playbackError(error)
            setControlError(error)
            throw error
        }
    }

    /// Rapid taps keep only the newest pending destination. The in-flight
    /// HTTP request finishes before the next one starts, so Spotify cannot
    /// execute our requests out of order. Superseded seeks are handled by
    /// the newer request and don't flash a spurious failure in their caller.
    func seek(to seconds: Double) async -> Bool {
        guard let service, let trackID = playing?.track.id, seconds.isFinite,
              seconds < Double(Int.max / 1000) else { return false }
        seekIntent += 1
        let intent = seekIntent
        let epoch = commandEpoch
        do {
            let command = try await acquire(epoch)
            defer { release(command) }
            if intent != seekIntent { return true }
            guard playing?.track.id == trackID else { throw PlayError.notConfirmed }
            guard !deviceRestricted else { throw PlayError.restrictedDevice }
            // Seeking at duration advances to another track in Spotify.
            let end = playing?.track.durationMs.map { max(0, Double($0) / 1000 - 0.001) } ?? seconds
            let target = max(0, min(seconds, end))
            let device = deviceID
            let issued = now()
            do {
                if let seekOnDevice = service.seekOnDevice { try await seekOnDevice(target, device) }
                else { try await service.seek(target) }
            } catch { if !mayHaveReachedSpotify(error) { throw error } }
            try checkCommand(epoch)
            if intent != seekIntent { return true }
            try await confirm(service: service, trackID: trackID, target: target, device: device,
                              requirePlaying: false, issued: issued, epoch: epoch, intent: intent)
            return true
        } catch {
            if Task.isCancelled || epoch != commandEpoch || intent != seekIntent { return false }
            setControlError(playbackError(error))
            return false
        }
    }

}

extension Duration {
    var seconds: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// Recovery is a read-only handoff: returning from Spotify checks availability,
/// then asks the user to retry. It never starts a recording on foregrounding.
@MainActor
final class SpotifyDeviceRecovery: ObservableObject {
    enum State: Equatable {
        case idle, waitingForSpotify, awaitingAuthorization, checking, ready(String), followingPlayback, failed(String)
    }
    @Published private(set) var state: State = .idle
    private let checkDevice: () async throws -> SpotifyAPI.Device
    private let sleep: (Double) async throws -> Void
    private var generation = 0
    private var leftApp = false
    private var appActive = true
    private var expectsAuthorization = false
    private var authorized = false
    private var checkingGeneration: Int?
    private var followingRun: UUID?

    var authorizationWaitID: Int? { state == .awaitingAuthorization ? generation : nil }

    init(checkDevice: @escaping () async throws -> SpotifyAPI.Device,
         sleep: @escaping (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.checkDevice = checkDevice
        self.sleep = sleep
    }

    /// A casual play-along may already be working through read-only Spotify
    /// state before native authorization returns. It never retries playback
    /// or enters the practice/sync ready state on that evidence alone.
    func followPlayingTrack(check: @escaping () async -> Bool) async {
        guard state == .awaitingAuthorization, appActive, leftApp else { return }
        let token = generation
        guard followingRun == nil else { return }
        let run = UUID()
        followingRun = run
        defer { if followingRun == run { followingRun = nil } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        for attempt in 0..<24 {
            guard !Task.isCancelled, generation == token, followingRun == run, state == .awaitingAuthorization,
                  appActive, ContinuousClock.now < deadline else { return }
            let playing = await check()
            guard !Task.isCancelled, generation == token, followingRun == run, state == .awaitingAuthorization,
                  appActive, ContinuousClock.now < deadline else { return }
            if playing {
                generation += 1
                state = .followingPlayback
                return
            }
            if attempt < 23 {
                do { try await sleep(0.5) } catch { return }
            }
        }
    }

    @discardableResult func openRequested(expectsAuthorization: Bool = false) -> Int {
        generation += 1
        followingRun = nil
        leftApp = false
        self.expectsAuthorization = expectsAuthorization
        authorized = false
        state = .waitingForSpotify
        return generation
    }
    func openCompleted(_ opened: Bool, attempt: Int) {
        guard attempt == generation, state == .waitingForSpotify || state == .awaitingAuthorization else { return }
        if !opened { state = .failed("Spotify could not open. Install the Spotify app on this phone and sign in to the same account as Chordlyze.") }
    }
    func authorizationCompleted(error: String?, attempt: Int) {
        guard attempt == generation, state == .waitingForSpotify || state == .awaitingAuthorization else { return }
        if let error { state = .failed(error); return }
        authorized = true
        if appActive { retry() }
    }
    /// Returning manually without an SDK callback must not leave a spinner
    /// forever or automatically resume an authorization the user dismissed.
    func authorizationTimedOut(attempt: Int) {
        guard generation == attempt, state == .awaitingAuthorization else { return }
        state = .failed("Spotify connection wasn’t completed. Open Spotify again to connect, or check the connection if you already started the song there.")
    }
    func sceneChanged(active: Bool) {
        appActive = active
        if !active {
            followingRun = nil
            if state == .waitingForSpotify { leftApp = true }
            if state == .checking { cancel() }
        } else if state == .waitingForSpotify, leftApp {
            if expectsAuthorization && !authorized { state = .awaitingAuthorization }
            else { retry() }
        }
    }
    func retry() {
        generation += 1
        leftApp = false
        state = .checking
    }
    func check() async {
        guard state == .checking else { return }
        let token = generation
        guard checkingGeneration != token else { return }
        checkingGeneration = token
        defer { if checkingGeneration == token { checkingGeneration = nil } }
        do {
            let device = try await checkDevice()
            guard !Task.isCancelled, generation == token else { return }
            state = .ready(device.displayName)
        } catch {
            guard !Task.isCancelled, generation == token else { return }
            state = .failed(error.localizedDescription)
        }
    }
    func cancel() {
        generation += 1
        followingRun = nil
        leftApp = false
        state = .idle
    }
}
