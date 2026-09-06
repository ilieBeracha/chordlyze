import Combine
import Foundation

/// One observable song document shared by search, library, live and practice.
/// Lyrics load independently of analysis; complete charts replace pending rows.
/// Opening a song only reads its status: analysis is requested by the
/// Analyze button alone, never by a screen appearing or a song playing.
@MainActor
final class SongSheetStore: ObservableObject {
    struct Service {
        var request: (SongDescriptor) async throws -> SongStatus = { try await BackendClient.requestSong($0, retry: true) }
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
    @Published private(set) var lyricsLoading = true
    @Published private(set) var lyricsFailed = false
    /// Chord display shared by every surface, so the sheet, Live and Practice
    /// name the same chords: capo mode favors open shapes, manual shift transposes.
    @Published var capoMode = false
    @Published var manualShift = 0
    /// Seconds added to Spotify's position before reading the chart, for a
    /// chart whose recording starts earlier or later than the Spotify track.
    @Published var timingOffset = 0.0
    @Published private(set) var capo = 0
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
    var shift: Int { (capoMode ? -capo : 0) + manualShift }
    /// "Capo 2", "+1", "Capo 2 +1", or nil when chords show as analyzed.
    var chordNote: String? {
        let parts = [capoMode && capo > 0 ? "Capo \(capo)" : nil,
                     manualShift != 0 ? String(format: "%+d", manualShift) : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
    /// Seconds the analyzed recording is longer (+) or shorter (−) than the
    /// Spotify track. nil when either length is unknown or they agree within
    /// a second. A different edition shifts every chord against Spotify audio.
    var editionGap: Double? {
        guard let analyzed = analysis?.audioDuration, let track = song.duration else { return nil }
        let gap = analyzed - track
        return abs(gap) > 1 ? gap : nil
    }
    var editionNote: String? {
        editionGap.map { String(format: "Chart made from a recording %.0f s %@ than the Spotify track. Chords may sit early or late; adjust timing in Key & capo.", abs($0), $0 > 0 ? "longer" : "shorter") }
    }
    /// Label of the one action that requests analysis; nil while nothing can be requested.
    var actionTitle: String? {
        busy || state == "ready" ? nil : (state == "missing" ? "Analyze" : "Retry")
    }

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

    /// Analyze / Retry button: the only path that requests analysis. After a
    /// connection loss it reconnects without requesting anything.
    func retry() {
        start(request: state != "connection")
        loadLyrics(force: true)
    }

    /// Pull to refresh: re-read status and lyrics, never request analysis.
    func refresh() {
        start()
        loadLyrics(force: true)
    }

    private func start(request: Bool = false) {
        revision += 1
        let token = revision
        task?.cancel()
        loadLyrics(force: lyricsLoading || lyricsFailed)
        task = Task { [weak self] in
            guard let self else { return }
            var first = request
            var failures = 0
            while !Task.isCancelled && token == revision {
                do {
                    let result = try await (first ? service.request(song) : service.status(song.id))
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
                do { try await service.sleep(failures > 0 ? min(30, Double(failures * 3)) : (state == "ready" || state == "missing" ? 15 : 3)) }
                catch { return }
            }
        }
    }

    private func apply(_ status: SongStatus) {
        let oldSong = song
        let reset = libraryGeneration != nil && libraryGeneration != status.libraryGeneration
        if let previous = libraryGeneration, previous != status.libraryGeneration {
            lines = []
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
            lyricsLoading = false
            lyricsFailed = false
            lyricsNote = aligned.matched == "transcribed" ? "Transcribed from the recording" : "Lyrics timed from the recording"
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
                lines = result?.lines ?? []
                if let result, !result.synced {
                    // Catalog lines with estimated times: chords still sit above the
                    // words. The worker replaces them with recording-timed lines.
                    lyricsNote = "Estimated lyric timing"
                } else {
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
                                duration: song.duration ?? analysis?.songDuration)
        capo = ChordMath.autoCapo(names: analysis?.chords.filter { $0.label != "N" }
            .map { ($0.displayName, $0.duration) } ?? [])
    }
}

extension SongDescriptor {
    init(track: Track) {
        self.init(trackID: track.id, title: track.name, artist: track.artistNames,
                  album: track.album.name, duration: track.durationMs.map { Double($0) / 1000 },
                  isrc: track.isrc, artwork: track.album.artworkURL?.absoluteString)
    }
}
