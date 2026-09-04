import Foundation

/// Polls Spotify for what the account is playing right now — no mic needed.
/// Fetches (or triggers) the chord analysis for each track as it starts.
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

    @Published private(set) var playing: Playing?
    /// Analysis of `playing`'s track; nil while it is being fetched. Never
    /// an older track's: it is cleared the moment the track changes.
    @Published private(set) var analysis: ChordAnalysis?
    /// Analysis was attempted for the current track and nothing came back.
    @Published private(set) var analysisFailed = false
    /// Token lacks the playback scope (or Spotify refused) — reconnect in Profile.
    @Published private(set) var needsReauth = false

    /// Playback position `offset` was true at monotonic instant `at`.
    /// (Spotify's own `timestamp` field is when its state last changed, not
    /// when `progress_ms` was sampled, so it is not used for timing.)
    private var anchor: (offset: TimeInterval, at: ContinuousClock.Instant)?
    private var pollTask: Task<Void, Never>?
    /// Track id the analysis (or the fetch in flight) belongs to.
    private var analysisKey: String?
    private var analysisTask: Task<Void, Never>?
    private var api: SpotifyAPI?
    /// A fresh report within this much of the running prediction is poll
    /// jitter, not new information: keep the anchor so the display doesn't hop.
    private static let jitterTolerance: TimeInterval = 0.4

    /// Begin (or resume) polling. Safe to call repeatedly.
    func start(api: SpotifyAPI) {
        self.api = api
        guard pollTask == nil else { return }
        needsReauth = false
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                if self?.pollTask == nil { break }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Stop and forget everything (sign-out).
    func reset() {
        stop()
        analysisTask?.cancel()
        analysisTask = nil
        analysisKey = nil
        playing = nil
        anchor = nil
        analysis = nil
        analysisFailed = false
        needsReauth = false
    }

    /// Current playback position; frozen while paused; nil when Spotify has
    /// not reported one.
    func livePosition() -> TimeInterval? {
        position(at: .now)
    }

    private func position(at instant: ContinuousClock.Instant) -> TimeInterval? {
        guard let anchor else { return nil }
        guard playing?.isPlaying == true else { return anchor.offset }
        return anchor.offset + anchor.at.duration(to: instant).seconds
    }

    private func poll() async {
        guard let api else { return }
        do {
            let sent = ContinuousClock.now
            let current = try await api.currentlyPlaying()
            let received = ContinuousClock.now
            guard let current, let track = current.item else {
                playing = nil
                anchor = nil
                return
            }
            // progress_ms was read somewhere inside the round trip; the midpoint
            // is the best guess and halves the latency error.
            let sampledAt = sent.advanced(by: sent.duration(to: received) / 2)
            let next = Playing(track: track, isPlaying: current.isPlaying)
            if let ms = current.progressMs {
                let reported = Double(ms) / 1000
                let predicted = playing == next ? position(at: sampledAt) : nil
                if let predicted, abs(predicted - reported) < Self.jitterTolerance {
                    // Same track, same state, agrees with the running clock: keep it.
                } else {
                    anchor = (reported, sampledAt)
                }
            } else {
                anchor = nil
            }
            playing = next
            fetchAnalysisIfNeeded(track)
        } catch let error as NSError where error.code == 401 || error.code == 403 {
            // Missing scope on an old login (or dev-mode block): stop hammering.
            needsReauth = true
            stop()
        } catch {
            // Transient network error or rate limit — keep the last known state.
        }
    }

    /// Jump the account's playback to `seconds`. False when Spotify refuses
    /// (free account, or token missing the playback scope).
    func seek(to seconds: Double) async -> Bool {
        guard let api else { return false }
        do {
            try await api.seek(toMs: Int(seconds * 1000))
            anchor = (seconds, .now)  // optimistic; next poll confirms
            return true
        } catch {
            return false
        }
    }

    /// One fetch per track, in its own task: the poll loop never waits on
    /// it, so a song change is noticed while the previous song is still
    /// being analyzed, and that stale result is dropped when it arrives.
    private func fetchAnalysisIfNeeded(_ track: Track) {
        guard analysisKey != track.id else { return }
        analysisKey = track.id
        analysisTask?.cancel()
        analysis = nil
        analysisFailed = false
        analysisTask = Task { [weak self] in
            let result = try? await BackendClient.retrying { try await BackendClient.analyzeTrack(track) }
            guard let self, !Task.isCancelled, self.analysisKey == track.id else { return }
            self.analysis = result
            self.analysisFailed = result == nil
        }
    }
}

extension Duration {
    var seconds: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
