import Combine
import Foundation

/// One observable song document shared by search, library, live and practice.
/// Lyrics load independently of analysis; complete charts replace pending rows.
/// Opening a song only reads its status: analysis is requested by the
/// Analyze and Reanalyze buttons alone, never by a screen appearing or a song playing.
@MainActor
final class SongSheetStore: ObservableObject {
    struct Service {
        var request: (SongDescriptor) async throws -> SongStatus = { try await BackendClient.requestSong($0, retry: true) }
        var status: (String) async throws -> SongStatus = { try await BackendClient.songStatus(trackID: $0) }
        var requestLyricTiming: (String) async throws -> SongStatus = { try await BackendClient.requestLyricTiming(trackID: $0) }
        var lyrics: (SongDescriptor) async throws -> BackendClient.LyricsResult? = {
            try await BackendClient.lyrics(title: $0.title, artist: $0.artist, duration: $0.duration, album: $0.album)
        }
        var save: (String, Bool) async throws -> Void = { try await BackendClient.setSaved(trackID: $0, $1) }
        var saveTiming: (String, TimingMap?) async throws -> Void = { try await BackendClient.setTiming(trackID: $0, $1) }
        var sleep: (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
        var editBoundary: (String, BackendClient.BoundaryEdit) async throws -> SongStatus = { try await BackendClient.editBoundary(trackID: $0, edit: $1) }
        var synchronize: (String, [BackendClient.SyncClip], String, String) async throws -> SongStatus = {
            try await BackendClient.synchronize(trackID: $0, clips: $1, chartRevision: $2, timingRevision: $3)
        }
        var applyPassage: (String, PassageJob) async throws -> SongStatus = { try await BackendClient.applyPassage(trackID: $0, job: $1) }
        var correctChord: (String, ChordSegment, String?, String) async throws -> SongStatus = {
            try await BackendClient.correctChord(trackID: $0, segment: $1, name: $2, revision: $3)
        }
        var reanalyze: (String, String) async throws -> SongStatus = {
            try await BackendClient.reanalyzeSong(trackID: $0, expectedRevision: $1)
        }
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
    /// Validate timing once per document update, not on every playback frame.
    private(set) var beatGrid: BeatGrid?
    @Published private(set) var rows: [SheetModel.Row] = []
    @Published private(set) var state = "loading"
    @Published private(set) var message = "Checking this song…"
    @Published private(set) var lyricsNote: String?
    @Published private(set) var lyricsLoading = true
    @Published private(set) var lyricsFailed = false
    @Published private(set) var lyricsJob: SongStatus.Job?
    @Published private(set) var requestingLyricTiming = false
    @Published private(set) var lyricTimingError: String?
    @Published private(set) var analysisInfo: SongAnalysisInfo?
    @Published private(set) var analysisJob: SongStatus.Job?
    @Published private(set) var requestingReanalysis = false
    @Published private(set) var reanalysisError: String?
    @Published private(set) var hasTimedLyricWords = false
    @Published private(set) var hasCompleteLyricTiming = false
    /// In the account's library. Requesting analysis saves; the sheet's
    /// bookmark toggles it. The chart itself is shared by every account.
    @Published private(set) var saved = false
    @Published private(set) var saveError: String?
    @Published private(set) var savingCorrection = false
    /// Chord display shared by every surface, so the sheet, Live and Practice
    /// name the same chords: capo mode favors open shapes, manual shift transposes.
    @Published var capoMode = false
    @Published var manualShift = 0
    /// How this account's chart timeline maps onto the Spotify recording it
    /// hears. Identity until calibrated by ear; saved per account on the
    /// server, since it absorbs the listener's own output delay.
    @Published private(set) var timing: TimingMap = .identity
    @Published private(set) var timingError: String?
    @Published private(set) var timingIsStale = false
    private(set) var timingRevision: String?
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
    /// Lyrics attached to this recording's chart outrank catalog timing,
    /// whether the worker aligned existing words or transcribed new ones.
    private var hasRecordingLyrics = false
    private var nextLyricRetry: ContinuousClock.Instant?

    init(song: SongDescriptor, analysis: ChordAnalysis? = nil, service: Service = Service()) {
        self.song = song
        self.analysis = analysis
        self.service = service
        rebuild()
    }

    var busy: Bool { ["loading", "queued", "processing"].contains(state) }
    /// A status outage does not invalidate the full chart already in memory.
    /// Explicit missing/unavailable responses still disable its actions.
    var canPractice: Bool { analysis?.isPreview == false && (state == "ready" || state == "connection") }
    var reanalysisPending: Bool {
        requestingReanalysis || ["queued", "processing"].contains(analysisJob?.state ?? "") || timingLyrics
    }
    private var reanalysisRevision: String? { analysisInfo?.chartRevision ?? analysis?.chartRevision }
    var canReanalyze: Bool {
        analysisInfo != nil && reanalysisRevision != nil && !reanalysisPending && !savingCorrection
            && state != "loading" && state != "connection"
    }
    var analysisProgressLabel: String {
        if requestingReanalysis { return "Requesting reanalysis…" }
        let job = analysisJob ?? (timingLyrics ? lyricsJob : nil)
        switch job?.state {
        case "queued": return job?.workerOnline == false ? "Waiting for service" : "Queued"
        case "processing":
            if job?.workerOnline == false { return "Waiting for service" }
            switch job?.stage {
            case "downloading": return "Finding and downloading recording"
            case "aligning": return "Timing lyrics"
            default: return "Analyzing chords and rhythm"
            }
        case "failed", "unavailable": return "Reanalysis failed"
        default: return timingLyrics ? "Timing lyrics" : (reanalysisRevision == nil ? "Not analyzed" : "Ready")
        }
    }
    var analysisProgressMessage: String? {
        if let reanalysisError { return reanalysisError }
        if state == "connection" { return "Could not check the latest status. Showing the last information received." }
        if let job = analysisJob, ["failed", "unavailable"].contains(job.state) {
            return job.message ?? "The new analysis could not finish. Your existing chart is still available."
        }
        if reanalysisPending {
            if let ahead = analysisJob?.ahead, ahead > 0 { return "\(ahead) \(ahead == 1 ? "song" : "songs") ahead in the queue." }
            return "Your existing chart stays available while this runs."
        }
        return nil
    }
    var shift: Int { (capoMode ? -capo : 0) + manualShift }
    var lyricTimingIsSynced: Bool { lyricsResult?.synced == true }
    var needsChordPlaybackSummary: Bool { canPractice && usesIndependentLyrics }
    /// Plain catalog lyrics have no relationship to the chart clock. Keep
    /// their text visible while exposing chords on their own real timeline.
    var usesIndependentLyrics: Bool { !lyricTimingIsSynced && !lines.isEmpty }
    var untimedLyricRows: [SheetModel.Row] {
        rows.filter { !$0.text.isEmpty }.map {
            SheetModel.Row(start: $0.start, end: $0.end, kind: .lyric,
                           text: $0.text, words: nil, chords: [], held: nil)
        }
    }
    var independentChordTimeline: SheetModel.Row {
        let events = SheetModel.events(analysis)
        return SheetModel.Row(start: 0, end: analysis?.coverageEnd ?? 0,
            kind: .instrumental, text: "", words: nil,
            chords: events.map { SheetModel.Placed(event: $0, position: 0, wordIndex: nil) }, held: nil)
    }
    var timingLyrics: Bool { requestingLyricTiming || ["queued", "processing"].contains(lyricsJob?.state ?? "") }
    var needsLyricTiming: Bool {
        canPractice && !lyricsLoading && !lyricsFailed && lyricsResult?.instrumental != true && !hasCompleteLyricTiming
    }
    var lyricTimingMessage: String? {
        if let lyricTimingError { return lyricTimingError }
        if timingLyrics {
            return lyricsJob?.workerOnline == false ? "Lyrics are waiting to be synchronized." : "Synchronizing lyrics to the recording…"
        }
        if hasCompleteLyricTiming { return nil }
        if let job = lyricsJob, ["failed", "unavailable"].contains(job.state) {
            return job.message ?? "Lyric timing could not finish. Your chords are still available."
        }
        guard needsLyricTiming else { return nil }
        return hasTimedLyricWords ? "Some words still need timing." : "Lyrics aren't synchronized yet."
    }
    var lyricTimingActionTitle: String {
        ["failed", "unavailable"].contains(lyricsJob?.state ?? "") || lyricTimingError != nil ? "Retry" : "Sync lyrics"
    }

    /// Auto-follow only a measured sung word or a real instrumental row.
    /// Guessed lyric positions must not advance the page as if vocals began.
    func followingRow(at time: Double) -> SheetModel.Row? {
        guard !usesIndependentLyrics else { return nil }
        guard let row = SheetModel.activeRow(rows, at: time) else { return nil }
        if row.text.isEmpty { return row }
        guard lyricTimingIsSynced, let words = row.words,
              LyricPlayhead.currentWord(at: time, words: words, rowStart: row.start, rowEnd: row.end) != nil else { return nil }
        return row
    }

    /// Explicit recovery uses the existing chart; it never re-analyzes chords.
    func requestLyricTiming() async {
        guard canPractice, !reanalysisPending, !savingCorrection else { return }
        requestingLyricTiming = true
        lyricTimingError = nil
        revision += 1
        let token = revision
        task?.cancel(); task = nil
        defer { requestingLyricTiming = false; if observers > 0 { start() } }
        do {
            let result = try await service.requestLyricTiming(song.id)
            guard !Task.isCancelled, token == revision else { return }
            apply(result)
        } catch {
            guard !Task.isCancelled, token == revision else { return }
            lyricTimingError = "Could not request lyric timing. Try again."
        }
    }
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
        editionGap.map { String(format: "Chart made from a recording %.0f s %@ than the Spotify track. Chords may sit early or late; adjust timing in Song settings.", abs($0), $0 > 0 ? "longer" : "shorter") }
    }
    /// Label of the one action that requests analysis; nil while nothing can be requested.
    var actionTitle: String? {
        if state == "connection" { return "Reconnect" }
        return busy || state == "ready" ? nil : (state == "missing" ? "Analyze" : "Retry")
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

    /// A separate explicit action bypasses the normal current-chart cache hit.
    /// Polling is suspended while enqueueing so an older read cannot undo it.
    func reanalyze() async {
        guard canReanalyze, let expectedRevision = reanalysisRevision else { return }
        requestingReanalysis = true
        reanalysisError = nil
        revision += 1
        let token = revision
        task?.cancel(); task = nil
        defer {
            requestingReanalysis = false
            if observers > 0 { start() }
        }
        do {
            let result = try await service.reanalyze(song.id, expectedRevision)
            guard !Task.isCancelled, token == revision else { return }
            apply(result)
        } catch {
            guard !Task.isCancelled, token == revision else { return }
            if let error = error as? BackendError, error.status == 409 {
                reanalysisError = "The chart changed. Refresh its status before trying again."
            } else if let error = error as? BackendError, error.status == 404 {
                reanalysisError = "Reanalysis is not available on this service yet."
            } else {
                reanalysisError = "Could not confirm the request. Refresh the status before trying again."
            }
        }
    }

    /// A calibration stops applying when the chart it was made on is gone.
    var timingNote: String? {
        if timingIsStale { return "Timing belongs to an earlier chart. Synchronize again." }
        if timing.method == "automatic" {
            return timing.driftMeasured == true ? "Automatically synchronized, including drift." : "Automatically synchronized; offset measured."
        }
        if timing.isIdentity { return nil }
        if let error = timing.verifiedError { return String(format: "Calibrated by ear, checked within %.2f s.", error) }
        return "Adjusted by hand."
    }

    /// Saves a calibration (nil clears it) for this account on the server.
    func setTiming(_ map: TimingMap?) async {
        guard !savingCorrection else { timingError = "Another change is still saving."; return }
        let previous = timing
        let wasStale = timingIsStale
        savingCorrection = true
        revision += 1
        task?.cancel(); task = nil
        defer { savingCorrection = false; if observers > 0 { start() } }
        timingIsStale = false
        timing = map ?? .identity
        timingError = nil
        do { try await service.saveTiming(song.id, map) } catch {
            timing = previous
            timingIsStale = wasStale
            timingError = "Could not save the timing: \(error.localizedDescription)"
        }
    }

    /// Hand adjustment from Key & capo: shifts the offset, keeps the scale.
    func nudgeTiming(chordsEarlierBy delta: Double) async {
        var map = timing
        map.offset -= delta
        map.verifiedError = nil
        map.method = "manual"
        map.matchScore = nil; map.matchMargin = nil; map.driftMeasured = nil
        map.chartRevision = analysis?.chartRevision
        map.chartAudioSha256 = analysis?.audioSha256
        await setTiming(map.isIdentity ? nil : map)
    }

    /// Bookmark: keep or drop this song in the account's library.
    func setSaved(_ flag: Bool) async {
        let previous = saved
        saved = flag
        saveError = nil
        do { try await service.save(song.id, flag) } catch {
            saved = previous
            saveError = "Could not update your library: \(error.localizedDescription)"
        }
    }

    /// Pull to refresh: re-read status and lyrics, never request analysis.
    func refresh() {
        start()
        loadLyrics(force: true)
    }

    /// Commit one occurrence in the recording's original key. Never let an
    /// already-running status read undo the saved response, even if it ignores cancellation.
    func correctChord(_ segment: ChordSegment, name: String?, expectedRevision: String) async throws {
        guard !savingCorrection else { throw BackendError(status: 409, detail: "A chord is still saving.") }
        guard analysis?.chartRevision == expectedRevision else {
            throw BackendError(status: 409, detail: "The chart changed. Reopen the chord before saving again.")
        }
        try await commitChange { try await self.service.correctChord(self.song.id, segment, name, expectedRevision) }
    }

    func applyPassage(_ job: PassageJob) async throws {
        guard analysis?.chartRevision == job.chartRevision else {
            throw BackendError(status: 409, detail: "The chart changed. Reanalyze the passage before applying it.")
        }
        try await commitChange { try await self.service.applyPassage(self.song.id, job) }
    }

    func editBoundary(_ edit: BackendClient.BoundaryEdit) async throws {
        guard analysis?.chartRevision == edit.chartRevision else {
            throw BackendError(status: 409, detail: "The chart changed. Reopen the chord before editing.")
        }
        try await commitChange { try await self.service.editBoundary(self.song.id, edit) }
    }

    func synchronize(clips: [BackendClient.SyncClip], chartRevision: String, timingRevision: String) async throws {
        guard analysis?.chartRevision == chartRevision else {
            throw BackendError(status: 409, detail: "The chart changed while listening. Synchronize again.")
        }
        try await commitChange {
            let result = try await self.service.synchronize(self.song.id, clips, chartRevision, timingRevision)
            guard result.timing?.method == "automatic", result.timing?.chartRevision == chartRevision else {
                throw BackendError(status: 409, detail: "The service did not confirm synchronization. Reopen the song to check timing.")
            }
            return result
        }
    }

    private func commitChange(_ action: () async throws -> SongStatus) async throws {
        guard !savingCorrection, !requestingReanalysis else { throw BackendError(status: 409, detail: "Another change is still saving.") }
        savingCorrection = true
        revision += 1
        task?.cancel(); task = nil
        defer {
            savingCorrection = false
            if observers > 0 { start() }
        }
        let result = try await action()
        guard result.analysis?.chartRevision != nil else {
            throw BackendError(status: 409, detail: "The service did not confirm the change. Reopen the song to check it.")
        }
        apply(result)
    }

    private func start(request: Bool = false) {
        guard !savingCorrection, !request || !requestingReanalysis else { return }
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
                    message = canPractice ? "Reconnecting… Your loaded chart is still available." : "Reconnecting…"
                }
                do { try await service.sleep(failures > 0 ? min(30, Double(failures * 3)) : (reanalysisPending ? 3 : (state == "ready" || state == "missing" ? 15 : 3))) }
                catch { return }
            }
        }
    }

    private func apply(_ status: SongStatus) {
        let oldSong = song
        let reset = libraryGeneration != nil && libraryGeneration != status.libraryGeneration
        let recordingChanged = analysis?.audioSha256 != status.analysis?.audioSha256
            || (analysis?.audioSha256 == nil && analysis != status.analysis)
        if reset || (hasRecordingLyrics && recordingChanged) {
            lines = []
            lyricsResult = nil
            lyricKey = nil
            hasRecordingLyrics = false
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
        if let aligned = status.lyrics, aligned.synced, aligned != lyricsResult || !hasRecordingLyrics {
            // Lyrics timed to the analyzed recording beat any catalog lookup.
            lyricRevision += 1
            lyricTask?.cancel(); lyricTask = nil
            lyricKey = lyricLookupKey
            lyricsResult = aligned
            hasRecordingLyrics = true
            lines = aligned.lines
            lyricsLoading = false
            lyricsFailed = false
            let incompleteWords = aligned.lines.enumerated().contains { index, line in
                guard !line.text.isEmpty else { return false }
                let boundary = index + 1 < aligned.lines.count ? aligned.lines[index + 1].time :
                    analysis?.audioDuration ?? song.duration ?? max(line.time, line.words?.map(\.time).max() ?? line.time) + 1
                guard let words = SheetModel.completeWords(line, before: boundary) else { return true }
                return words.contains { $0.estimated == true }
            }
            lyricsNote = aligned.timingNote ?? (incompleteWords ? "Some lyric timing is approximate." :
                aligned.matched == "transcribed" ? "Transcribed from the recording" : "Lyrics timed from the recording")
        }
        state = status.job.state
        if ["queued", "processing"].contains(status.analysisJob?.state ?? "")
            || (status.analysisInfo?.analyzedAt != nil && status.analysisInfo?.analyzedAt != analysisInfo?.analyzedAt) {
            reanalysisError = nil
        }
        analysisInfo = status.analysisInfo
        analysisJob = status.analysisJob
        lyricsJob = status.lyricsJob
        if ["queued", "processing", "ready"].contains(status.lyricsJob?.state ?? "") {
            lyricTimingError = nil
        }
        if let flag = status.saved { saved = flag }
        if status.saved != nil {
            let candidate = status.timing ?? .identity
            timingIsStale = !candidate.matches(chartAudioSha256: analysis?.audioSha256, spotifyTrackID: song.id, chartRevision: analysis?.chartRevision)
            timing = timingIsStale ? .identity : candidate
            timingRevision = status.timingRevision
        }
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
    private func loadLyrics(force: Bool = false) {
        let key = lyricLookupKey
        guard !hasRecordingLyrics, force || key != lyricKey else { return }
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
        beatGrid = BeatGrid(tempo: analysis?.tempo, chords: analysis?.chords ?? [])
        rows = SheetModel.build(analysis: analysis, lines: lines,
                                duration: song.duration ?? analysis?.songDuration)
        let lyricRows = rows.filter { !$0.text.isEmpty }
        hasTimedLyricWords = lyricTimingIsSynced && lyricRows.contains { row in
            row.words?.contains { word in
                LyricPlayhead.currentWord(at: word.time, words: row.words ?? [], rowStart: row.start, rowEnd: row.end) != nil
            } == true
        }
        hasCompleteLyricTiming = lyricTimingIsSynced && !lyricRows.isEmpty && lyricRows.allSatisfy { row in
            guard let words = row.words, !words.isEmpty else { return false }
            return words.indices.allSatisfy { index in
                LyricPlayhead.currentWord(at: words[index].time, words: words, rowStart: row.start, rowEnd: row.end) == index
            }
        }
        if hasCompleteLyricTiming { lyricTimingError = nil }
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
