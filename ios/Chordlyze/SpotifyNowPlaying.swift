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
    @Published private(set) var analysis: ChordAnalysis?
    /// Analysis was attempted for the current track and nothing came back.
    @Published private(set) var analysisFailed = false
    /// Token lacks the playback scope (or Spotify refused) — reconnect in Profile.
    @Published private(set) var needsReauth = false

    private var anchor: (offset: TimeInterval, at: Date)?
    private var pollTask: Task<Void, Never>?
    private var analysisKey: String?
    private var api: SpotifyAPI?

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

    /// Current playback position; frozen while paused.
    func livePosition() -> TimeInterval? {
        guard let anchor else { return nil }
        guard playing?.isPlaying == true else { return anchor.offset }
        return anchor.offset + Date().timeIntervalSince(anchor.at)
    }

    private func poll() async {
        guard let api else { return }
        do {
            let current = try await api.currentlyPlaying()
            guard let current, let track = current.item else {
                playing = nil
                anchor = nil
                return
            }
            anchor = (Double(current.progressMs ?? 0) / 1000, Date())
            playing = Playing(track: track, isPlaying: current.isPlaying)
            await analyzeIfNeeded(track)
        } catch let error as NSError where error.code == 401 || error.code == 403 {
            // Missing scope on an old login (or dev-mode block): stop hammering.
            needsReauth = true
            stop()
        } catch {
            // Transient network error — keep the last known state.
        }
    }

    /// Jump the account's playback to `seconds`. False when Spotify refuses
    /// (free account, or token missing the playback scope).
    func seek(to seconds: Double) async -> Bool {
        guard let api else { return false }
        do {
            try await api.seek(toMs: Int(seconds * 1000))
            anchor = (seconds, Date())  // optimistic; next poll confirms
            return true
        } catch {
            return false
        }
    }

    private func analyzeIfNeeded(_ track: Track) async {
        guard analysisKey != track.id else { return }
        analysisKey = track.id
        analysis = nil
        analysisFailed = false
        var result = await BackendClient.cachedAnalysis(trackID: track.id, isrc: track.isrc)
        if result == nil {
            result = await BackendClient.analyzeTrack(trackID: track.id, isrc: track.isrc,
                                                      title: track.name, artist: track.artistNames)
        }
        guard analysisKey == track.id else { return }  // song changed meanwhile
        analysis = result
        analysisFailed = result == nil
    }
}
