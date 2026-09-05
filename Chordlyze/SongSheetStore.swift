import Combine
import Foundation

/// One observable song document shared by search, library, live and practice.
/// Lyrics load independently of analysis; complete charts replace pending rows.
@MainActor
final class SongSheetStore: ObservableObject {
    struct Service {
        var request: (SongDescriptor, Bool) async throws -> SongStatus = { try await BackendClient.requestSong($0, retry: $1) }
        var status: (String) async throws -> SongStatus = { try await BackendClient.songStatus(trackID: $0) }
        var lyrics: (SongDescriptor) async throws -> BackendClient.LyricsResult? = {
            try await BackendClient.lyrics(title: $0.title, artist: $0.artist, duration: $0.duration, album: $0.album)
        }
        var sleep: (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    }
    private static var documents: [String: SongSheetStore] = [:]
    static func shared(for song: SongDescriptor) -> SongSheetStore {
        if let existing = documents[song.id] { return existing }
        if documents.count >= 16, let unused = documents.first(where: { $0.value.observers == 0 }) {
            documents.removeValue(forKey: unused.key)
        }
        let document = SongSheetStore(song: song)
        documents[song.id] = document
        return document
    }

    @Published private(set) var song: SongDescriptor
    @Published private(set) var analysis: ChordAnalysis?
    @Published private(set) var rows: [SheetModel.Row] = []
    @Published private(set) var state = "loading"
    @Published private(set) var message = "Checking this song…"
    @Published private(set) var lyricsNote: String?
    /// Lyric lines without timing: shown as text, never as timed rows.
    @Published private(set) var untimedLyrics: [String] = []
    @Published private(set) var lyricsLoading = true
    @Published private(set) var lyricsFailed = false
    private(set) var lyricsResult: BackendClient.LyricsResult?
    private var service: Service
    private var observers = 0
    private var task: Task<Void, Never>?
    private var lyricTask: Task<Void, Never>?
    private var revision = 0
    private var lyricRevision = 0
    private var lyricKey: String?
    private var libraryGeneration: String?
    private var lines: [LyricLine] = []
    private var nextLyricRetry: ContinuousClock.Instant?

    init(song: SongDescriptor, analysis: ChordAnalysis? = nil, service: Service = Service()) {
        self.song = song
        self.analysis = analysis
        self.service = service
        rebuild()
    }

    var busy: Bool { ["loading", "queued", "processing"].contains(state) }
    var canPractice: Bool { analysis != nil && state == "ready" }

    /// SwiftUI owns this subscription through .task. Last departure cancels
    /// networking; reentry starts a new generation, including canceled lyrics.
    func observe() async {
        observers += 1
        if task == nil { start() }
        defer {
            observers -= 1
            if observers == 0 {
                revision += 1
                lyricRevision += 1
                task?.cancel(); task = nil
                lyricTask?.cancel(); lyricTask = nil
            }
        }
        do {
            while !Task.isCancelled { try await Task.sleep(for: .seconds(3600)) }
        } catch {}
    }

    func retry() {
        start(retry: true)
        loadLyrics(force: true)
    }

    private func start(retry: Bool = false) {
        revision += 1
        let token = revision
        task?.cancel()
        loadLyrics(force: lyricsLoading || lyricsFailed)
        task = Task { [weak self] in
            guard let self else { return }
            var first = true
            var failures = 0
            while !Task.isCancelled && token == revision {
                do {
                    let result = try await (first ? service.request(song, retry) : service.status(song.id))
                    try Task.checkCancellation()
                    guard token == revision else { return }
                    first = false
                    failures = 0
                    apply(result)
                } catch {
                    guard !Task.isCancelled, token == revision else { return }
                    if let error = error as? BackendError, (400..<500).contains(error.status), error.status != 429 {
                        state = "unavailable"
                        message = song.duration.map { $0 > 1200 } == true
                            ? "Full-song analysis supports recordings up to 20 minutes."
                            : "This song could not be requested. Tap Retry to try again."
                        return
                    }
                    failures += 1
                    state = "connection"
                    message = "Reconnecting…"
                }
                do { try await service.sleep(failures > 0 ? min(30, Double(failures * 3)) : (state == "ready" ? 15 : 3)) }
                catch { return }
            }
        }
    }

    private func apply(_ status: SongStatus) {
        let oldSong = song
        let reset = libraryGeneration != nil && libraryGeneration != status.libraryGeneration
        if let previous = libraryGeneration, previous != status.libraryGeneration {
            lines = []
            untimedLyrics = []
            lyricsResult = nil
            lyricKey = nil
        }
        libraryGeneration = status.libraryGeneration
        if let metadata = status.song {
            if let title = metadata.title, !title.isEmpty { song.title = title }
            if let artist = metadata.artist, !artist.isEmpty { song.artist = artist }
            song.album = metadata.album ?? song.album
            song.duration = metadata.duration ?? song.duration
        }
        let changed = analysis != status.analysis
        analysis = status.analysis
        if let aligned = status.lyrics, aligned.synced, aligned != lyricsResult {
            // Lyrics timed to the analyzed recording beat any catalog lookup.
            lyricRevision += 1
            lyricTask?.cancel(); lyricTask = nil
            lyricKey = lyricLookupKey
            lyricsResult = aligned
            lines = aligned.lines
            untimedLyrics = []
            lyricsLoading = false
            lyricsFailed = false
            lyricsNote = "Lyrics timed from the recording"
        }
        state = status.job.state
        // Three states the user sees: not analyzed, analyzing, ready.
        switch state {
        case "ready": message = ""
        case "processing", "queued":
            let ahead = state == "queued" ? status.job.ahead ?? 0 : 0
            message = !status.job.workerOnline ? "Analyzing, waiting for the service"
                : ahead > 0 ? "Analyzing, \(ahead) ahead" : "Analyzing, about a minute"
        case "missing": message = "Not analyzed"
        default: message = status.job.message ?? "Analysis unavailable"
        }
        if changed || reset || oldSong != song || rows.isEmpty || status.lyrics != nil { rebuild() }
        loadLyrics(force: lyricsFailed && (nextLyricRetry.map { ContinuousClock.now >= $0 } ?? true))
    }

    private var lyricLookupKey: String { "\(song.title)|\(song.artist)|\(song.album ?? "")|\(song.duration ?? 0)" }
    private var hasAlignedLyrics: Bool { lyricsResult?.matched == "aligned" }

    private func loadLyrics(force: Bool = false) {
        let key = lyricLookupKey
        guard !hasAlignedLyrics, force || key != lyricKey else { return }
        lyricKey = key
        lyricRevision += 1
        let token = lyricRevision
        lyricTask?.cancel()
        lyricsLoading = true
        lyricsFailed = false
        let descriptor = song
        lyricTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await service.lyrics(descriptor)
                try Task.checkCancellation()
                guard token == lyricRevision else { return }
                lyricsResult = result
                if let result, !result.synced {
                    // Guessed line times must never drive the runner or place chords.
                    lines = []
                    untimedLyrics = result.lines.map(\.text).filter { !$0.isEmpty }
                    lyricsNote = "Lyrics have no timing; words listed below"
                } else {
                    lines = result?.lines ?? []
                    untimedLyrics = []
                    lyricsNote = result?.instrumental == true ? "Instrumental recording" : result?.betaNote
                    if result == nil { lyricsNote = "No lyrics for this recording" }
                    if result?.synced == true, result?.lines.contains(where: { !$0.text.isEmpty && $0.words == nil }) == true {
                        lyricsNote = "Approximate lyric timing"
                    }
                }
                lyricsLoading = false
                rebuild()
            } catch {
                guard !Task.isCancelled, token == lyricRevision else { return }
                lyricsLoading = false
                lyricsFailed = true
                nextLyricRetry = ContinuousClock.now.advanced(by: .seconds(10))
                lyricsNote = "Lyrics connection interrupted. Retrying automatically…"
                rebuild()
            }
        }
    }

    private func rebuild() {
        rows = SheetModel.build(analysis: analysis, lines: lines,
                                duration: song.duration ?? analysis?.songDuration,
                                untimedLyrics: !untimedLyrics.isEmpty)
    }
}

extension SongDescriptor {
    init(track: Track) {
        self.init(trackID: track.id, title: track.name, artist: track.artistNames,
                  album: track.album.name, duration: track.durationMs.map { Double($0) / 1000 },
                  isrc: track.isrc, artwork: track.album.artworkURL?.absoluteString)
    }
}
