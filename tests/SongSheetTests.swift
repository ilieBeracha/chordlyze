import Combine
import Foundation

enum Config { static let backendBaseURL = URL(string: "http://127.0.0.1:1")! }
@MainActor final class SpotifyAuth { func validToken(rejecting: String? = nil) async throws -> String { fatalError("Tests must not authenticate") } }

@MainActor private var checks = 0
@MainActor private func check(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !value() { fatalError(message) }
}
@MainActor private func waitFor(_ predicate: () -> Bool) async throws {
    for _ in 0..<300 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    fatalError("Timed out waiting for observable state")
}
private func decode<T: Decodable>(_ object: Any, as: T.Type = T.self) -> T {
    try! JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
}
private func chart(_ segments: [[String: Any]] = [["start": 0, "end": 20, "label": "C:maj"]], preview: Bool = false) -> ChordAnalysis {
    decode(["chords": segments, "source": preview ? "itunes_preview" : "youtube", "audio_duration": 20, "song_duration": 20])
}
private func status(_ state: String, epoch: String = "fresh", ready: Bool = false, saved: Bool? = nil) -> SongStatus {
    var result: [String: Any] = ["job": ["state": state, "worker_online": true], "library_generation": epoch]
    if let saved { result["saved"] = saved }
    if ready { result["analysis"] = ["chords": [["start": 0, "end": 20, "label": "C:maj"]], "source": "youtube", "audio_duration": 20] }
    return decode(result)
}
private func lyrics(_ text: String = "First words") -> BackendClient.LyricsResult {
    decode(["lines": [["time": 2, "text": text], ["time": 8, "text": "Second line"]], "synced": true])
}
private func developerStatus(job: String? = "ready", stage: String? = nil, updated: Bool = false,
                             includeInfo: Bool = true, lyricJob: String? = nil,
                             workerOnline: Bool = true, ahead: Int? = nil) -> SongStatus {
    let chartRevision = String(repeating: updated ? "d" : "c", count: 64)
    var payload: [String: Any] = [
        "job": ["state": "ready", "worker_online": true], "library_generation": "developer-fixture",
        "analysis": ["source": "youtube", "audio_duration": 20, "chart_revision": chartRevision,
                     "audio_sha256": String(repeating: updated ? "b" : "a", count: 64),
                     "chords": [["start": 0, "end": 20, "label": updated ? "G:maj" : "C:maj"]]],
        "lyrics": ["synced": true, "matched": "aligned", "lines": [["time": 2, "text": "Authored line",
            "words": [["time": 2, "end": 2.5, "text": "Authored"], ["time": 3, "end": 3.5, "text": "line"]]]]]]
    if includeInfo {
        payload["analysis_info"] = ["analyzed_at": updated ? 1788912000.0 : 1700000000.0,
            "analysis_version": updated ? 4 : 2, "current_analysis_version": 4,
            "versions_behind": updated ? 0 : 2, "is_current": updated,
            "model": "ismir2019", "model_revision": updated ? "new-model" : "old-model",
            "current_model_revision": "new-model", "source_title": "Authored recording", "source_provider": "youtube",
            "current_version_released_at": 1788860000.0, "chart_revision": chartRevision]
    }
    if let job {
        var value: [String: Any] = ["state": job, "worker_online": workerOnline, "message": "Authored reanalysis \(job)"]
        if let stage { value["stage"] = stage }
        if let ahead { value["ahead"] = ahead }
        payload["analysis_job"] = value
    }
    if let lyricJob { payload["lyrics_job"] = ["state": lyricJob, "worker_online": true] }
    return decode(payload)
}
private func playback(id: String = "one", milliseconds: Int? = 12000, playing: Bool = true, deviceID: String = "phone") -> SpotifyAPI.CurrentlyPlaying {
    decode(["progress_ms": milliseconds.map { $0 as Any } ?? NSNull(), "is_playing": playing,
        "device": ["id": deviceID, "name": deviceID == "phone" ? "iPhone" : deviceID, "type": "Smartphone", "is_active": true], "item": [
        "id": id, "name": "Song", "artists": [["name": "Band"]], "album": ["name": "Album"], "duration_ms": 200000]])
}

@MainActor private final class NativeSpotifyFixture: SpotifyNativeTransport {
    var isConnected = false
    var tokens: [String] = []
    var connections: [(Result<Void, Error>) -> Void] = []
    var disconnects = 0
    var reads = 0
    var plays: [String] = []
    var seeks: [Double] = []
    var sample: SpotifyAPI.CurrentlyPlaying? = playback(deviceID: SpotifyNativeSession.device.id!)
    var read: (() async throws -> SpotifyAPI.CurrentlyPlaying?)?
    func connect(token: String, completion: @escaping (Result<Void, Error>) -> Void) {
        tokens.append(token)
        connections.append(completion)
    }
    func connected() {
        isConnected = true
        connections.last?(.success(()))
    }
    func disconnect() { isConnected = false; disconnects += 1 }
    func current() async throws -> SpotifyAPI.CurrentlyPlaying? {
        reads += 1
        if let read { return try await read() }
        return sample
    }
    func playURI(_ trackID: String) async throws { plays.append(trackID) }
    func seek(_ seconds: Double) async throws { seeks.append(seconds) }
}

@main struct SongSheetTests {
    @MainActor static func main() async throws {
        lyricCompletenessTests()
        independentChordTimingTests()
        partialWordTimingTests()
        try sharedWordTimingContractTests()
        estimatedWordTimingTests()
        lyricEntrancePresentationTests()
        try await savedAlignmentRefreshTests()
        try await lyricTimingRecoveryTests()
        developerMetadataTests()
        try await developerReanalysisTests()
        try await developerReanalysisRaceTests()
        try await developerReanalysisRecoveryTests()
        modelTests()
        barMapTests()
        runnerTests()
        sungWordTests()
        try await documentTests()
        try await correctionTests()
        try await passageTests()
        try await synchronizationAndBoundaryTests()
        try await loadedChartRecoveryTests()
        try await recordingLyricsRecoveryTests()
        try await cancellationTests()
        try await playbackTests()
        try await playbackReliabilityTests()
        try await spotifyDeviceRecoveryTests()
        try await spotifyStartupTests()
        try await spotifyNativeSessionTests()
        recentPlaysTests()
        print("Song sheet and playback: \(checks)/\(checks) checks passed")
    }

    @MainActor static func developerMetadataTests() {
        let legacy = status("ready", ready: true)
        check(legacy.analysisInfo == nil && legacy.analysisJob == nil && legacy.analysis != nil,
              "Legacy song responses remain playable without invented developer metadata")
        let old = developerStatus().analysisInfo!
        check(old.analysisVersion == 2 && old.currentAnalysisVersion == 4 && old.versionsBehind == 2,
              "Developer metadata preserves stored and current analysis versions")
        check(old.statusLabel == "2 versions behind" && old.versionLabel == "v2 · latest v4",
              "An older analysis clearly reports its version distance")
        check(old.analyzedDate == Date(timeIntervalSince1970: 1700000000)
              && old.latestVersionDate == Date(timeIntervalSince1970: 1788860000),
              "Last analysis and new version dates use their own server timestamps")
        check(old.sourceTitle == "Authored recording" && old.sourceProvider == "youtube"
              && old.modelRevision == "old-model" && old.currentModelRevision == "new-model",
              "Source and model metadata survive decoding")
        let current = developerStatus(updated: true).analysisInfo!
        check(current.isCurrent && current.statusLabel == "Up to date" && current.versionsBehind == 0,
              "A fully current analysis is distinguished from an older model at the same version")
        var raw: [String: Any] = ["analysis_version": 4, "current_analysis_version": 4,
            "versions_behind": 0, "is_current": false, "model_revision": "older-model",
            "current_model_revision": "newer-model", "future_metadata": ["enabled": true]]
        let modelOnly: SongAnalysisInfo = decode(raw)
        check(modelOnly.statusLabel == "Update available" && !modelOnly.isCurrent,
              "Equal numbered versions cannot hide a changed recognition model")
        check(modelOnly.analyzedDate == nil && modelOnly.latestVersionDate == nil,
              "Missing analysis or release timestamps stay unknown")
        raw["analysis_version"] = 3; raw["versions_behind"] = 1
        check(decode(raw, as: SongAnalysisInfo.self).statusLabel == "1 version behind", "A single outdated version uses singular wording")
        raw["analysis_version"] = 5; raw["versions_behind"] = 0
        check(decode(raw, as: SongAnalysisInfo.self).statusLabel == "Newer than this service",
              "A newer saved analysis is not misreported as an update requirement")
        raw["analysis_version"] = NSNull(); raw["versions_behind"] = NSNull()
        let unknown: SongAnalysisInfo = decode(raw)
        check(unknown.statusLabel == "Version unknown" && unknown.versionLabel == "Unknown · latest v4",
              "Unversioned legacy analysis never receives a made-up version")
        for seconds in [0.0, -1] {
            raw["analyzed_at"] = seconds; raw["current_version_released_at"] = seconds
            let invalid: SongAnalysisInfo = decode(raw)
            check(invalid.analyzedDate == nil && invalid.latestVersionDate == nil,
                  "Nonpositive metadata dates cannot display an invented historical date")
        }
        let extra: SongStatus = decode(["job": ["state": "ready", "worker_online": true],
            "library_generation": "legacy", "analysis_info": NSNull(), "analysis_job": NSNull(),
            "unknown_future_status": ["field": 1]])
        check(extra.analysisInfo == nil && extra.analysisJob == nil, "Additive metadata and unknown server fields keep legacy decoding compatible")
    }

    @MainActor static func developerReanalysisTests() async throws {
        var current = developerStatus()
        var requests = 0, implicitRequests = 0, requestMode = 0
        var pending: CheckedContinuation<SongStatus, Never>?
        let sheet = SongSheetStore(song: SongDescriptor(trackID: "developer", title: "Authored", artist: "Fixture"), service: .init(
            request: { _ in implicitRequests += 1; return current }, status: { _ in current }, lyrics: { _ in nil },
            sleep: { _ in try await Task.sleep(for: .milliseconds(10)) }, reanalyze: { track, revision in
                requests += 1
                check(track == "developer" && revision == String(repeating: "c", count: 64),
                      "Reanalyze carries the selected song and exact displayed chart revision")
                if requestMode == 0 { return await withCheckedContinuation { pending = $0 } }
                if requestMode == 1 { throw URLError(.timedOut) }
                return current
            }))
        let observation = Task { await sheet.observe() }
        try await waitFor { sheet.canReanalyze && sheet.canPractice }
        let oldChart = sheet.analysis, oldDate = sheet.analysisInfo?.analyzedAt
        sheet.refresh()
        try await Task.sleep(for: .milliseconds(30))
        check(requests == 0 && implicitRequests == 0, "Opening settings and refreshing metadata never enqueue reanalysis")
        let requesting = Task { await sheet.reanalyze() }
        try await waitFor { pending != nil }
        check(sheet.requestingReanalysis && sheet.reanalysisPending && !sheet.canReanalyze
              && sheet.canPractice && sheet.analysis == oldChart,
              "A pending reanalysis request leaves the existing chart playable and prevents duplicate taps")
        check(sheet.analysisProgressLabel == "Requesting reanalysis…", "The explicit enqueue request has visible progress")
        await sheet.reanalyze()
        check(requests == 1, "Repeated Reanalyze taps share the pending request")
        current = developerStatus(job: "queued")
        pending?.resume(returning: current); pending = nil
        await requesting.value
        try await waitFor { sheet.analysisJob?.state == "queued" }
        check(sheet.reanalysisPending && sheet.analysisProgressLabel == "Queued" && sheet.canPractice
              && sheet.analysis == oldChart && sheet.analysisInfo?.analyzedAt == oldDate,
              "Queued work keeps the last successful chart and date visible")
        await sheet.reanalyze()
        check(requests == 1, "A server-queued job also prevents another enqueue")
        for ahead in [1, 3] {
            current = developerStatus(job: "queued", workerOnline: false, ahead: ahead)
            sheet.refresh()
            try await waitFor { sheet.analysisJob?.ahead == ahead }
            check(sheet.analysisProgressLabel == "Waiting for service" && sheet.reanalysisPending && sheet.canPractice,
                  "A disconnected worker keeps queued work pending and the existing chart playable")
            check(sheet.analysisProgressMessage == "\(ahead) \(ahead == 1 ? "song" : "songs") ahead in the queue.",
                  "Queue progress reports the server's position with readable pluralization")
        }
        for (stage, label) in [("downloading", "Finding and downloading recording"),
                               ("analyzing", "Analyzing chords and rhythm"), ("aligning", "Timing lyrics")] {
            current = developerStatus(job: "processing", stage: stage)
            sheet.refresh()
            try await waitFor { sheet.analysisJob?.stage == stage }
            check(sheet.analysisProgressLabel == label && sheet.analysisProgressMessage != nil,
                  "The \(stage) stage has readable live progress")
            check(sheet.reanalysisPending && !sheet.canReanalyze && sheet.canPractice
                  && sheet.analysis == oldChart && sheet.analysisInfo?.analyzedAt == oldDate,
                  "The \(stage) stage cannot replace the chart or successful analysis date early")
        }
        current = developerStatus(job: "failed")
        sheet.refresh()
        try await waitFor { sheet.analysisJob?.state == "failed" }
        check(!sheet.reanalysisPending && sheet.canReanalyze && sheet.canPractice && sheet.analysis == oldChart,
              "A failed rerun enables retry without losing the old chart")
        check(sheet.analysisProgressLabel == "Reanalysis failed" && sheet.analysisProgressMessage == "Authored reanalysis failed",
              "The service failure is surfaced without claiming success")
        current = developerStatus(job: "unavailable")
        sheet.refresh()
        try await waitFor { sheet.analysisJob?.state == "unavailable" }
        check(sheet.analysisProgressLabel == "Reanalysis failed" && sheet.canReanalyze && sheet.canPractice,
              "An unavailable recording permits retry and preserves the last successful chart")
        requestMode = 1
        await sheet.reanalyze()
        check(requests == 2 && sheet.reanalysisError != nil && sheet.canPractice && sheet.analysis == oldChart,
              "An unconfirmed network request reports its error and preserves the loaded chart")
        current = developerStatus(job: "queued"); requestMode = 2
        await sheet.reanalyze()
        try await waitFor { sheet.analysisJob?.state == "queued" }
        check(requests == 3 && sheet.reanalysisError == nil, "A confirmed retry clears the previous request error")
        current = developerStatus(updated: true)
        sheet.refresh()
        try await waitFor { sheet.analysisInfo?.isCurrent == true }
        check(sheet.analysis == current.analysis && sheet.analysisInfo?.analyzedAt == 1788912000
              && !sheet.reanalysisPending && sheet.canPractice && sheet.canReanalyze,
              "Successful completion publishes the new chart and date together and permits a later explicit rerun")
        current = developerStatus(updated: true, lyricJob: "processing")
        sheet.refresh()
        try await waitFor { sheet.timingLyrics }
        check(sheet.reanalysisPending && !sheet.canReanalyze && sheet.canPractice,
              "Active lyric alignment prevents competing reanalysis while leaving the chart available")
        current = developerStatus(job: nil, includeInfo: false)
        sheet.refresh()
        try await waitFor { sheet.analysisInfo == nil }
        check(!sheet.canReanalyze && sheet.canPractice, "An older server remains playable without offering an unsupported developer action")
        observation.cancel(); await observation.value
    }

    @MainActor static func developerReanalysisRaceTests() async throws {
        let original = developerStatus(), replacement = developerStatus(updated: true)
        var current = original, calls = 0
        var staleRead: CheckedContinuation<SongStatus, Never>?
        let store = SongSheetStore(song: SongDescriptor(trackID: "race", title: "Authored", artist: "Fixture"), service: .init(
            status: { _ in
                calls += 1
                if calls == 2 { return await withCheckedContinuation { staleRead = $0 } }
                return current
            }, lyrics: { _ in nil }, sleep: { _ in try await Task.sleep(for: .milliseconds(10)) },
            reanalyze: { _, _ in current = replacement; return replacement }))
        let observation = Task { await store.observe() }
        try await waitFor { store.canReanalyze && staleRead != nil }
        await store.reanalyze()
        check(store.analysis == replacement.analysis && store.analysisInfo == replacement.analysisInfo,
              "A completed rerun updates the chart and developer metadata atomically")
        staleRead?.resume(returning: original); staleRead = nil
        try await Task.sleep(for: .milliseconds(40))
        check(store.analysis == replacement.analysis && store.analysisInfo == replacement.analysisInfo,
              "An in-flight pre-rerun status response cannot undo newer chart metadata")
        observation.cancel(); await observation.value

        for failure in [false, true] {
            var fresh = original
            var pending: CheckedContinuation<SongStatus, Error>?
            let guarded = SongSheetStore(song: SongDescriptor(trackID: "late", title: "Authored", artist: "Fixture"), service: .init(
                status: { _ in fresh }, lyrics: { _ in nil }, sleep: { _ in try await Task.sleep(for: .milliseconds(10)) },
                reanalyze: { _, _ in try await withCheckedThrowingContinuation { pending = $0 } }))
            let watching = Task { await guarded.observe() }
            try await waitFor { guarded.canReanalyze }
            let request = Task { await guarded.reanalyze() }
            try await waitFor { pending != nil }
            fresh = replacement
            guarded.refresh()
            try await waitFor { guarded.analysisInfo?.isCurrent == true }
            check(guarded.requestingReanalysis && !guarded.canReanalyze && guarded.canPractice,
                  "Refreshing during an in-flight enqueue reads new data without permitting a duplicate request")
            if failure { pending?.resume(throwing: URLError(.timedOut)) }
            else { pending?.resume(returning: developerStatus(job: "queued")) }
            pending = nil
            await request.value
            check(guarded.analysis == replacement.analysis && guarded.analysisInfo == replacement.analysisInfo
                  && !guarded.reanalysisPending && guarded.reanalysisError == nil,
                  "A superseded reanalysis \(failure ? "failure" : "response") cannot overwrite fresh data or reintroduce a pending state")
            watching.cancel(); await watching.value
        }
    }

    @MainActor static func developerReanalysisRecoveryTests() async throws {
        for canonical in [String(repeating: "e", count: 64), ""] {
            var loaded = developerStatus()
            var info: [String: Any] = ["current_analysis_version": 4, "is_current": false]
            if !canonical.isEmpty { info["chart_revision"] = canonical }
            loaded.analysisInfo = decode(info)
            var received: String?
            let store = SongSheetStore(song: SongDescriptor(trackID: "personal", title: "Authored", artist: "Fixture"), service: .init(
                status: { _ in loaded }, lyrics: { _ in nil },
                sleep: { _ in try await Task.sleep(for: .milliseconds(10)) },
                reanalyze: { _, revision in received = revision; return loaded }))
            let observation = Task { await store.observe() }
            try await waitFor { store.canReanalyze }
            await store.reanalyze()
            check(received == (canonical.isEmpty ? loaded.analysis?.chartRevision : canonical),
                  "Reanalysis uses the canonical server revision before a personal chart revision, with a compatible fallback")
            observation.cancel(); await observation.value
        }
        for code in [404, 409] {
            let loaded = developerStatus()
            let store = SongSheetStore(song: SongDescriptor(trackID: "failure", title: "Authored", artist: "Fixture"), service: .init(
                status: { _ in loaded }, lyrics: { _ in nil },
                sleep: { _ in try await Task.sleep(for: .milliseconds(10)) },
                reanalyze: { _, _ in throw BackendError(status: code, detail: "Authored service error") }))
            let observation = Task { await store.observe() }
            try await waitFor { store.canReanalyze }
            await store.reanalyze()
            let expected = code == 404 ? "Reanalysis is not available on this service yet."
                : "The chart changed. Refresh its status before trying again."
            check(store.reanalysisError == expected && !store.reanalysisPending
                  && store.canPractice && store.analysis == loaded.analysis,
                  "HTTP \(code) explains recovery without losing the last chart or inventing progress")
            observation.cancel(); await observation.value
        }

        for failure in [false, true] {
            let original = developerStatus()
            var pending: CheckedContinuation<SongStatus, Error>?
            let store = SongSheetStore(song: SongDescriptor(trackID: "departing", title: "Authored", artist: "Fixture"), service: .init(
                status: { _ in original }, lyrics: { _ in nil },
                sleep: { _ in try await Task.sleep(for: .milliseconds(10)) },
                reanalyze: { _, _ in try await withCheckedThrowingContinuation { pending = $0 } }))
            let observation = Task { await store.observe() }
            try await waitFor { store.canReanalyze }
            let request = Task { await store.reanalyze() }
            try await waitFor { pending != nil }
            observation.cancel(); await observation.value
            if failure { pending?.resume(throwing: URLError(.timedOut)) }
            else { pending?.resume(returning: developerStatus(updated: true)) }
            pending = nil
            await request.value
            check(store.analysis == original.analysis && store.analysisInfo == original.analysisInfo
                  && store.reanalysisError == nil && !store.requestingReanalysis,
                  "Leaving the last observing screen invalidates a delayed reanalysis \(failure ? "error" : "response")")
        }
    }

    @MainActor static func sharedWordTimingContractTests() throws {
        struct Case: Decodable {
            let id: String
            let line: LyricLine
            let boundary: Double
            let usable: [Int]
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: "tests/fixtures/word-timing-contract.json"))
        let fixtures = try JSONDecoder().decode([Case].self, from: data)
        check(fixtures.filter { $0.id.hasPrefix("reported-") }.count == 124, "All reported failure geometries remain covered")
        for fixture in fixtures {
            let original = fixture.line.words!
            check(SheetModel.usableWordIndices(fixture.line, before: fixture.boundary) == fixture.usable,
                  "Shared backend/client timing contract: \(fixture.id)")
            let projected = SheetModel.completeWords(fixture.line, before: fixture.boundary)
            if fixture.usable.isEmpty {
                check(projected == nil, "A wholly uncertain phrase cannot invent word anchors: \(fixture.id)")
                continue
            }
            check(projected?.map(\.text) == original.map(\.text), "All lyric words survive: \(fixture.id)")
            for index in original.indices {
                if fixture.usable.contains(index) {
                    check(projected![index] == original[index], "Usable word stays exact: \(fixture.id)/\(index)")
                } else {
                    check(projected![index].estimated == true && projected![index].end == nil,
                          "Uncertain word stays visibly approximate: \(fixture.id)/\(index)")
                }
            }
            check(zip(projected!, projected!.dropFirst()).allSatisfy { $0.time <= $1.time },
                  "Presentation never reverses lyric order: \(fixture.id)")
        }
    }


    @MainActor static func correctionTests() async throws {
        func response(_ corrected: Bool) -> SongStatus {
            var segment: [String: Any] = ["start": 0, "end": 20, "label": corrected ? "D:min7" : "C:maj"]
            if corrected { segment["original_label"] = "C:maj" }
            return decode(["job": ["state": "ready", "worker_online": true],
                "library_generation": "one", "saved": true,
                "analysis": ["chords": [segment], "source": "youtube", "audio_duration": 20,
                    "audio_sha256": "audio", "chart_revision": corrected ? "new" : "old"]])
        }
        let original = response(false), corrected = response(true)
        var latest = original
        var staleRead: CheckedContinuation<SongStatus, Never>?
        var calls = 0
        var writes = 0
        var fail = false
        let store = SongSheetStore(song: SongDescriptor(trackID: "edit", title: "Song", artist: "Band"),
            analysis: original.analysis, service: .init(status: { _ in
                calls += 1
                if calls == 1 { return await withCheckedContinuation { staleRead = $0 } }
                return latest
            }, lyrics: { _ in nil }, correctChord: { track, segment, name, revision in
                writes += 1
                check(track == "edit" && segment.start == 0 && segment.end == 20, "Correction targets an occurrence")
                if fail { throw URLError(.notConnectedToInternet) }
                check(revision == (name == nil ? "new" : "old"), "Correction carries the chart revision")
                check(name == nil || name == "Dm7", "Correction stays in original key")
                latest = name == nil ? original : corrected
                return latest
            }))
        store.manualShift = 2
        let observing = Task { await store.observe() }
        defer { observing.cancel() }
        try await waitFor { staleRead != nil }
        try await store.correctChord(original.analysis!.chords[0], name: "Dm7", expectedRevision: "old")
        check(store.analysis == corrected.analysis && store.saved, "Saved correction updates the shared document")
        check(store.rows.flatMap(\.chords).first?.event.display(transposedBy: store.shift) == "Em7", "Live and sheet use corrected, transposed events")
        check(store.manualShift == 2, "Correction preserves playing settings")
        check(store.analysis?.chords[0].originalLabel == "C:maj", "Original remains available for undo")
        staleRead?.resume(returning: original)
        try await Task.sleep(for: .milliseconds(30))
        check(store.analysis == corrected.analysis, "In-flight stale poll cannot undo a correction")
        do {
            try await store.correctChord(original.analysis!.chords[0], name: "G", expectedRevision: "old")
            fatalError("Stale editor saved")
        } catch { check(writes == 1, "Stale editor rejected before networking") }
        fail = true
        do {
            try await store.correctChord(corrected.analysis!.chords[0], name: nil, expectedRevision: "new")
            fatalError("Failed write succeeded")
        } catch {}
        check(store.analysis == corrected.analysis && !store.savingCorrection, "Failed correction preserves chart and unlocks retry")
        fail = false
        try await store.correctChord(corrected.analysis!.chords[0], name: nil, expectedRevision: "new")
        check(store.analysis == original.analysis && !store.savingCorrection, "Restore updates every surface")
    }

    @MainActor static func synchronizationAndBoundaryTests() async throws {
        for duration in [45.0, 90, 240, 1200] {
            let windows = AutomaticSyncPlan.windows(duration: duration)
            check(windows.count == 3, "Three windows for supported songs")
            check(windows.allSatisfy { $0.start >= 0 && $0.duration >= 12 && $0.duration <= 22 && $0.start + $0.duration <= duration }, "Listening stays inside the track")
            check(windows[2].start - windows[0].start >= 15, "Windows separated enough to measure an offset")
        }
        check(AutomaticSyncPlan.windows(duration: 20).isEmpty && AutomaticSyncPlan.windows(duration: .nan).isEmpty, "Unsupported duration refused")
        check(AutomaticSyncPlan.uninterrupted(start: 20, position: 30.3, elapsed: 10), "Small polling adjustment allowed")
        check(!AutomaticSyncPlan.uninterrupted(start: 20, position: 32, elapsed: 10), "Seek rejects listening window")
        check(!AutomaticSyncPlan.uninterrupted(start: 20, position: 20, elapsed: 10), "Pause rejects listening window")
        func response(moved: Bool = false, synced: Bool = false) -> SongStatus {
            var data: [String: Any] = ["job": ["state": "ready", "worker_online": true], "saved": true,
                "library_generation": "one", "timing_revision": synced ? "timed" : "empty",
                "analysis": ["source": "youtube", "audio_sha256": "audio", "audio_duration": 40,
                    "chart_revision": moved ? "moved" : "base", "can_undo": moved, "boundaries_edited": moved,
                    "chords": [["start": 0, "end": moved ? 12 : 10, "label": "C:maj"],
                               ["start": moved ? 12 : 10, "end": 40, "label": "G:maj"]]]]
            if synced { data["timing"] = ["offset": 1.2, "scale": 1.01, "anchors": [], "chart_revision": "base",
                "chart_audio_sha256": "audio", "spotify_track_id": "sync", "method": "automatic", "drift_measured": true] }
            return decode(data)
        }
        var latest = response()
        var fail = false
        var boundaryWrites = 0
        let store = SongSheetStore(song: SongDescriptor(trackID: "sync", title: "Song", artist: "Band"), service: .init(
            status: { _ in latest }, lyrics: { _ in nil },
            editBoundary: { _, edit in
                boundaryWrites += 1
                if fail { throw URLError(.notConnectedToInternet) }
                check(edit.operation == .move || edit.operation == .undo, "Boundary operation transmitted")
                latest = response(moved: edit.operation == .move, synced: true)
                return latest
            }, synchronize: { _, _, revision, timingRevision in
                check(revision == "base" && timingRevision == "empty", "Sync carries chart and timing concurrency guards")
                latest = response(synced: true)
                return latest
            }))
        let observer = Task { await store.observe() }
        defer { observer.cancel() }
        try await waitFor { store.state == "ready" }
        try await store.synchronize(clips: [], chartRevision: "base", timingRevision: "empty")
        check(store.timing.offset == 1.2 && store.timing.scale == 1.01 && store.timingNote?.contains("Automatically") == true, "Automatic map applied to shared playback")
        check(abs(store.timing.chartTime(store.timing.spotifyTime(100)) - 100) < 0.00001, "Map remains invertible after seeking")
        let request = BackendClient.BoundaryEdit(operation: .move, start: 0, end: 10, at: 12, chartRevision: "base")
        fail = true
        do { try await store.editBoundary(request); fatalError("Failed boundary edit accepted") } catch {}
        check(store.analysis?.chords[0].end == 10 && store.timing.offset == 1.2, "Failed edit leaves chart and calibration intact")
        fail = false
        try await store.editBoundary(request)
        check(store.analysis?.chords[0].end == 12 && store.rows.flatMap(\.chords).contains(where: { $0.event.start == 12 }), "Boundary reaches the shared sheet model")
        check(store.timingIsStale && store.timing.isIdentity && store.timingNote?.contains("earlier chart") == true, "Old timing is disabled after a chart edit")
        do { try await store.editBoundary(request); fatalError("Stale boundary edit accepted") }
        catch { check(boundaryWrites == 2, "Stale edit rejected before request") }
        try await store.editBoundary(.init(operation: .undo, chartRevision: "moved"))
        check(!store.timingIsStale && store.timing.offset == 1.2, "Undo restores the matching timing map")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        check(object["chart_revision"] as? String == "base" && object["at"] as? Double == 12, "Boundary request encodes time and revision")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("sample audio".utf8).write(to: file)
        let upload = try BackendClient.synchronizationRequest(trackID: "sync", clips: [10.0, 100, 200].map { .init(file: file, spotifyStart: $0) }, chartRevision: "base", timingRevision: "timed")
        let body = String(data: upload.httpBody!, encoding: .utf8)!
        check(body.components(separatedBy: "name=\"files\"").count == 4, "All three recordings uploaded")
        check(body.contains("name=\"positions\"") && body.contains("name=\"timing_revision\"") && body.contains("name=\"chart_revision\""), "Sync request includes sample clock and concurrency guards")
    }

    @MainActor static func barMapTests() {
        let times = (0..<17).map { Double($0)*0.5 }
        let positions = [2, 3] + Array(repeating: [1, 2, 3], count: 5).flatMap { $0 }
        let bars: [[String: Any]] = (0..<4).map { index in
            let start = 1.0 + Double(index)*1.5
            return ["start": start, "end": start+1.5, "beats": 3]
        }
        var data: [String: Any] = ["bpm": 120, "beats": times, "beat_positions": positions,
            "rhythm_version": 1, "bars": bars,
            "sections": [["start": 1, "end": 7, "start_bar": 1, "end_bar": 4, "label": "A", "occurrence": 1]]]
        func grid(_ data: [String: Any]) -> BeatGrid? {
            BeatGrid(tempo: decode(data, as: ChordAnalysis.Tempo.self), chords: [])
        }
        let triple = grid(data)!
        check(triple.bars.count == 4 && triple.sections.count == 1, "Detected bar and section metadata decoded")
        check(!triple.isEstimated && triple.beatsInBar(at: 3) == 3, "Detected triple meter replaces 4/4 inference")
        check(triple.beatsInBar(at: 8) == 3, "Partial ending retains the last known meter")
        check(triple.beatInBar(at: 0) == 2 && triple.beatInBar(at: 1) == 1, "Pickup positions retained")
        check(triple.barNumber(at: 0) == nil && triple.barNumber(at: 2.5) == 2, "Bar boundaries are half-open; pickup unnumbered")
        check(triple.barNumber(at: 7) == nil, "Partial tail is outside complete bar map")
        check(triple.barRange(first: 2, last: 3) == 2.5...5.5, "Selected bars use exact endpoints")
        check(triple.barRange(first: 0, last: 3) == nil && triple.barRange(first: 2, last: 1) == nil && triple.barRange(first: 1, last: 5) == nil, "Out of bounds and reversed ranges rejected")
        let clicks = triple.clicks(from: 1, to: 4)
        check(clicks.count == 6 && clicks.enumerated().filter { $0.element.downbeat }.map(\.offset) == [0, 3], "Metronome accents every third beat")
        let map = TimingMap(offset: 2, scale: 1.01)
        let range = triple.barRange(first: 2, last: 3)!
        check(abs(map.chartTime(map.spotifyTime(range.lowerBound))-range.lowerBound) < 1e-9, "Bar selection endpoints survive calibrated clock mapping")
        var broken = data; broken["beat_positions"] = [1]
        check(grid(broken)!.bars.isEmpty && grid(broken)!.sections.isEmpty, "Malformed positions disable bar actions")
        broken = data; broken["bars"] = [["start": 1, "end": 99, "beats": 3]]
        check(grid(broken)!.bars.isEmpty, "Out of timeline bar rejected")
        broken = data; broken["sections"] = [["start": 1, "end": 7, "start_bar": 0, "end_bar": 4, "label": "A", "occurrence": 1]]
        check(grid(broken)!.sections.isEmpty && grid(broken)!.bars.count == 4, "Bad section cannot corrupt valid bars")
        broken = data; broken["bars"] = [bars[0], bars[2]]; broken["sections"] = []
        check(grid(broken)!.barRange(first: 1, last: 2) == nil, "No bar selection across missing bar")
        data["bars"] = []; data["sections"] = []; data["beat_positions"] = []
        let unmetered = grid(data)!
        check(unmetered.bars.isEmpty && !unmetered.isDownbeat(0), "New beat-only analyses never invent 4/4 downbeats")
        check(unmetered.downbeat(atOrBefore: 6.3) == 6, "Unmetered section start stays near selected passage")
        data["beats"] = [0, 1, 1, 2]
        check(grid(data) == nil, "Duplicate beats rejected without desynchronizing positions")
        let varying: [String: Any] = ["bpm": 120, "beats": [0, 0.5, 1, 1.5, 2.1, 2.7, 3.3, 3.9],
            "rhythm_version": 1, "beat_positions": [1, 2, 3, 1, 2, 3, 4, 1],
            "bars": [["start": 0, "end": 1.5, "beats": 3], ["start": 1.5, "end": 3.9, "beats": 4]], "sections": []]
        let changing = grid(varying)!
        check(changing.beatsInBar(at: 1) == 3 && changing.beatsInBar(at: 2) == 4, "Contract supports changing meter")
        check(abs(changing.period(at: 2)-0.6) < 1e-9, "Count-in uses local tempo")
    }

    @MainActor static func recentPlaysTests() {
        func track(_ id: String) -> Track {
            decode(["id": id, "name": id, "artists": [["name": "Band"]], "album": ["name": "Album"]])
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let plays = [SpotifyAPI.RecentPlay(track: track("a"), playedAt: now.addingTimeInterval(-7200)),
                     SpotifyAPI.RecentPlay(track: track("b"), playedAt: now.addingTimeInterval(-90)),
                     SpotifyAPI.RecentPlay(track: track("a"), playedAt: now.addingTimeInterval(-30))]
        let songs = RecentPlays.songs(plays)
        check(songs.map(\.id) == ["a", "b"], "One row per song, most recent play first")
        check(songs[0].count == 2 && songs[1].count == 1 && songs[0].lastPlayed == now.addingTimeInterval(-30), "Repeat plays are counted and dated by the latest")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let days = RecentPlays.daily(plays, analyzed: ["a"], days: 3, calendar: calendar, now: now)
        check(days.count == 3 && days.map(\.total) == [0, 0, 3] && days.map(\.analyzed) == [0, 0, 2], "Plays are bucketed by day, oldest first, with analyzed counts")
        check(days.last?.date == calendar.startOfDay(for: now), "The last bucket is today")
        check(RecentPlays.relativeTime(now.addingTimeInterval(-30), now: now) == "now", "Under a minute reads as now")
        check(RecentPlays.relativeTime(now.addingTimeInterval(-600), now: now) == "10m ago", "Minutes ago")
        check(RecentPlays.relativeTime(now.addingTimeInterval(-7200), now: now) == "2h ago", "Hours ago")
    }

    /// The lyric runner: words alone drive it; chords never move it.
    @MainActor static func runnerTests() {
        // One visual line: five words 60 pt apart. Word 2 is held for ten seconds under many chords.
        let words: [Int: CGRect] = Dictionary(uniqueKeysWithValues: (0..<5).map { ($0, CGRect(x: CGFloat($0) * 60, y: 0, width: 50, height: 20)) })
        let times = [10.0, 11.0, 12.0, 22.0, 23.0]
        let chords: [(time: Double, wordIndex: Int)] = [(12, 2), (14, 2), (16, 2), (18, 2), (20, 2)]
        let points = LyricPlayhead.waypoints(rowStart: 8, rowEnd: 30, words: words, wordTimes: times, chordStarts: chords, rtl: false)
        check(points.map(\.time) == [8, 9, 10, 11, 12, 22, 23, 24, 30], "Edge, one second before the first word, each word, a one-second tail, the row end")
        check(!points.contains { [14, 16, 18, 20].contains($0.time) }, "Chord changes above a held word add no waypoints")
        let held = LyricPlayhead.position(at: 17, along: points, rtl: false)!
        check(held.x == 120 + (180 - 120) * 0.125, "Halfway through a held word the runner has moved only an eighth of the way: it lingers, then arrives on the onset")
        check(LyricPlayhead.position(at: 22, along: points, rtl: false)!.x == 180, "It reaches the next word exactly at its onset")
        check(LyricPlayhead.position(at: 8.5, along: points, rtl: false)!.x == 0, "Before the lead-in it waits at the leading edge")
        check(LyricPlayhead.position(at: 26, along: points, rtl: false)!.x == 290, "After the tail it rests at the trailing edge")
        check(LyricPlayhead.currentWord(at: 17, wordTimes: times) == 2 && LyricPlayhead.currentWord(at: 9.9, wordTimes: times) == nil
              && LyricPlayhead.currentWord(at: 23, wordTimes: times) == 4, "The highlighted word is the last one begun")
        // Seeking: any time resolves without state.
        check(LyricPlayhead.position(at: 22.5, along: points, rtl: false)!.x == 180 + 60 * 0.125, "Seeking to any time resolves without state")
        // A wrapped line: words 3 and 4 sit on a second visual line.
        var wrapped = words
        wrapped[3] = CGRect(x: 0, y: 40, width: 50, height: 20); wrapped[4] = CGRect(x: 60, y: 40, width: 50, height: 20)
        let wrapPoints = LyricPlayhead.waypoints(rowStart: 8, rowEnd: 30, words: wrapped, wordTimes: times, chordStarts: [], rtl: false)
        let crossing = LyricPlayhead.position(at: 17, along: wrapPoints, rtl: false)!
        check(crossing.y == 10 && crossing.x > 120, "Halfway from word 2 to a wrapped word 3 the runner is still on the first line, moving right")
        let nearEnd = LyricPlayhead.position(at: 21.9, along: wrapPoints, rtl: false)!
        check(nearEnd.y == 10 && nearEnd.x > 165, "Just before a wrapped word it has run to the end of the first line")
        let arrived = LyricPlayhead.position(at: 22, along: wrapPoints, rtl: false)!
        check(arrived.y == 50 && arrived.x == 0, "At the word's onset it is on the second line at that word")
        // Line-timed rows: chords are the only fixed points.
        let lineTimed = LyricPlayhead.waypoints(rowStart: 8, rowEnd: 30, words: words, wordTimes: nil, chordStarts: [(12, 1), (20, 3)], rtl: false)
        check(lineTimed.map(\.time) == [8, 12, 20, 30] && lineTimed.map(\.x) == [0, 60, 180, 290], "Without word times the runner moves chord to chord and on to the edge")
        // Right-to-left text runs the other way.
        let rtlPoints = LyricPlayhead.waypoints(rowStart: 8, rowEnd: 30, words: words, wordTimes: times, chordStarts: [], rtl: true)
        check(rtlPoints.first!.x == 290 && rtlPoints.last!.x == 0, "Right-to-left rows enter at the right edge and leave at the left")
    }

    @MainActor static func sungWordTests() {
        let words = [WordStamp(time: 19.2, text: "Stay", end: 19.8),
                     WordStamp(time: 20.1, text: "here", end: 23.3),
                     WordStamp(time: 23.8, text: "with", end: 24.1),
                     WordStamp(time: 24.2, text: "me", end: 25)]
        func current(_ time: Double, _ source: [WordStamp] = words, start: Double = 0, end: Double = 28) -> Int? {
            LyricPlayhead.currentWord(at: time, words: source, rowStart: start, rowEnd: end)
        }
        check(current(0) == nil && current(19) == nil && current(19.199) == nil,
              "An instrumental opening never lights a word before its measured vocal onset")
        check(current(19.2) == 0 && current(19.799) == 0 && current(19.8) == nil,
              "A sung word turns on at its measured onset and off at its exact end")
        check(current(20) == nil && current(23.5) == nil && current(24.15) == nil,
              "Vocal rests remain unhighlighted even within the active lyric row")
        check(current(24.2) == 3 && current(25) == nil && current(27.9) == nil,
              "The last word stops lighting when singing ends, without an invented tail")

        let changes: ChordAnalysis = decode(["source": "youtube", "audio_duration": 28,
                             "chords": [["start": 19, "end": 20, "label": "C:maj"],
                             ["start": 20, "end": 21.2, "label": "G:maj"],
                             ["start": 21.2, "end": 22.4, "label": "A:min"],
                             ["start": 22.4, "end": 24, "label": "F:maj"]]])
        let events = SheetModel.events(changes)
        for (time, chord) in [(20.2, "G"), (21.2, "Am"), (22.4, "F"), (23.2, "F")] {
            check(current(time) == 1 && events.first(where: { $0.contains(time) })?.display(transposedBy: 0) == chord,
                  "The held word remains sung while each independently timed chord changes")
        }
        check(current(20.1) == 1 && current(23.8) == 2 && current(19.2) == 0,
              "Forward and backward seeks resolve the sung word directly from time")

        var uncertain = words
        uncertain[0].estimated = true
        uncertain[2].estimated = true
        check(current(19.4, uncertain) == nil && current(23.9, uncertain) == nil,
              "Estimated prefixes and interpolated middle words never claim a precise sung highlight")
        check(current(20.2, uncertain) == 1 && current(24.3, uncertain) == 3,
              "An estimated neighbor does not suppress a healthy measured word")
        uncertain[1].end = nil
        uncertain[1].estimated = false
        check(current(20.2, uncertain) == nil && current(23.5, uncertain) == nil,
              "A measured onset without a vocal end cannot invent a held-word duration")
        let onsets = words.map { WordStamp(time: $0.time, text: $0.text) }
        check(current(19.4, onsets) == nil && current(27, onsets) == nil,
              "Onset-only lyrics never remain white across unknown vocal rests")
        var overlap = words
        overlap[1].end = 24.5
        overlap[2].estimated = true
        check(current(23.9, overlap) == nil && current(24.15, overlap) == nil,
              "An estimated following word blocks a stale overlapping earlier highlight")
        overlap[2].estimated = false
        check(current(23.9, overlap) == 2 && current(24.15, overlap) == nil,
              "A later measured word takes over, and ending it never relights an earlier word")

        for invalidEnd in [Double.nan, .infinity, 19.2, 19.1, 28] {
            let invalid = [WordStamp(time: 19.2, text: "Invalid", end: invalidEnd)]
            check(current(19.3, invalid) == nil, "Malformed or stretched durations do not light a word")
        }
        for invalidTime in [Double.nan, .infinity, -.infinity] {
            check(current(invalidTime) == nil, "A nonfinite playhead cannot light a word")
            check(current(19.3, [WordStamp(time: invalidTime, text: "Invalid", end: 20)]) == nil,
                  "A nonfinite word onset cannot light a word")
        }
        let inverted = [WordStamp(time: 18, text: "Before", end: 18.5),
                        WordStamp(time: 20, text: "Conflicting", end: 20.5),
                        WordStamp(time: 19, text: "Positions", end: 19.5),
                        WordStamp(time: 21, text: "After", end: 21.5)]
        check(current(19.2, inverted) == nil && current(20.2, inverted) == nil,
              "Neither side of a backwards word sequence receives a precise highlight")
        check(current(18.2, inverted) == 0 && current(21.2, inverted) == 3,
              "Healthy words outside a timestamp inversion retain their highlight")
        check(current(19.3, start: 20) == nil && current(19.3, end: 19.3) == nil,
              "A word cannot light outside its row's visible interval")
        check(current(19.3, end: 19.5) == 0 && current(19.5, end: 19.5) == nil,
              "A row boundary clips a measured word without discarding its earlier sounding portion")
        check(current(19.3, [], start: 0, end: 28) == nil
              && current(19.3, start: -1) == nil && current(19.3, start: .nan) == nil
              && current(19.3, start: 28, end: 0) == nil && current(19.3, end: .infinity) == nil,
              "Empty timing and invalid row bounds cannot manufacture a sung word")
    }

    @MainActor static func independentChordTimingTests() {
        let axis = [LyricPlayhead.Waypoint(time: 0, x: 0, line: CGRect(x: 0, y: 0, width: 100, height: 30)),
                    LyricPlayhead.Waypoint(time: 4, x: 100, line: CGRect(x: 0, y: 0, width: 100, height: 30))]
        check(LyricPlayhead.position(at: 2, along: axis, rtl: false, eased: false)?.x == 50,
              "The chord cursor moves steadily between timed changes instead of accelerating near the next lyric")
        check(LyricPlayhead.position(at: 4, along: axis, rtl: false, eased: false)?.x == 100,
              "The cursor reaches each chord exactly at its onset")
        let analysis = chart([
            ["start": 0, "end": 2, "label": "N"],
            ["start": 2, "end": 4, "label": "E:min"],
            ["start": 4, "end": 5.5, "label": "E:min7"],
            ["start": 5.5, "end": 6.8, "label": "D:min7"],
            ["start": 6.8, "end": 10, "label": "E:min7"],
            ["start": 10, "end": 20, "label": "A:maj"]])
        let words = [WordStamp(time: 4.2, text: "First", end: 4.8),
                     WordStamp(time: 7, text: "sample", end: 7.4),
                     WordStamp(time: 8, text: "phrase", end: 8.4)]
        let rows = SheetModel.build(analysis: analysis,
            lines: [LyricLine(time: 0, text: "First sample phrase", words: words)], duration: 20)
        let sung = rows.first { !$0.text.isEmpty }!
        check(sung.start == 4 && sung.chords.map(\.wordIndex) == [0, nil, 1],
              "Intro remains independent; close anticipation attaches, but a mid-rest change does not")
        check(rows.first?.chords.map(\.event.start) == [0, 2], "N.C. and the intro chord precede the words")
        check(rows.flatMap(\.chords).map(\.event) == SheetModel.events(analysis),
              "Separating intro, phrase and outro neither drops nor duplicates any event")
        let future = SheetModel.changes(SheetModel.events(analysis), from: 1, count: 8).first!
        check(future.start == 2 && !future.contains(1), "The first playable shape during N.C. is upcoming, not sounding")
        let damaged = LyricLine(time: 0, text: "First sample phrase", words: [
            WordStamp(time: 0, text: "First", end: 1), WordStamp(time: 1, text: "sample", end: 18),
            WordStamp(time: 18, text: "phrase", end: 19)])
        let guarded = SheetModel.completeWords(damaged, before: 20)!
        check(guarded.prefix(2).allSatisfy { $0.estimated == true && $0.end == nil } && guarded[2] == damaged.words![2],
              "A stretched intro cannot supply precise positions; its healthy suffix remains available")
        let fallback = SheetModel.build(analysis: analysis, lines: [damaged], duration: 20)
        check(fallback.first?.text == damaged.text && fallback.first?.chords.allSatisfy { $0.wordIndex == nil } == true,
              "Declining damaged word timing preserves the full lyric and independent chord changes")
        check(fallback.flatMap(\.chords).map(\.event) == SheetModel.events(analysis), "Fallback preserves the musical timeline")
        let boundary = SheetModel.build(analysis: chart([
            ["start": 0, "end": 2, "label": "C:maj"], ["start": 2, "end": 20, "label": "G:maj"]]),
            lines: [LyricLine(time: 1, text: "Sample phrase", words: [
                WordStamp(time: 1, text: "Sample", end: 2), WordStamp(time: 9, text: "phrase", end: 10)])], duration: 20)
        check(boundary.first { $0.start == 2 }?.isInstrumental == true,
              "A change exactly when the preceding word ends belongs to the rest")
        for onset in stride(from: 0.0, through: 18, by: 0.25) {
            let line = LyricLine(time: onset, text: "Sample phrase", words: [
                WordStamp(time: onset, text: "Sample", end: onset + 0.2),
                WordStamp(time: onset + 0.5, text: "phrase", end: onset + 1)])
            let shifted = SheetModel.build(analysis: analysis, lines: [line], duration: 20)
            check(shifted.flatMap(\.chords).map(\.event) == SheetModel.events(analysis),
                  "Events survive arbitrary vocal boundaries, including exact chord and word endpoints")
        }
    }

    @MainActor static func partialWordTimingTests() {
        let line = LyricLine(time: 0, text: "First second third last", words: [
            WordStamp(time: 1, text: "First", end: 2), WordStamp(time: 3, text: "second", end: 4),
            WordStamp(time: 2.5, text: "third", end: 3.5), WordStamp(time: 5, text: "last", end: 6)])
        check(SheetModel.usableWordIndices(line, before: 7) == [0, 3], "Both sides of a reversed sequence remain uncertain")
        let projected = SheetModel.completeWords(line, before: 7)!
        check(projected[0] == line.words![0] && projected[3] == line.words![3], "Healthy anchors retain their exact stamps")
        check(projected.map(\.text) == line.words!.map(\.text), "Projection never sorts, drops or rewrites lyric tokens")
        check(projected[1].estimated == true && projected[2].estimated == true && projected[1].end == nil && projected[2].end == nil,
              "Only explicitly approximate positions fill the uncertain region")
        check(zip(projected, projected.dropFirst()).allSatisfy { $0.time <= $1.time }, "Word highlighting receives an ordered display timeline")
        check(line.words![1].time == 3 && line.words![2].time == 2.5, "Source evidence stays unchanged")
        let crossing = LyricLine(time: 0, text: "First last", words: [
            WordStamp(time: 1, text: "First", end: 2), WordStamp(time: 5.02, text: "last", end: 6)])
        let bounded = SheetModel.completeWords(crossing, before: 5)!
        check(bounded[0] == crossing.words![0] && bounded[1].estimated == true && bounded[1].time < 5,
              "A small boundary conflict cannot discard an unrelated word anchor")
        let analysis: ChordAnalysis = decode(["source": "youtube", "audio_duration": 7,
            "chords": [["start": 0, "end": 1, "label": "N"], ["start": 1, "end": 3, "label": "C:maj"],
                       ["start": 3, "end": 5, "label": "G:maj"], ["start": 5, "end": 7, "label": "A:min"]]])
        let rows = SheetModel.build(analysis: analysis, lines: [line], duration: 7)
        let placed = rows.flatMap(\.chords)
        check(placed.map(\.event) == SheetModel.events(analysis), "Partial recovery keeps every musical event exactly once")
        check(placed.first { $0.event.start == 1 }?.wordIndex == 0 && placed.first { $0.event.start == 5 }?.wordIndex == 3,
              "Correct anchors survive on both sides of ambiguous words")
        check(placed.first { $0.event.start == 3 }?.wordIndex == nil, "An estimate never becomes a claimed chord anchor")
    }

    @MainActor static func estimatedWordTimingTests() {
        // Same mixed measured/interpolated timing as the reported split phrase.
        let analysis: ChordAnalysis = decode(["source": "youtube", "audio_duration": 46,
            "chords": [["start": 0, "end": 34.644, "label": "E:min7"],
                       ["start": 34.644, "end": 41.123, "label": "B:min7"],
                       ["start": 41.123, "end": 42.98, "label": "A:maj"],
                       ["start": 42.98, "end": 46, "label": "E:min7"]]])
        let line = LyricLine(time: 33.51, text: "We keep moving onward", words: [
            WordStamp(time: 33.51, text: "We", estimated: true),
            WordStamp(time: 37.2, text: "keep", end: 37.76),
            WordStamp(time: 37.76, text: "moving", end: 38.34),
            WordStamp(time: 41.65, text: "onward", estimated: true)])
        let rows = SheetModel.build(analysis: analysis, lines: [line], duration: 46)
        check(rows.filter { !$0.text.isEmpty }.map(\.text) == [line.text], "An estimated word cannot split off the end of a phrase")
        check(rows.last?.end == 46 && rows.last?.text == line.text, "Unknown vocal end cannot manufacture an instrumental tail")
        check(rows.last?.chords.allSatisfy { $0.wordIndex == nil } == true, "Estimated word onsets do not claim precise chord anchors")
        check(rows.flatMap(\.chords).map(\.event) == SheetModel.events(analysis), "Keeping a phrase intact preserves every event")
        for measured in [false, true] {
            for onset in stride(from: 3.0, through: 15.0, by: 0.5) {
                let words = [WordStamp(time: 1, text: "First", end: 2),
                             WordStamp(time: onset, text: "last", end: measured ? onset + 0.5 : nil, estimated: !measured)]
                let candidate = SheetModel.build(analysis: chart([["start": 0, "end": 2.5, "label": "C:maj"],
                    ["start": 2.5, "end": 20, "label": "G:maj"]]),
                    lines: [LyricLine(time: 1, text: "First last", words: words)], duration: 20)
                check(candidate.filter { !$0.text.isEmpty }.map(\.text).joined(separator: " ") == "First last", "Splitting never drops or duplicates words")
                check(candidate.flatMap(\.chords).map(\.event.start) == [0, 2.5], "Measured and estimated gaps preserve every chord once")
                if !measured { check(candidate.filter { !$0.text.isEmpty }.count == 1, "Estimated gaps always retain the full phrase") }
                if measured && onset >= 5 { check(candidate.filter { !$0.text.isEmpty }.count == 2, "A measured long rest still separates its chord change") }
            }
        }
        let unknown = LyricLine(time: 1, text: "Onsets only", words: [WordStamp(time: 1, text: "Onsets"), WordStamp(time: 9, text: "only")])
        let unknownRows = SheetModel.build(analysis: chart([["start": 0, "end": 3, "label": "C:maj"], ["start": 3, "end": 20, "label": "G:maj"]]), lines: [unknown], duration: 20)
        check(unknownRows.filter { !$0.text.isEmpty }.map(\.text) == [unknown.text], "Legacy onset-only lyrics do not prove silence")
        let stamped: WordStamp = decode(["time": 1, "text": "Estimate", "estimated": true, "end": 2])
        check(!stamped.hasMeasuredOnset && stamped.measuredEnd == nil, "Explicit estimated provenance wins over a supplied end")
    }

    @MainActor static func savedAlignmentRefreshTests() async throws {
        func response(estimated: Bool) -> SongStatus {
            var finalWord: [String: Any] = ["time": 9.0, "text": "phrase"]
            if estimated { finalWord["estimated"] = true }
            return decode(["job": ["state": "ready", "worker_online": true], "library_generation": "unchanged",
                "analysis": ["source": "youtube", "audio_duration": 20, "audio_sha256": "same-recording", "chart_revision": "same-chart",
                    "chords": [["start": 0, "end": 2.5, "label": "C:maj"],
                               ["start": 2.5, "end": 9.1, "label": "G:maj"],
                               ["start": 9.1, "end": 20, "label": "A:min"]]],
                "lyrics": ["synced": true, "matched": "aligned",
                    "lines": [["time": 1, "text": "Complete phrase", "words": [
                        ["time": 1, "end": 2, "text": "Complete"], finalWord]]]]])
        }
        var current = response(estimated: false)
        var analysisRequests = 0
        let sheet = SongSheetStore(song: SongDescriptor(trackID: "saved-alignment", title: "Sample", artist: "Test", duration: 20),
            service: .init(request: { _ in analysisRequests += 1; return current }, status: { _ in current },
                lyrics: { _ in nil }))
        let observation = Task { await sheet.observe() }
        try await waitFor { sheet.canPractice && sheet.rows.contains { $0.words?.count == 2 } }
        check(sheet.rows.flatMap(\.chords).first { $0.event.start == 9.1 }?.wordIndex == 1,
              "The fixture starts with the legacy cached word association")
        check(sheet.lyricsNote == "Lyrics timed from the recording", "The final healthy phrase uses the real recording boundary")
        let originalEvents = SheetModel.events(sheet.analysis)
        current = response(estimated: true)
        sheet.refresh()
        try await waitFor { sheet.rows.contains { $0.words?.last?.estimated == true } }
        check(sheet.rows.flatMap(\.chords).first { $0.event.start == 9.1 }?.wordIndex == nil,
              "A provenance-only lyric refresh rebuilds the visible placement")
        check(sheet.analysis?.chartRevision == "same-chart", "Lyric repair does not require a new chord revision")
        check(SheetModel.events(sheet.analysis) == originalEvents, "Refreshing estimated lyrics does not change musical events")
        check(sheet.rows.filter { !$0.text.isEmpty }.map(\.text) == ["Complete phrase"], "Cached lyric text remains complete")
        check(sheet.lyricsNote?.contains("approximate") == true, "The app explains estimated timing even without a server note")
        check(analysisRequests == 0, "Refreshing a saved song never re-requests analysis")
        observation.cancel()
        await observation.value
    }

    @MainActor static func lyricTimingRecoveryTests() async throws {
        let song = SongDescriptor(trackID: "vocal-timing", title: "Timing fixture", artist: "Test", duration: 32)
        let catalog: BackendClient.LyricsResult = decode(["synced": false, "lines": [
            ["time": 11.36, "text": "Opening words"], ["time": 13.41, "text": "Second phrase"],
            ["time": 15.8, "text": "Third phrase"], ["time": 17.71, "text": "Fourth phrase"]]])
        let measured: [[String: Any]] = [
            ["time": 19.2, "text": "Opening words", "words": [
                ["time": 19.2, "end": 19.7, "text": "Opening"], ["time": 20, "end": 20.4, "text": "words"]]],
            ["time": 21.5, "text": "Second phrase", "words": [
                ["time": 21.5, "end": 22, "text": "Second"], ["time": 22.1, "end": 22.8, "text": "phrase"]]],
            ["time": 24.2, "text": "Third phrase", "words": [
                ["time": 24.2, "end": 24.7, "text": "Third"], ["time": 24.8, "end": 25.4, "text": "phrase"]]],
            ["time": 27, "text": "Fourth phrase", "words": [
                ["time": 27, "end": 27.5, "text": "Fourth"], ["time": 27.6, "end": 28.2, "text": "phrase"]]]]
        func response(job: String? = nil, lines: [[String: Any]]? = nil) -> SongStatus {
            var payload: [String: Any] = ["job": ["state": "ready", "worker_online": true],
                "library_generation": "timing-library", "analysis": [
                    "source": "youtube", "audio_duration": 32, "audio_sha256": "same-audio", "chart_revision": "same-chords",
                    "chords": [["start": 0, "end": 8, "label": "C:maj"], ["start": 8, "end": 16, "label": "G:maj"],
                               ["start": 16, "end": 24, "label": "A:min"], ["start": 24, "end": 32, "label": "F:maj"]]]]
            if let job { payload["lyrics_job"] = ["state": job, "worker_online": true] }
            if let lines { payload["lyrics"] = ["synced": true, "matched": "aligned", "lines": lines] }
            return decode(payload)
        }
        check(response().lyricsJob == nil && response(job: "queued").lyricsJob?.state == "queued",
              "Lyrics jobs decode when supplied and remain optional for older servers")
        var current = response(job: "missing")
        var statusReads = 0, analysisRequests = 0, timingRequests = 0, lookupCount = 0, requestMode = 0
        var pending: CheckedContinuation<SongStatus, Never>?
        let sheet = SongSheetStore(song: song, service: .init(
            request: { _ in analysisRequests += 1; return current },
            status: { _ in statusReads += 1; return current },
            requestLyricTiming: { trackID in
                check(trackID == song.id, "Lyric timing requests target the open song")
                timingRequests += 1
                if requestMode == 0 { return await withCheckedContinuation { pending = $0 } }
                if requestMode == 1 { throw URLError(.timedOut) }
                current = response(job: "ready", lines: measured)
                return current
            }, lyrics: { _ in lookupCount += 1; return catalog },
            sleep: { _ in try await Task.sleep(for: .milliseconds(25)) }))
        let observation = Task { await sheet.observe() }
        try await waitFor { sheet.canPractice && !sheet.lyricsLoading }
        check(sheet.rows.filter { !$0.text.isEmpty }.map(\.text) == catalog.lines.map(\.text),
              "Unsynchronized lyrics remain complete and readable")
        check(SheetModel.activeRow(sheet.rows, at: 19)?.text == "Fourth phrase" && sheet.followingRow(at: 19) == nil,
              "Estimated early lines never auto-follow the fourth phrase when vocals have not begun")
        check(!sheet.lyricTimingIsSynced && !sheet.hasTimedLyricWords && !sheet.hasCompleteLyricTiming && sheet.needsLyricTiming,
              "Unsynchronized catalog timing offers explicit recovery without claiming measured words")
        check(sheet.needsChordPlaybackSummary, "Untimed lyrics keep independent current and next chord guidance available")
        check(sheet.lyricTimingActionTitle == "Sync lyrics", "A never-started lyric job offers Sync lyrics, not Retry")
        let original = sheet.analysis
        let originalEvents = SheetModel.events(sheet.analysis)
        let readsBeforeRefresh = statusReads, lookupsBeforeRefresh = lookupCount
        sheet.refresh()
        try await waitFor { statusReads > readsBeforeRefresh && lookupCount > lookupsBeforeRefresh && !sheet.lyricsLoading }
        check(timingRequests == 0 && analysisRequests == 0,
              "Opening and refreshing a song start neither lyric timing nor chord analysis")

        let requesting = Task { await sheet.requestLyricTiming() }
        try await waitFor { pending != nil }
        await sheet.requestLyricTiming()
        check(timingRequests == 1 && sheet.requestingLyricTiming && sheet.canPractice,
              "Repeated taps share one pending lyric request while chords remain playable")
        current = response(job: "queued")
        pending?.resume(returning: current); pending = nil
        await requesting.value
        try await waitFor { sheet.lyricsJob?.state == "queued" && !sheet.requestingLyricTiming }
        await sheet.requestLyricTiming()
        check(timingRequests == 1 && sheet.timingLyrics && sheet.analysis == original,
              "An already queued lyric job cannot be submitted twice or replace the chart")
        check(SheetModel.events(sheet.analysis) == originalEvents && sheet.followingRow(at: 19) == nil,
              "Queued timing leaves chord events exact and guessed vocals inactive")
        current = response(job: "failed")
        sheet.refresh()
        try await waitFor { sheet.lyricsJob?.state == "failed" && !sheet.lyricsLoading }
        check(!sheet.timingLyrics && sheet.needsLyricTiming && sheet.canPractice && sheet.analysis == original,
              "Failed lyric timing permits retry and retains the usable chord chart")
        check(sheet.lyricTimingActionTitle == "Retry", "An unsuccessful lyric job offers Retry")
        check(sheet.lyricTimingMessage?.contains("Your chords are still available") == true,
              "A failed timing job explains that the existing chords remain available")
        requestMode = 1
        await sheet.requestLyricTiming()
        check(timingRequests == 2 && sheet.lyricTimingError != nil && sheet.canPractice && sheet.analysis == original,
              "A failed retry request reports its error without losing lyrics or chords")
        for unconfirmedJob in [nil, "missing"] as [String?] {
            current = response(job: unconfirmedJob)
            let priorReads = statusReads
            sheet.refresh()
            try await waitFor { statusReads > priorReads && sheet.lyricsJob?.state == unconfirmedJob }
            check(sheet.lyricTimingError != nil,
                  "An older or missing-job status cannot erase an unconfirmed lyric request error")
        }
        current = response(job: "processing")
        sheet.refresh()
        try await waitFor { sheet.lyricsJob?.state == "processing" }
        check(sheet.lyricTimingError == nil && sheet.timingLyrics && sheet.analysis == original,
              "Polling clears a timed-out request error once the server confirms it accepted the lyric job")
        current = response(job: "failed")
        sheet.refresh()
        try await waitFor { sheet.lyricsJob?.state == "failed" }
        requestMode = 2
        await sheet.requestLyricTiming()
        try await waitFor { sheet.hasCompleteLyricTiming }
        check(timingRequests == 3 && analysisRequests == 0 && sheet.lyricTimingError == nil && !sheet.needsLyricTiming,
              "An explicit successful retry clears the error without reanalyzing chords")
        check(sheet.lyricTimingIsSynced && sheet.hasTimedLyricWords && sheet.analysis == original
              && SheetModel.events(sheet.analysis) == originalEvents,
              "Measured lyric replacement preserves the recording, chart revision, and every chord event")
        check(!sheet.needsChordPlaybackSummary, "Complete word timing does not need redundant chord guidance")
        check(sheet.followingRow(at: 19)?.text.isEmpty != false
              && sheet.followingRow(at: 19.2)?.text == "Opening words"
              && sheet.followingRow(at: 19.8) == nil,
              "Vocal follow starts at the measured 19.2-second onset and stops during the measured rest")
        current = response(job: "failed", lines: measured)
        sheet.refresh()
        try await waitFor { sheet.lyricsJob?.state == "failed" }
        check(sheet.lyricTimingMessage == nil, "Complete measured lyrics supersede an old unsuccessful job message")
        current = response(job: "ready", lines: [["time": 18, "text": "Estimated measured", "words": [
            ["time": 18, "end": 18.4, "text": "Estimated", "estimated": true],
            ["time": 20, "end": 21, "text": "measured"]]]])
        sheet.refresh()
        try await waitFor { sheet.rows.contains { $0.text == "Estimated measured" } }
        check(sheet.hasTimedLyricWords && !sheet.hasCompleteLyricTiming && sheet.needsLyricTiming
              && sheet.followingRow(at: 18.2) == nil && sheet.followingRow(at: 20.1)?.text == "Estimated measured",
              "Partial timing follows measured words while estimated prefixes remain inactive and recoverable")
        check(!sheet.needsChordPlaybackSummary, "A partly timed sheet stays a plain chord chart without a redundant first-chord summary")
        requestMode = 1
        await sheet.requestLyricTiming()
        check(sheet.lyricTimingError != nil, "A new uncertain request reports its own failure")
        current = response(lines: measured)
        sheet.refresh()
        try await waitFor { sheet.hasCompleteLyricTiming }
        check(sheet.lyricTimingError == nil && sheet.lyricsJob == nil && sheet.analysis == original,
              "Complete measured lyrics clear a stale request error even without the optional job status")
        observation.cancel(); await observation.value

        for cancelRequest in [false, true] {
            var delayed: CheckedContinuation<SongStatus, Never>?
            var requests = 0
            let protected = SongSheetStore(song: song, service: .init(status: { _ in response() },
                requestLyricTiming: { _ in
                    requests += 1
                    return await withCheckedContinuation { delayed = $0 }
                }, lyrics: { _ in catalog }, sleep: { _ in try await Task.sleep(for: .milliseconds(25)) }))
            var observing = Task { await protected.observe() }
            try await waitFor { protected.canPractice && !protected.lyricsLoading }
            let before = protected.analysis
            var publishedJobs: [String] = []
            let subscription = protected.$lyricsJob.sink { if let state = $0?.state { publishedJobs.append(state) } }
            let request = Task { await protected.requestLyricTiming() }
            try await waitFor { delayed != nil }
            if cancelRequest {
                request.cancel()
            } else {
                observing.cancel(); await observing.value
                observing = Task { await protected.observe() }
                await Task.yield()
            }
            delayed?.resume(returning: response(job: "queued", lines: measured)); delayed = nil
            await request.value
            check(requests == 1 && !publishedJobs.contains("queued") && protected.analysis == before
                  && !protected.hasTimedLyricWords && protected.lyricTimingError == nil,
                  cancelRequest ? "A cancelled timing request cannot publish its late response or erase the chart"
                    : "Leaving and reopening the song rejects an older in-flight lyric timing response")
            subscription.cancel()
            observing.cancel(); await observing.value
        }
    }

    @MainActor static func lyricCompletenessTests() {
        let analysis: ChordAnalysis = decode(["source": "youtube", "audio_duration": 45, "chords": [
            ["start": 0, "end": 30.16, "label": "E:maj"],
            ["start": 30.16, "end": 31.82, "label": "B:min"],
            ["start": 31.82, "end": 34.9, "label": "D:maj"],
            ["start": 34.9, "end": 36.74, "label": "F#:min"],
            ["start": 36.74, "end": 45, "label": "E:maj"]]])
        // Authored text with Horse to Water's observed phrase boundary pattern.
        let lines = [
            LyricLine(time: 26.8, text: "First phrase ends", words: [
                WordStamp(time: 26.8, text: "First", end: 28), WordStamp(time: 28, text: "phrase", end: 30),
                WordStamp(time: 30.16, text: "ends", end: 30.62)]),
            LyricLine(time: 31.88, text: "Next phrase starts", words: [
                WordStamp(time: 31.88, text: "Next", end: 33), WordStamp(time: 34.64, text: "phrase", end: 35.82),
                WordStamp(time: 36.13, text: "starts")]),
            LyricLine(time: 36.9, text: "Another phrase", words: [WordStamp(time: 36.9, text: "Another", end: 38),
                WordStamp(time: 39, text: "phrase", end: 40)])]
        let rows = SheetModel.build(analysis: analysis, lines: lines, duration: 45)
        let sung = rows.filter { !$0.text.isEmpty }
        check(sung[1].start == 31.82 && sung[1].chords.first?.event.chord?.display == "D"
              && sung[1].chords.first?.wordIndex == 0, "Anticipated D leads the next phrase instead of the previous last word")
        check(sung[2].start == 36.74 && sung[2].chords.first?.event.chord?.display == "E", "Short anticipation also handles an inferred word end")
        check(sung[0].chords.contains { $0.event.chord?.display == "Bm" }, "Change during the previous word stays with that word")
        check(rows.flatMap(\.chords).map(\.event) == SheetModel.events(analysis), "Phrase association preserves all chord events and timestamps exactly")
        var held = lines
        held[0] = LyricLine(time: 26.8, text: "Still singing", words: [WordStamp(time: 26.8, text: "Still", end: 29), WordStamp(time: 30, text: "singing", end: 31.87)])
        let heldRows = SheetModel.build(analysis: analysis, lines: held, duration: 45)
        check(heldRows.first { $0.text == "Still singing" }!.chords.contains { $0.event.chord?.display == "D" }, "Do not move a chord while the previous word still sounds")
        for words in [
            [WordStamp(time: 1, text: "keep")],
            [WordStamp(time: 1, text: "keep"), WordStamp(time: 9, text: "every"), WordStamp(time: 10, text: "word")],
            [WordStamp(time: 2, text: "keep"), WordStamp(time: 1, text: "every"), WordStamp(time: 3, text: "word")]
        ] {
            let incomplete = SheetModel.build(analysis: chart(), lines: [LyricLine(time: 1, text: "keep every word", words: words), LyricLine(time: 8, text: "next line", words: nil)], duration: 20)
            let first = incomplete.first { !$0.text.isEmpty }!
            check(first.text == "keep every word", "Incomplete or invalid timing never loses lyric words")
            if words.count == 1 {
                check(first.words == nil, "An incomplete word array cannot replace the complete lyric text")
            } else {
                check(first.words?.count == 3 && first.words!.contains { $0.estimated == true },
                      "Complete text retains its usable anchors and explicitly estimates the damaged positions")
            }
        }
        let shortIntro = SheetModel.build(analysis: chart(), lines: [LyricLine(time: 0.2, text: "Early entrance", words: nil)], duration: 20)
        check(shortIntro.flatMap(\.chords).map(\.event) == SheetModel.events(chart()), "A sub-second wordless gap cannot swallow its chord change")
        let shared = SheetModel.build(analysis: chart(), lines: [LyricLine(time: 2, text: "first line", words: nil), LyricLine(time: 2, text: "second line", words: nil)], duration: 20)
        check(shared.first { !$0.text.isEmpty }?.text == "first line second line", "Distinct lyrics sharing a timestamp both survive")
    }

    @MainActor static func lyricEntrancePresentationTests() {
        let analysis = chart([["start": 0, "end": 5, "label": "B:min"],
                              ["start": 5, "end": 7, "label": "E:maj"],
                              ["start": 7, "end": 12, "label": "F#:min"]])
        let line = LyricLine(time: 3, text: "Alpha bravo charlie", words: [
            WordStamp(time: 3, text: "Alpha", end: 3.5),
            WordStamp(time: 5, text: "bravo", end: 5.5),
            WordStamp(time: 7, text: "charlie", end: 8)])
        let rows = SheetModel.build(analysis: analysis, lines: [line], duration: 12)
        let vocal = rows.first { !$0.text.isEmpty }!
        check(vocal.vocalEntranceChord == SheetModel.events(analysis).first,
              "A reliable vocal entrance identifies the exact chord already ringing")
        check(vocal.vocalEntranceChord?.start == 0 && vocal.chords.map(\.event.start) == [5, 7],
              "Displaying the first chord cannot create an attack at the lyric onset")
        check(rows.flatMap(\.chords).map(\.event) == SheetModel.events(analysis),
              "Displaying the first chord keeps the complete scoring and playback sequence unchanged")
        check(!vocal.needsChordSequence && vocal.chords.map(\.wordIndex) == [1, 2],
              "Fully supported changes retain their word anchors")
        var uncertain = line.words!
        uncertain[0].estimated = true
        let estimated = SheetModel.build(analysis: analysis,
            lines: [LyricLine(time: 3, text: line.text, words: uncertain)], duration: 12).first { !$0.text.isEmpty }!
        check(estimated.vocalEntranceChord == nil, "An estimated first word cannot claim the first vocal chord")
        let lineOnly = SheetModel.build(analysis: analysis,
            lines: [LyricLine(time: 3, text: line.text, words: nil)], duration: 12).first { !$0.text.isEmpty }!
        check(lineOnly.vocalEntranceChord == vocal.held && lineOnly.needsChordSequence,
              "A synchronized line onset can identify its first chord without inventing word timing")
        uncertain[1].estimated = true
        let partial = SheetModel.build(analysis: analysis,
            lines: [LyricLine(time: 3, text: line.text, words: uncertain)], duration: 12).first { !$0.text.isEmpty }!
        check(partial.needsChordSequence && partial.chords.map(\.wordIndex) == [nil, 2],
              "Mixed timing presents one sequence while retaining reliable anchors in the model")
        check(rows.filter { $0.text.isEmpty }.allSatisfy { $0.vocalEntranceChord == nil },
              "Wordless rows cannot invent vocal entrances")
        check(vocal.beginsVocalPassage && vocal.displayChords.map(\.event.start) == [0, 5, 7]
              && vocal.displayChords.map(\.wordIndex) == [0, 1, 2],
              "The first ringing chord sits above the first word in the same chord line")
        check(vocal.displayChords.first?.event.display(transposedBy: 2) == "C#m"
              && vocal.displayChords.first?.event == vocal.held,
              "The first displayed chord transposes normally without changing its event identity")
        let onsetOnly = LyricLine(time: 3, text: line.text, words: line.words!.map {
            WordStamp(time: $0.time, text: $0.text, estimated: false)
        })
        let onsetRow = SheetModel.build(analysis: analysis, lines: [onsetOnly], duration: 12)
            .first { !$0.text.isEmpty }!
        check(onsetRow.vocalEntranceChord == vocal.held,
              "A measured onset can show the first chord without requiring a vocal end")

        // The screenshot's repeated phrases are ordinary lines in one passage.
        // Their old chord must not be repeated merely because text moved down.
        let repeating = chart([["start": 0, "end": 20, "label": "A:min"]])
        let repeatedLines = [LyricLine(time: 1, text: "Across the open valley", words: nil),
                             LyricLine(time: 4, text: "We follow every footstep", words: nil),
                             LyricLine(time: 7, text: "Across the open valley", words: nil)]
        let repeatedRows = SheetModel.build(analysis: repeating, lines: repeatedLines, duration: 20)
        let repeatedVocals = repeatedRows.filter { !$0.text.isEmpty }
        check(repeatedVocals.map(\.beginsVocalPassage) == [true, false, false],
              "Ordinary new lyric lines and repeated sentences do not begin another passage")
        check(repeatedVocals.map { $0.displayChords.count } == [1, 0, 0],
              "An initial line-only Am is readable once without repeating it above every sentence")
        check(repeatedRows.flatMap(\.chords).map(\.event) == SheetModel.events(repeating),
              "Repeated lyric lines never add another musical event")
        let readingRows = SheetModel.readingRows(repeatedRows)
        check(readingRows.first?.text == repeatedLines.first?.text
              && readingRows.flatMap(\.displayChords).filter { $0.event.start == 0 }.count == 1,
              "A lone chord immediately before the first lyric is displayed once above that lyric")
        check(repeatedRows.first?.chords.first?.event.start == 0,
              "Removing a duplicate from reading does not remove the original playback event")
        let openingPlaybackRow = SheetModel.activeRow(repeatedRows, at: 0.2)!
        check(SheetModel.readingRowID(openingPlaybackRow, in: repeatedRows) == repeatedVocals[0].id,
              "Seeking backward into a hidden short lead-in scrolls to the displayed opening lyric")
        check(SheetModel.readingRowID(repeatedVocals[0], in: repeatedRows) == repeatedVocals[0].id,
              "An existing lyric row retains its normal navigation identifier")
        let longIntro = SheetModel.build(analysis: repeating,
            lines: [LyricLine(time: 5, text: "Across the open valley", words: nil)], duration: 20)
        check(SheetModel.readingRows(longIntro).first?.isInstrumental == true,
              "A real long instrumental opening remains visible before the first lyric")
        check(SheetModel.readingRowID(longIntro[0], in: longIntro) == longIntro[0].id,
              "A visible instrumental introduction retains its own navigation destination")
        let splitIntroChart: ChordAnalysis = decode(["source": "youtube", "audio_duration": 25,
            "chords": [["start": 0, "end": 25, "label": "C:maj"]]])
        let splitIntro = SheetModel.build(analysis: splitIntroChart, lines: [
            LyricLine(time: 1, text: "", words: nil),
            LyricLine(time: 20, text: "Morning", words: [WordStamp(time: 20, text: "Morning", end: 21)])], duration: 25)
        check(splitIntro.first?.end == 1 && SheetModel.readingRows(splitIntro).first?.chords.first?.event.start == 0,
              "Blank catalog markers cannot hide a long sustained intro by splitting its first row short")
        let introChanges = chart([["start": 0, "end": 0.2, "label": "A:min"],
                                  ["start": 0.2, "end": 0.4, "label": "C:maj"],
                                  ["start": 0.4, "end": 20, "label": "G:maj"]])
        let compactIntro = SheetModel.build(analysis: introChanges,
            lines: [LyricLine(time: 0.6, text: "Across the open valley", words: nil)], duration: 20)
        check(SheetModel.readingRows(compactIntro).first?.chords.count == 3,
              "Even a short instrumental progression retains all of its changes")
        check(SheetModel.readingRows(rows).first?.chords.first?.event.start == 0,
              "The three-second intro in the measured fixture remains a visible musical opening")

        let atFirstWord = LyricLine(time: 5, text: "Alpha bravo charlie", words: [
            WordStamp(time: 5, text: "Alpha", end: 5.5),
            WordStamp(time: 6, text: "bravo", end: 6.5),
            WordStamp(time: 7, text: "charlie", end: 8)])
        let actualChange = SheetModel.build(analysis: analysis, lines: [atFirstWord], duration: 12)
            .first { !$0.text.isEmpty }!
        check(actualChange.held == nil && actualChange.displayChords.map(\.event.start) == [5, 7],
              "An actual first-word change is displayed once with no duplicate initial chord")
        check(Set(actualChange.displayChords.map(\.id)).count == actualChange.displayChords.count,
              "First-word rendering retains unique chord identities")

        let restedChart = chart([["start": 0, "end": 4, "label": "A:min"],
                                 ["start": 4, "end": 10, "label": "C:maj"],
                                 ["start": 10, "end": 20, "label": "G:maj"]])
        let restedLines = [LyricLine(time: 1, text: "Soft morning", words: [
            WordStamp(time: 1, text: "Soft", end: 1.5), WordStamp(time: 2, text: "morning", end: 3)]),
            LyricLine(time: 8, text: "Across the valley", words: [
                WordStamp(time: 8, text: "Across", end: 8.5), WordStamp(time: 9, text: "the", end: 9.5),
                WordStamp(time: 10, text: "valley", end: 11)])]
        let restedRows = SheetModel.build(analysis: restedChart, lines: restedLines, duration: 20)
        let restedVocals = restedRows.filter { !$0.text.isEmpty }
        check(restedVocals.map(\.beginsVocalPassage) == [true, true],
              "A measured long rest with an instrumental chord change begins a new passage")
        check(restedVocals[1].displayChords.map(\.event.start) == [4, 10],
              "The new passage starts with its ringing C followed by the actual G change")
        let quietRows = SheetModel.build(analysis: repeating, lines: restedLines, duration: 20)
        check(quietRows.filter { !$0.text.isEmpty }.map(\.beginsVocalPassage) == [true, false],
              "A long empty gap without any chord changes does not repeat the same chord")
        let shortRestLines = [restedLines[0], LyricLine(time: 5.5, text: "Across the valley", words: [
            WordStamp(time: 5.5, text: "Across", end: 6), WordStamp(time: 6.1, text: "the", end: 6.5),
            WordStamp(time: 7, text: "valley", end: 8)])]
        let shortRows = SheetModel.build(analysis: restedChart, lines: shortRestLines, duration: 20)
        check(shortRows.filter { !$0.text.isEmpty }.map(\.beginsVocalPassage) == [true, false],
              "A brief inter-line breath does not repeat the previous chord")
        for time in [0.0, 1, 3, 3.99, 4, 7.99, 8, 9.99, 10, 19.99, 20] {
            let original = SheetModel.activeEvent(SheetModel.events(restedChart), at: time)
            let retained = SheetModel.activeEvent(restedRows.flatMap(\.chords).map(\.event), at: time)
            check(retained == original, "Plain first-chord display leaves playback unchanged at \(time)")
        }
    }

    @MainActor static func modelTests() {
        let lines = [LyricLine(time: 2, text: "One two three", words: nil), LyricLine(time: 8, text: "Four five six", words: nil)]
        let rows = SheetModel.build(analysis: chart(), lines: lines, duration: 20)
        let sung = rows.filter { !$0.text.isEmpty }
        check(sung.count == 2, "Every lyric line is retained")
        check(rows.first?.chords.first?.event.chord?.display == "C", "A chord is shown where it starts")
        check(sung.allSatisfy { $0.chords.isEmpty && $0.held?.chord?.display == "C" }, "A held chord is never repeated on a later row")
        check(sung[1].end == 20 && sung[1].text == "Four five six", "Long lyric lines are not cut into blank eight-second rows")
        check(rows.first?.isInstrumental == true, "Intro has its own chord row")
        check(SheetModel.activeRow(rows, at: 9)?.id == 8, "Live selects current row by interval")
        check(SheetModel.activeRow(rows, at: 20) == nil, "Live does not hold the last lyric forever past song end")
        check(SheetModel.activeRow(rows, at: 3)?.id == 2, "Backward seek selects the earlier line")
        // Guitar shapes: every root with a known quality has one, and every fretted note is a chord tone.
        let openStrings = [4, 9, 2, 7, 11, 4]
        var shapes = 0
        for root in Chord.names {
            for suffix in ["", "m", "7", "maj7", "m7", "sus2", "sus4", "7sus4", "°", "°7", "ø7", "+", "6", "m6", "mMaj7", "9", "maj9", "m9", "11", "13"] {
                let name = root + suffix
                guard let chord = Chord(display: name), let tones = chord.pitchClasses else { fatalError("\(name) should parse") }
                guard let shape = ChordShapes.guitar(name) else { fatalError("\(name) has no shape") }
                shapes += 1
                check(shape.frets.count == 6 && shape.top <= 15, "\(name): six strings within the neck")
                let pressed = shape.frets.filter { $0 > 0 }
                check(pressed.allSatisfy { $0 >= shape.baseFret && $0 < shape.baseFret + 4 }, "\(name): fits the four-fret grid from \(shape.baseFret)")
                let sounding = zip(openStrings, shape.frets).compactMap { $1 < 0 ? nil : ($0 + $1) % 12 }
                check(sounding.allSatisfy { tones.contains($0) }, "\(name): \(shape.frets) plays only chord tones")
                check(sounding.contains(chord.root), "\(name): the root sounds")
            }
        }
        check(shapes == 240, "Twelve roots by twenty qualities")
        check(ChordShapes.guitar("C") == ChordShapes.GuitarShape([-1, 3, 2, 0, 1, 0]) && ChordShapes.guitar("Cm7/A#") == ChordShapes.guitar("Cm7"),
              "Open shapes stay the known ones; a slash chord plays its root position")
        check(ChordShapes.guitar("Cm") == ChordShapes.GuitarShape([-1, 3, 5, 5, 4, 3], base: 3) && ChordShapes.guitar("N.C.") == nil,
              "Cm is the A-form barre at the third fret; no chord, no shape")
        // The now-playing pill: the sounding chord and the next change of chord.
        let pillEvents = SheetModel.events(chart([["start": 0, "end": 2, "label": "C:maj"], ["start": 2, "end": 4, "label": "C:maj"],
                                                  ["start": 4, "end": 6, "label": "G:maj"], ["start": 6, "end": 8, "label": "A:min"]]))
        check(SheetModel.nextEvent(pillEvents, after: 1)?.start == 4, "A following event with the same chord is not the next chord")
        check(SheetModel.nextEvent(pillEvents, after: 5)?.start == 6 && SheetModel.nextEvent(pillEvents, after: 7) == nil,
              "The next chord after the sounding one; none at the end of the chart")
        check(SheetModel.changes(pillEvents, from: 1, count: 8).map(\.start) == [0, 4, 6] && SheetModel.changes(pillEvents, from: 3, count: 2).map(\.start) == [2, 4],
              "The rail starts at the sounding chord, merges repeats, and stops at the count")
        check(SheetModel.changes(pillEvents, from: 9, count: 8).isEmpty && SheetModel.changes(pillEvents, from: -1, count: 8).first?.start == 0,
              "Nothing past the chart; before it, the first chord to come")
        let withRest = SheetModel.events(chart([["start": 0, "end": 2, "label": "C:maj"], ["start": 2, "end": 4, "label": "N"], ["start": 4, "end": 6, "label": "G:maj"]]))
        check(SheetModel.changes(withRest, from: 2.5, count: 8).map(\.start) == [4], "A no-chord stretch is not a card")
        // A word-timed line with a long pause that carries chord changes splits around an instrumental.
        let paused = SheetModel.build(analysis: chart([["start": 0, "end": 2, "label": "C:maj"], ["start": 2, "end": 5, "label": "G:maj"],
                                                       ["start": 5, "end": 8, "label": "A:min"], ["start": 8, "end": 20, "label": "F:maj"]]),
            lines: [LyricLine(time: 1, text: "When when did it", words: [WordStamp(time: 1, text: "When", end: 1.4), WordStamp(time: 9, text: "when", end: 9.4),
                                                                        WordStamp(time: 9.5, text: "did", end: 9.8), WordStamp(time: 10, text: "it", end: 11)])], duration: 20)
        check(paused.map(\.text) == ["", "When", "", "when did it", "", ""], "The pause after the first word becomes its own row")
        check(paused[2].chords.map { $0.event.chord?.display } == ["G", "Am", "F"] && paused[1].chords.isEmpty,
              "Every change after the word ends stays in the instrumental pause")
        check(paused[3].start == 9 && paused[3].chords.isEmpty && paused[3].held?.chord?.display == "F",
              "A held chord is not a new attack at the next word")
        let lone = SheetModel.build(analysis: chart([["start": 0, "end": 3, "label": "C:maj"], ["start": 3, "end": 20, "label": "F:maj"]]),
            lines: [LyricLine(time: 1, text: "When when", words: [WordStamp(time: 1, text: "When", end: 2), WordStamp(time: 9, text: "when", end: 10)])], duration: 20)
        check(lone.filter { !$0.text.isEmpty }.count == 2 && lone.first { $0.isInstrumental && $0.start > 1 }?.chords.first?.event.start == 3, "Even a single change during a long rest belongs to the rest")
        let brief = SheetModel.build(analysis: chart([["start": 0, "end": 20, "label": "C:maj"]]),
            lines: [LyricLine(time: 1, text: "When when", words: [WordStamp(time: 1, text: "When"), WordStamp(time: 9, text: "when")])], duration: 20)
        check(brief.filter { !$0.text.isEmpty }.count == 1, "A pause with no chord change does not split the line")
        // Beat grid: 120 BPM, chord changes on beats 4, 8, 12 (index 3 mod 4 = 3) -> those are downbeats.
        let beats = (0..<32).map { Double($0) * 0.5 }
        let gridChart: ChordAnalysis = decode(["chords": [["start": 0, "end": 1.53, "label": "C:maj"], ["start": 1.53, "end": 3.48, "label": "G:maj"],
                                                          ["start": 3.48, "end": 5.5, "label": "A:min"], ["start": 5.5, "end": 16, "label": "F:maj"]],
                                               "source": "youtube", "audio_duration": 16, "tempo": ["bpm": 120, "beats": beats]])
        let grid = BeatGrid(tempo: gridChart.tempo, chords: gridChart.chords)!
        check(grid.period == 0.5 && grid.phase == 3, "Bar phase is the beat most chord changes land on")
        check(grid.snap(1.53) == 1.5 && grid.snap(3.48) == 3.5 && grid.snap(1.3) == 1.3, "Boundaries within a third of a beat snap to it; others stay")
        check(SheetModel.events(gridChart).map(\.start) == [0, 1.53, 3.48, 5.5], "Sheet events retain measured onsets instead of snapping to nearby beats")
        check(grid.beatInBar(at: 1.5) == 1 && grid.beatInBar(at: 2.9) == 3 && grid.beatInBar(at: 3.5) == 1, "Beat within the bar counts from the inferred downbeat")
        check(grid.downbeat(atOrBefore: 4.2) == 3.5 && grid.downbeat(atOrBefore: 0.2) == 1.5, "A take begins on the bar at or before its range, or the first bar")
        let clicks = grid.clicks(from: 1.5, to: 4)
        check(clicks.map(\.offset) == [0, 0.5, 1, 1.5, 2] && clicks.map(\.downbeat) == [true, false, false, false, true], "Clicks are offsets from the take start with beat 1 marked")
        check(BeatGrid(tempo: nil, chords: []) == nil && BeatGrid(tempo: decode(["bpm": 100, "beats": [0, 0.6, 1.2]], as: ChordAnalysis.Tempo.self), chords: []) == nil, "Too few beats give no grid")
        // Line timing cannot establish which word a chord belongs above.
        let lineTimed = SheetModel.build(analysis: chart([["start": 0, "end": 2.4, "label": "C:maj"], ["start": 2.4, "end": 20, "label": "G:maj"]]),
                                     lines: [LyricLine(time: 0, text: "one two three four", words: nil), LyricLine(time: 8, text: "next", words: nil)], duration: 20)
        check(SheetModel.sungDuration(words: 4, interval: 8) == 4.8 && SheetModel.sungDuration(words: 12, interval: 4) == 4,
              "Singing is estimated at half a second a word, at least 60% of the gap, never past it")
        check(lineTimed.first?.chords.map(\.wordIndex) == [nil, nil], "Line-only timing never invents a word for a chord")
        check(status("ready", saved: true).saved == true && status("ready").saved == nil, "The saved flag is optional in the status")
        // Timing calibration: spotify = scale * chart + offset, fitted from listened anchors.
        let delayedStart = TimingMap(offset: 1)
        let firstEvent = SheetModel.events(chart()).first!
        check(delayedStart.chartTime(0.5) == -0.5 && !firstEvent.contains(delayedStart.chartTime(0.5)),
              "Negative calibrated chart time stays negative so the first chord does not light early")
        check(delayedStart.chartTime(1) == 0 && firstEvent.contains(delayedStart.chartTime(1)),
              "The first chord lights exactly when calibrated Spotify progress reaches its onset")
        let one = TimingMap.fit([.init(chart: 12, spotify: 12.4)], chartAudioSha256: "h", spotifyTrackID: "one")!
        check(abs(one.offset - 0.4) < 1e-9 && one.scale == 1 && abs(one.chartTime(30.4) - 30) < 1e-9 && abs(one.spotifyTime(30) - 30.4) < 1e-9,
              "One anchor gives an offset at scale 1")
        let two = TimingMap.fit([.init(chart: 10, spotify: 10.3), .init(chart: 190, spotify: 192.1)], chartAudioSha256: "h", spotifyTrackID: "one")!
        check(abs(two.scale - 1.01) < 1e-9 && abs(two.offset - 0.2) < 1e-9, "Two anchors far apart give offset and scale")
        check(abs(two.chartTime(two.spotifyTime(100)) - 100) < 1e-9, "The map inverts exactly")
        let close = TimingMap.fit([.init(chart: 10, spotify: 10.3), .init(chart: 15, spotify: 15.1)], chartAudioSha256: nil, spotifyTrackID: nil)!
        check(close.scale == 1 && abs(close.offset - 0.2) < 1e-9, "Anchors under twenty seconds apart cannot measure speed: offset only")
        check(TimingMap.fit([], chartAudioSha256: nil, spotifyTrackID: nil) == nil, "No anchors, no map")
        check(one.matches(chartAudioSha256: "h", spotifyTrackID: "one") && !one.matches(chartAudioSha256: "changed", spotifyTrackID: "one")
              && !one.matches(chartAudioSha256: "h", spotifyTrackID: "relinked") && one.matches(chartAudioSha256: "h", spotifyTrackID: nil),
              "A calibration is tied to the chart and the Spotify recording it was made on")
        let decoded: TimingMap = decode(["offset": 0.25, "scale": 1.0, "anchors": [["chart": 1, "spotify": 1.25]], "verified_error": 0.05])
        check(decoded.offset == 0.25 && decoded.verifiedError == 0.05 && decoded.anchors.count == 1, "Calibration decodes from the server")
        let other = SongSheetStore(song: SongDescriptor(trackID: "x", title: "T", artist: "A", duration: 200), analysis: chart())
        check(other.editionGap == -180 && other.editionNote?.contains("180 s shorter") == true, "A chart from a different-length recording reports the gap")
        let same = SongSheetStore(song: SongDescriptor(trackID: "x", title: "T", artist: "A", duration: 20.5), analysis: chart())
        check(same.editionGap == nil && same.editionNote == nil, "Lengths within a second are the same edition")
        check(SongSheetStore(song: SongDescriptor(trackID: "x", title: "T", artist: "A"), analysis: chart()).editionGap == nil, "An unknown track length claims nothing")
        let pending = SheetModel.build(analysis: nil, lines: lines, duration: 20)
        check(pending.filter { !$0.text.isEmpty }.map(\.text) == lines.map(\.text), "Lyrics appear while analysis is pending")
        check(pending.allSatisfy { $0.chords.isEmpty }, "Pending analysis never invents chords")
        check(pending.filter(\.hasVisibleContent).allSatisfy { !$0.text.isEmpty }, "Missing analysis does not render blank timing gaps")
        let lyricsWithBreak = [LyricLine(time: 4, text: "First sample line", words: nil), LyricLine(time: 8, text: "", words: nil), LyricLine(time: 18, text: "Next sample line", words: nil)]
        let missingRows = SheetModel.build(analysis: nil, lines: lyricsWithBreak, duration: 24)
        check(missingRows.contains { $0.text.isEmpty && $0.kind == .uncovered }, "Unanalyzed timing gaps remain in the timeline")
        check(missingRows.filter(\.hasVisibleContent).map(\.text) == ["First sample line", "Next sample line"], "Only lyric content renders when analysis is unavailable")
        let preview = SheetModel.build(analysis: chart(preview: true), lines: lines, duration: 20)
        check(preview.filter { !$0.text.isEmpty }.count == 2 && preview.allSatisfy { $0.chords.isEmpty }, "Unknown-offset previews never masquerade as aligned chords")
        let blank = SheetModel.build(analysis: chart(), lines: [lines[0], LyricLine(time: 5, text: "", words: nil), lines[1]], duration: 20)
        check(blank.first { $0.start == 5 }?.isInstrumental == true, "Blank timed lyric creates a real instrumental break")
        check(blank.first { $0.start == 5 }?.chords.isEmpty == true && blank.first { $0.start == 5 }?.held != nil, "An instrumental break does not repeat the held chord")
        let changed = chart([["start": 0, "end": 5, "label": "C:maj"], ["start": 5, "end": 20, "label": "G:7"]])
        let changedRows = SheetModel.build(analysis: changed, lines: lines, duration: 20)
        check(changedRows.first { $0.start == 2 }?.chords.map { $0.event.chord?.display } == ["G7"], "Only the change inside the line is shown above it")
        check(changedRows.first { $0.start == 8 }?.chords.isEmpty == true && changedRows.first { $0.start == 8 }?.held?.chord?.display == "G7", "The later row knows its chord without repeating it")
        let gapped = chart([["start": 0, "end": 3, "label": "C:maj"], ["start": 10, "end": 20, "label": "G:maj"]])
        check(SheetModel.build(analysis: gapped, lines: lines, duration: 20).first { $0.start == 8 }?.chords.first?.event.start == 10, "A rest never extends an earlier chord")
        let badOrder = [lines[1], lines[0], lines[0], LyricLine(time: .nan, text: "invalid", words: nil)]
        let normalized = SheetModel.build(analysis: chart(), lines: badOrder, duration: 20)
        check(normalized.filter { !$0.text.isEmpty }.count == 2, "Unsorted duplicate timestamps cannot create invalid rows")
        check(normalized.allSatisfy { $0.end > $0.start }, "Every row has positive duration")
        let timed = [LyricLine(time: 2, text: "One phrase Two", words: [WordStamp(time: 2, text: "One phrase"), WordStamp(time: 5, text: "Two")])]
        check(SheetModel.build(analysis: changed, lines: timed, duration: 20).first { $0.start == 2 }?.chords.last?.wordIndex == 1, "Enhanced LRC uses timestamped token groups")
        let rtl = [LyricLine(time: 2, text: "שלום עולם", words: nil)]
        check(SheetModel.build(analysis: changed, lines: rtl, duration: 20).first { $0.start == 2 }?.text == "שלום עולם", "RTL words are preserved")
        let tail = SheetModel.build(analysis: changed, lines: lines, duration: 20.4)
        check(!tail.contains { $0.kind == .uncovered }, "A sub-second gap after the analyzed audio is not a pending row")
        check(SheetModel.build(analysis: changed, lines: [], duration: 30).contains { $0.kind == .uncovered }, "A real unanalyzed tail still shows as pending")
        check(SheetModel.build(analysis: changed, lines: [], duration: 20).allSatisfy { $0.isInstrumental }, "Without any lyrics, blank rows stay instrumental")
    }

    @MainActor static func documentTests() async throws {
        let song = SongDescriptor(trackID: "fixture", title: "Song", artist: "Band", album: "Album", duration: 20)
        var requests = 0, polls = 0
        let service = SongSheetStore.Service(request: { _ in requests += 1; return status("queued") },
        status: { _ in polls += 1; return status(polls < 3 ? "processing" : "ready", ready: polls >= 3) },
        lyrics: { _ in lyrics() }, sleep: { _ in try await Task.sleep(for: .milliseconds(25)) })
        let sheet = SongSheetStore(song: song, service: service)
        let first = Task { await sheet.observe() }
        let second = Task { await sheet.observe() }
        try await waitFor { !sheet.lyricsLoading }
        check(sheet.analysis == nil && sheet.rows.contains { !$0.text.isEmpty }, "Lyrics do not wait for recognition")
        try await waitFor { sheet.message == "Analyzing, about a minute" }
        check(!sheet.canPractice, "A pending chart is not ready for Live or Practice")
        try await waitFor { sheet.canPractice }
        check(requests == 0, "Opening a song never requests analysis")
        check(sheet.rows.first?.chords.isEmpty == false && sheet.rows.filter { !$0.text.isEmpty }.allSatisfy { $0.held != nil }, "Finished analysis fills existing rows automatically")
        first.cancel(); await first.value
        let previousPolls = polls
        try await waitFor { polls > previousPolls }
        check(sheet.canPractice, "Leaving one screen cannot stop another screen's document")
        second.cancel(); await second.value
        let stopped = polls
        try await Task.sleep(for: .milliseconds(70))
        check(polls == stopped, "Leaving the final screen cancels background polling")
        let resumed = Task { await sheet.observe() }
        try await waitFor { polls > stopped }
        check(requests == 0, "Reentry resumes polling without requesting analysis")
        resumed.cancel(); await resumed.value

        var missingPolls = 0, analyzeRequests = 0
        let unanalyzed = SongSheetStore(song: song, service: .init(request: { descriptor in
            analyzeRequests += 1
            check(descriptor.album == "Album" && descriptor.duration == 20, "Analyze sends real song duration and album")
            return status("queued")
        }, status: { _ in missingPolls += 1; return analyzeRequests == 0 ? status("missing") : status("ready", ready: true) },
        lyrics: { _ in lyrics() }, sleep: { _ in try await Task.sleep(for: .milliseconds(10)) }))
        let unanalyzedTask = Task { await unanalyzed.observe() }
        try await waitFor { missingPolls >= 3 }
        check(analyzeRequests == 0 && unanalyzed.message == "Not analyzed", "A song stays unanalyzed until the user asks")
        check(unanalyzed.actionTitle == "Analyze", "Every surface offers the same Analyze action")
        unanalyzed.refresh()
        let beforeRefresh = missingPolls
        try await waitFor { missingPolls > beforeRefresh }
        check(analyzeRequests == 0, "Pull to refresh never requests analysis")
        unanalyzed.retry()
        try await waitFor { unanalyzed.canPractice }
        check(analyzeRequests == 1, "Analyze requests the song exactly once")
        check(unanalyzed.actionTitle == nil, "A ready song has nothing to request")
        unanalyzedTask.cancel(); await unanalyzedTask.value

        let guitar = SongSheetStore(song: song, analysis: chart([["start": 0, "end": 20, "label": "F:maj"]]))
        check(guitar.shift == 0 && guitar.chordNote == nil, "Chords show as analyzed until the user changes them")
        guitar.capoMode = true
        check(guitar.capo == 1 && guitar.shift == -1, "Capo mode picks the fret that gives open shapes")
        check(guitar.rows.first?.chords.first?.event.display(transposedBy: guitar.shift) == "E", "Sheet, Live and Practice transpose from one shared shift")
        guitar.manualShift = 2
        check(guitar.shift == 1 && guitar.chordNote == "Capo 1 +2", "Manual shift stacks on the capo and is named in the header")

        let plain = SongSheetStore(song: song, service: .init(request: { _ in status("ready", ready: true) },
            status: { _ in status("ready", ready: true) },
            lyrics: { _ in decode(["lines": [["time": 1, "text": "Guessed one"], ["time": 18.6, "text": "Guessed two"]], "synced": false]) },
            sleep: { _ in try await Task.sleep(for: .milliseconds(25)) }))
        let plainTask = Task { await plain.observe() }
        try await waitFor { plain.canPractice && !plain.lyricsLoading }
        check(plain.rows.map(\.text).filter { !$0.isEmpty } == ["Guessed one", "Guessed two"], "Catalog lyrics without timing still become lyric rows")
        check(plain.rows.first { $0.text == "Guessed one" }?.held?.chord?.display == "C", "Estimated lines sit on the chord timeline")
        check(plain.lyricsNote == "Estimated lyric timing", "Estimated timing is labeled")
        check(SheetModel.activeRow(plain.rows, at: 5)?.held?.chord?.display == "C", "Chords still follow the recording")
        check(plain.usesIndependentLyrics && plain.untimedLyricRows.map(\.text) == ["Guessed one", "Guessed two"],
              "Unsynchronized lyrics remain intact in an independent presentation")
        check(plain.untimedLyricRows.allSatisfy { $0.chords.isEmpty && $0.held == nil && $0.words == nil },
              "Unsynchronized lyric rows cannot visually inherit timed chords or vocal-entrance cues")
        check(plain.independentChordTimeline.chords.map(\.event) == SheetModel.events(plain.analysis),
              "The separate chord timeline retains every original measured event")
        check([0.0, 1, 5, 18.6].allSatisfy { plain.followingRow(at: $0) == nil },
              "Estimated lyric positions and generated wordless spans cannot trigger auto-follow")
        plainTask.cancel(); await plainTask.value

        var lookups = 0
        let alignedStatus: SongStatus = decode([
            "job": ["state": "ready", "worker_online": true], "library_generation": "fresh",
            "analysis": ["chords": [["start": 0, "end": 3.5, "label": "C:maj"], ["start": 3.5, "end": 20, "label": "G:maj"]], "source": "youtube", "audio_duration": 20],
            "lyrics": ["synced": true, "matched": "aligned", "lines": [
                ["time": 3, "text": "Timed one", "words": [["time": 3, "text": "Timed"], ["time": 3.5, "text": "one"]]],
                ["time": 12, "text": "Timed two"]]]])
        let aligned = SongSheetStore(song: song, service: .init(request: { _ in alignedStatus },
            status: { _ in alignedStatus },
            lyrics: { _ in
                lookups += 1
                try await Task.sleep(for: .milliseconds(60))
                return decode(["lines": [["time": 1, "text": "Guessed one"]], "synced": false])
            },
            sleep: { _ in try await Task.sleep(for: .milliseconds(25)) }))
        let alignedTask = Task { await aligned.observe() }
        try await waitFor { aligned.canPractice && aligned.rows.contains { $0.text == "Timed one" } }
        try await Task.sleep(for: .milliseconds(120))
        check(aligned.rows.map(\.text).filter { !$0.isEmpty } == ["Timed one", "Timed two"], "Recording-timed lyrics replace the catalog lookup")
        check(aligned.rows.first { $0.text == "Timed one" }?.chords.map(\.wordIndex) == [1], "Word times from the recording place the change on its word")
        check(!aligned.rows.contains { $0.text == "Guessed one" } && !aligned.lyricsLoading, "A late catalog result cannot overwrite recording-timed lyrics")
        alignedTask.cancel(); await alignedTask.value

        var resetPolls = 0
        let resetting = SongSheetStore(song: song, service: .init(request: { _ in status("ready", ready: true) },
            status: { _ in resetPolls += 1; return status("missing", epoch: "after-reset") },
            lyrics: { _ in lyrics() }, sleep: { _ in try await Task.sleep(for: .milliseconds(25)) }))
        let resetTask = Task { await resetting.observe() }
        try await waitFor { resetting.state == "missing" }
        check(resetting.message == "Not analyzed", "A cleared song reads as not analyzed")
        check(resetting.analysis == nil && resetting.rows.allSatisfy { $0.chords.isEmpty }, "Reset removes old charts from an already open view")
        check(!resetting.canPractice, "A cleared reference cannot start practice")
        resetTask.cancel(); await resetTask.value

        var attempts = 0
        let recovering = SongSheetStore(song: song, service: .init(status: { _ in
            attempts += 1
            if attempts == 1 { throw URLError(.timedOut) }
            return status("ready", ready: true)
        }, lyrics: { _ in lyrics() }, sleep: { _ in try await Task.sleep(for: .milliseconds(10)) }))
        let recovery = Task { await recovering.observe() }
        try await waitFor { recovering.canPractice }
        check(attempts >= 2 && recovering.state == "ready", "A failed initial status read recovers in place")  // the poll keeps going after recovery
        recovery.cancel(); await recovery.value
    }

    @MainActor static func loadedChartRecoveryTests() async throws {
        let song = SongDescriptor(trackID: "loaded", title: "Song", artist: "Band", duration: 20)
        var mode = 0, polls = 0, requests = 0
        let sheet = SongSheetStore(song: song, service: .init(
            request: { _ in requests += 1; return status("queued") },
            status: { _ in
                polls += 1
                if mode == 1 { throw URLError(.notConnectedToInternet) }
                if mode == 2 { return status("missing", epoch: "cleared") }
                return status("ready", ready: true)
            }, lyrics: { _ in lyrics() },
            sleep: { _ in try await Task.sleep(for: .milliseconds(10)) }))
        let observing = Task { await sheet.observe() }
        try await waitFor { sheet.canPractice && !sheet.lyricsLoading }
        let originalChords = sheet.rows.flatMap(\.chords).map(\.event)
        let originalText = sheet.rows.map(\.text)
        sheet.manualShift = 2
        mode = 1
        try await waitFor { sheet.state == "connection" }
        check(sheet.canPractice, "A loaded full chart remains usable through a status timeout")
        check(sheet.rows.flatMap(\.chords).map(\.event) == originalChords && sheet.rows.map(\.text) == originalText
              && sheet.manualShift == 2,
              "Connection loss retains chord rows, transposition")
        check(sheet.actionTitle == "Reconnect", "Connection recovery never offers misleading reanalysis")
        let beforeRetry = polls
        sheet.retry()
        try await waitFor { polls > beforeRetry }
        check(requests == 0 && sheet.canPractice, "Reconnect reads status without reanalyzing or disabling the loaded chart")
        mode = 0
        try await waitFor { sheet.state == "ready" }
        check(sheet.message.isEmpty && sheet.canPractice, "Automatic reconnection clears its notice without resetting the chart")
        mode = 2
        try await waitFor { sheet.state == "missing" }
        check(sheet.analysis == nil && !sheet.canPractice, "An explicit server reset still removes the loaded reference")
        observing.cancel(); await observing.value

        let preview = SongSheetStore(song: song, analysis: chart(preview: true), service: .init(
            status: { _ in throw URLError(.timedOut) }, lyrics: { _ in nil },
            sleep: { _ in try await Task.sleep(for: .milliseconds(10)) }))
        let previewTask = Task { await preview.observe() }
        try await waitFor { preview.state == "connection" }
        check(!preview.canPractice, "Connection recovery cannot promote an unknown-offset preview to a full chart")
        previewTask.cancel(); await previewTask.value
    }

    @MainActor static func recordingLyricsRecoveryTests() async throws {
        for match in ["aligned", "transcribed"] {
            let song = SongDescriptor(trackID: "lyrics-\(match)", title: "Song", artist: "Band", duration: 20)
            var revision = 0, polls = 0, lookups = 0
            let sheet = SongSheetStore(song: song, service: .init(status: { _ in
                polls += 1
                var response: [String: Any] = [
                    "job": ["state": "ready", "worker_online": true], "library_generation": "same-library",
                    "analysis": ["chords": [["start": 0, "end": 20, "label": "C:maj"]],
                                 "source": "youtube", "audio_duration": 20,
                                 "audio_sha256": revision == 0 ? "original-audio" : "replacement-audio"]]
                if revision == 0 {
                    response["lyrics"] = ["synced": true, "matched": match,
                        "lines": [["time": 3, "text": "Recording words", "words": [
                            ["time": 3, "text": "Recording"], ["time": 3.8, "text": "words"]]]]]
                }
                return decode(response)
            }, lyrics: { _ in lookups += 1; return lyrics("Catalog words") },
            sleep: { _ in try await Task.sleep(for: .milliseconds(10)) }))
            let observing = Task { await sheet.observe() }
            try await waitFor { sheet.rows.contains { $0.text == "Recording words" } && !sheet.lyricsLoading }
            let previousLookups = lookups, previousPolls = polls
            sheet.refresh()
            try await waitFor { polls >= previousPolls + 3 }
            check(lookups == previousLookups, "Refreshing \(match) lyrics never starts a lower-quality catalog replacement")
            check(sheet.rows.contains { $0.text == "Recording words" } && !sheet.lyricsLoading,
                  "Recording word timing survives refresh for \(match)")
            revision = 1
            try await waitFor { sheet.rows.contains { $0.text == "Catalog words" } }
            check(lookups > previousLookups && !sheet.rows.contains { $0.text == "Recording words" },
                  "A different analyzed recording invalidates old \(match) word timing and loads a fallback")
            observing.cancel(); await observing.value
        }
    }

    @MainActor static func cancellationTests() async throws {
        var pending: CheckedContinuation<SongStatus, Never>?
        var pendingLyrics: CheckedContinuation<BackendClient.LyricsResult?, Never>?
        var statusReads = 0, lyricCalls = 0
        let sheet = SongSheetStore(song: SongDescriptor(trackID: "canceled", title: "Song", artist: "Band", duration: 20),
            service: .init(status: { _ in
                statusReads += 1
                if statusReads == 1 { return await withCheckedContinuation { pending = $0 } }
                return status("ready", ready: true)
            }, lyrics: { _ in
                lyricCalls += 1
                if lyricCalls == 1 { return await withCheckedContinuation { pendingLyrics = $0 } }
                return lyrics("Fresh words")
            }, sleep: { _ in try await Task.sleep(for: .milliseconds(30)) }))
        let abandoned = Task { await sheet.observe() }
        try await waitFor { pending != nil && pendingLyrics != nil }
        abandoned.cancel(); await abandoned.value
        let replacement = Task { await sheet.observe() }
        try await waitFor { sheet.canPractice && !sheet.lyricsLoading }
        pending?.resume(returning: status("queued"))
        pendingLyrics?.resume(returning: lyrics("Stale words"))
        try await Task.sleep(for: .milliseconds(30))
        check(sheet.canPractice, "Canceled analysis cannot overwrite a replacement result")
        check(sheet.rows.contains { $0.text == "Fresh words" }, "Canceled lyrics cannot overwrite reentry")
        check(!sheet.rows.contains { $0.text == "Stale words" }, "Old lyric data is discarded")
        replacement.cancel(); await replacement.value
    }

    @MainActor static func playbackTests() async throws {
        var instant = ContinuousClock.now
        var phase = 0
        var requested = 0
        let provider: (Track) -> SongSheetStore = { track in
            SongSheetStore(song: SongDescriptor(track: track), service: .init(
                request: { _ in requested += 1; return status("ready", ready: true) }, status: { _ in status("ready", ready: true) },
                lyrics: { _ in lyrics() }, sleep: { _ in try await Task.sleep(for: .seconds(10)) }))
        }
        let player = SpotifyNowPlaying(service: .init(current: {
            switch phase {
            case 0: return playback()
            case 1: return playback(milliseconds: nil, playing: false)
            case 2: return playback(milliseconds: nil)
            case 3: return playback(id: "two", milliseconds: 1000)
            default: return nil
            }
        }, seek: { _ in }, sleep: { _ in try await Task.sleep(for: .milliseconds(30)) }),
        now: { instant }, sheetProvider: provider)
        player.resume()
        try await waitFor { player.playing != nil }
        check(player.livePosition() == 12, "Initial Spotify position is used immediately")
        instant = instant.advanced(by: .seconds(10))
        check(player.livePosition() == 22, "Playhead moves smoothly between network polls")
        phase = 1
        try await waitFor { player.playing?.isPlaying == false }
        instant = instant.advanced(by: .seconds(5))
        check(player.livePosition() == 22, "A pause without progress freezes the current estimate instead of jumping backward")
        check(player.playbackNote == "Playback paused", "Pause has an explicit state")
        phase = 2
        try await waitFor { player.playing?.isPlaying == true }
        instant = instant.advanced(by: .seconds(3))
        check(player.livePosition() == 25, "Resume without progress advances from the paused estimate")
        phase = 3
        try await waitFor { player.playing?.track.id == "two" }
        check(player.livePosition() == 1, "Song changes replace the old clock without leaving Live")
        phase = 4
        try await waitFor { player.playing == nil }
        check(player.livePosition() == nil && player.analysis == nil, "No playback clears the old song and chart")
        player.reset()

        var late: CheckedContinuation<SpotifyAPI.CurrentlyPlaying?, Never>?
        let canceled = SpotifyNowPlaying(service: .init(current: { await withCheckedContinuation { late = $0 } }, seek: { _ in }), sheetProvider: provider)
        canceled.resume()
        try await waitFor { late != nil }
        canceled.reset()
        late?.resume(returning: playback())
        try await Task.sleep(for: .milliseconds(20))
        check(canceled.playing == nil, "A canceled network response cannot restore a signed-out song")

        var nativeMetadata = false
        let metadata = SpotifyNowPlaying(service: .init(current: {
            if nativeMetadata { return playback(playing: false, deviceID: SpotifyNativeSession.device.id!) }
            return decode(["progress_ms": 12000, "is_playing": true, "item": [
                "id": "one", "name": "Song", "artists": [["name": "Band"]], "duration_ms": 200000,
                "external_ids": ["isrc": "saved-isrc"],
                "album": ["name": "Album", "images": [["url": "https://example.test/album.jpg"]]]]])
        }, seek: { _ in }, sleep: { _ in try await Task.sleep(for: .milliseconds(10)) }), sheetProvider: provider)
        metadata.resume()
        try await waitFor { metadata.playing?.track.album.artworkURL != nil }
        nativeMetadata = true
        try await waitFor { metadata.playing?.isPlaying == false }
        check(metadata.playing?.track.album.artworkURL?.absoluteString == "https://example.test/album.jpg" &&
              metadata.playing?.track.isrc == "saved-isrc", "Native playback updates preserve existing album artwork and recording metadata")
        metadata.reset()

        var delays: [Double] = []
        var calls = 0
        let limited = SpotifyNowPlaying(service: .init(current: {
            calls += 1
            if calls == 1 { throw NSError(domain: "SpotifyAPI", code: 429, userInfo: ["retryAfter": 37.0]) }
            return playback()
        }, seek: { _ in }, sleep: { value in delays.append(value); try await Task.sleep(for: .milliseconds(20)) }), sheetProvider: provider)
        limited.resume()
        try await waitFor { limited.playing != nil }
        check(delays.first == 37, "Retry-After is respected instead of hammering Spotify")
        check(limited.connectionMessage == nil, "A recovered Spotify request clears the error in place")
        limited.reset()

        // Practice "Play from Spotify": start the track, then trust only Spotify's own report.
        var device: (offset: Double, playing: Bool)?
        var started: [(String, Double)] = []
        var playFailure: Int?
        var stall = false
        func dev(_ id: String, _ name: String, _ type: String, active: Bool = false) -> SpotifyAPI.Device {
            decode(["id": id, "name": name, "type": type, "is_active": active])
        }
        let laptop = dev("mac", "Ilie's MacBook", "Computer", active: true)
        let phone = dev("phone", "iPhone", "Smartphone")
        var listed: [SpotifyAPI.Device] = [laptop, phone]
        var targeted: [String?] = []
        let starter = SpotifyNowPlaying(service: .init(
            current: { device.map { playback(id: "one", milliseconds: Int($0.offset * 1000), playing: $0.playing, deviceID: targeted.last.flatMap { $0 } ?? "phone") } },
            seek: { _ in },
            play: { id, at, deviceID in
                targeted.append(deviceID)
                if let playFailure { throw NSError(domain: "SpotifyAPI", code: playFailure, userInfo: ["reason": "PREMIUM_REQUIRED"]) }
                started.append((id, at)); device = (at, !stall)
            },
            devices: { listed },
            sleep: { _ in try await Task.sleep(for: .milliseconds(10)) }), sheetProvider: provider)
        starter.resume()
        try await starter.play(trackID: "one", at: 30)
        check(started.count == 1 && started[0].0 == "one" && started[0].1 == 30, "Play starts the requested track at the requested position")
        check(targeted == ["phone"] && starter.playbackDevice == "iPhone", "The phone is targeted even when a laptop is Spotify's active device")
        check(starter.playing?.track.id == "one" && starter.playing?.isPlaying == true, "Play returns only after Spotify reports the track playing")
        check(abs((starter.livePosition() ?? -1) - 30) < 1, "The playhead after play comes from Spotify's report")
        listed = [laptop]
        do { try await starter.play(trackID: "one", at: 0); fatalError("A laptop-only account must not start there") }
        catch let error as SpotifyNowPlaying.PlayError { check(error == .onlyElsewhere("Ilie's MacBook"), "Playback is never sent where the headphones are not") }
        listed = []
        do { try await starter.play(trackID: "one", at: 0); fatalError("No devices must fail") }
        catch let error as SpotifyNowPlaying.PlayError { check(error == .noDevice, "No listed phone means open Spotify on it first") }
        listed = [dev("p2", "Old phone", "Smartphone"), dev("p1", "iPhone", "Smartphone", active: true)]
        try await starter.play(trackID: "one", at: 8)
        check(targeted.last == "p1", "Among phones, the active one wins")
        listed = [laptop, phone]
        playFailure = 403
        do { try await starter.play(trackID: "one", at: 0); fatalError("A Premium failure must surface") }
        catch let error as SpotifyNowPlaying.PlayError { check(error == .premiumRequired, "Only an explicit Premium reason is presented as Premium required") }
        playFailure = nil
        stall = true
        do { try await starter.play(trackID: "one", at: 5); fatalError("An unconfirmed start must fail") }
        catch let error as SpotifyNowPlaying.PlayError { check(error == .notConfirmed, "Play never assumes playback Spotify did not report") }
        check(started.count == 3, "Failed requests never reach Spotify twice")
        starter.reset()
        var casualTrack = "one"
        var casualPosition = 17.0
        var casualPlaying = false
        var casualStarts: [(String, Double)] = []
        let casual = SpotifyNowPlaying(service: .init(
            current: { playback(id: casualTrack, milliseconds: Int(casualPosition * 1000), playing: casualPlaying, deviceID: "phone") },
            seek: { _ in fatalError("Play along must not seek an already playing song") },
            play: { id, at, _ in
                casualStarts.append((id, at))
                casualTrack = id; casualPosition = at; casualPlaying = true
            }, devices: { [phone] }, sleep: { _ in try await Task.sleep(for: .milliseconds(10)) }), sheetProvider: provider)
        casual.resume()
        try await waitFor { casual.playing != nil }
        try await casual.playAlong(trackID: "one")
        check(casualStarts.count == 1 && casualStarts[0].1 == 17, "Casual playing resumes the paused song at its position")
        try await casual.playAlong(trackID: "one")
        check(casualStarts.count == 1, "Casual playing does not restart a song already playing")
        try await casual.playAlong(trackID: "two")
        check(casualStarts.count == 2 && casualStarts[1].0 == "two" && casualStarts[1].1 == 0,
              "Selecting a different song starts it from the beginning")
        casual.reset()
        var returnedPosition = 23.0
        var returnedStarts = 0
        let returned = SpotifyNowPlaying(service: .init(
            current: { playback(milliseconds: Int(returnedPosition * 1000), deviceID: "phone") },
            seek: { _ in fatalError("An already playing handoff must not seek") },
            play: { _, at, _ in returnedStarts += 1; returnedPosition = at },
            devices: { [phone] }, sleep: { _ in try await Task.sleep(for: .milliseconds(10)) }), sheetProvider: provider)
        // The native handoff starts audio while Chordlyze's poller is stopped.
        // Its cached `playing` value is nil until the first fresh read.
        try await returned.playAlong(trackID: "one")
        check(returnedStarts == 0 && returnedPosition == 23,
              "Returning from Spotify must adopt the playing song without restarting its queue")
        returned.reset()
        try await returnedHandoffTests(phone: phone, provider: provider)
        let unconnected = SpotifyNowPlaying(sheetProvider: provider)
        do { try await unconnected.playAlong(trackID: "one"); fatalError("Signed out cannot start playback") }
        catch let error as SpotifyNowPlaying.PlayError { check(error == .notConnected, "Play without a Spotify session is an explicit error") }

        check(requested == 0, "Playing a song never requests its analysis")
        try await liveFlowTests()
    }

    @MainActor static func returnedHandoffTests(phone: SpotifyAPI.Device,
                                               provider: @escaping (Track) -> SongSheetStore) async throws {
        var position = 23.0, track = "one", deviceID = "phone"
        var isPlaying = true, failRead = false
        var starts: [(String, Double)] = [], seeks: [Double] = []
        var pending: CheckedContinuation<SpotifyAPI.CurrentlyPlaying?, Never>?
        var holdRead = false
        let player = SpotifyNowPlaying(service: .init(current: {
            if holdRead { return await withCheckedContinuation { pending = $0 } }
            if failRead { throw URLError(.timedOut) }
            return playback(id: track, milliseconds: Int(position * 1000), playing: isPlaying, deviceID: deviceID)
        }, seek: { _ in fatalError("Seek must target the selected phone") }, play: { id, at, selected in
            starts.append((id, at)); track = id; position = at; isPlaying = true; deviceID = selected!
        }, devices: { [phone] }, seekOnDevice: { at, selected in
            check(selected == phone.id, "A handoff resume seek stays on the selected phone")
            seeks.append(at); position = at
        }, sleep: { _ in try await Task.sleep(for: .seconds(60)) }), sheetProvider: provider)
        try await player.playAlong(trackID: "one", resumingAt: 17)
        check(starts.isEmpty && seeks.isEmpty && abs((player.livePosition() ?? 0) - 23) < 1,
              "An old requested position never rewinds music already started in Spotify")
        // The cached player still says playing while the fresh source is paused.
        isPlaying = false; position = 27
        try await player.playAlong(trackID: "one")
        check(starts.count == 1 && starts[0].1 == 27,
              "A stale playing cache cannot suppress resuming Spotify's actual paused position")
        position = 4
        try await player.playAlong(trackID: "one", resumingAt: 42)
        check(starts.count == 1 && seeks == [42],
              "A cold handoff restores a later resume point by seeking without recreating the queue")
        deviceID = "mac"
        try await player.playAlong(trackID: "one")
        check(starts.count == 2 && starts[1].1 == 0 && deviceID == "phone",
              "The same song on another device is not mistaken for the requested phone")
        failRead = true
        do { try await player.playAlong(trackID: "one"); fatalError("An unreadable handoff must fail") }
        catch let error as SpotifyNowPlaying.PlayError {
            check(error == .connectionLost && starts.count == 2,
                  "An unavailable playback read never causes a speculative replay")
        }
        player.stop()
        failRead = false; holdRead = true
        let canceled = Task { try await player.playAlong(trackID: "two") }
        try await waitFor { pending != nil }
        canceled.cancel()
        holdRead = false
        pending?.resume(returning: playback())
        do { try await canceled.value; fatalError("A canceled handoff must throw") } catch is CancellationError { }
        check(starts.count == 2, "Canceling during a fresh handoff read cannot later start audio")
        player.reset()
    }

    @MainActor static func spotifyNativeSessionTests() async throws {
        let driver = NativeSpotifyFixture()
        let session = SpotifyNativeSession(transport: driver, sleep: { seconds in
            if seconds == 10 { try await Task.sleep(for: .seconds(60)) }
            else { await Task.yield() }
        })
        var completions: [String?] = []
        session.sceneChanged(active: false)
        session.authorize(token: "fixture", completion: { completions.append($0) })
        check(driver.tokens.isEmpty && completions.isEmpty,
              "An authorization callback in background waits for an active native connection")
        session.sceneChanged(active: true)
        session.sceneChanged(active: true)
        session.reconnect()
        check(driver.tokens == ["fixture"] && !session.isConnected && completions.isEmpty,
              "Authorization installs its token once and does not claim connection before the SDK delegate")
        driver.connected()
        check(session.isConnected && completions.count == 1 && completions[0] == nil,
              "Only a connected SDK delegate completes the Spotify handoff")

        var webReads = 0, webWrites = 0
        let web = SpotifyNowPlaying.Service(current: { webReads += 1; return playback(id: "stale-web", deviceID: "mac") },
            seek: { _ in webWrites += 1 }, play: { _, _, id in
                check(id != SpotifyNativeSession.device.id, "The native identity never reaches a Spotify Web API write")
                webWrites += 1
            }, devices: { [] })
        let service = session.service(fallback: web)
        let current = try await service.current()
        let devices = try await service.devices()
        check(current?.item?.id == "one" && devices.map(\.id) == [SpotifyNativeSession.device.id] && webReads == 0,
              "A connected handoff reads and targets this phone instead of a stale Spotify Connect device")
        driver.sample = playback(playing: false, deviceID: SpotifyNativeSession.device.id!)
        let paused = try await service.current()
        check(paused?.isPlaying == false, "The phone's real pause state reaches the chart controller")
        driver.sample = nil
        let empty = try await service.current()
        check(empty == nil && webReads == 0, "An empty native player cannot fall through to another device's song")
        let webConfirmation = try await service.currentOnDevice!("mac")
        check(webConfirmation?.item?.id == "stale-web" && webReads == 1,
              "A Web API command keeps its confirmation source when native connection appears mid-command")

        try await service.play("one", 0, SpotifyNativeSession.device.id)
        check(driver.plays == ["one"] && webWrites == 0, "Native playback never sends a second command through the Web API")
        var readNumber = 0
        driver.read = {
            readNumber += 1
            return playback(id: readNumber < 3 ? "old-song" : "two", deviceID: SpotifyNativeSession.device.id!)
        }
        try await service.play("two", 31, SpotifyNativeSession.device.id)
        check(readNumber == 3 && driver.seeks == [31], "Native play waits for the new track before seeking its resume point")
        driver.read = { playback(id: "old-song", deviceID: SpotifyNativeSession.device.id!) }
        let previousReads = driver.reads
        do { try await service.play("missing", 9, SpotifyNativeSession.device.id); fatalError("A missing track change must fail") }
        catch let error as SpotifyNowPlaying.PlayError {
            check(error == .notConfirmed && driver.reads - previousReads == 12 && driver.seeks == [31],
                  "An accepted play that never changes songs fails within bounded reads without seeking the old song")
        }
        var pending: CheckedContinuation<SpotifyAPI.CurrentlyPlaying?, Never>?
        driver.read = { await withCheckedContinuation { pending = $0 } }
        let canceled = Task { try await service.play("two", 45, SpotifyNativeSession.device.id) }
        try await waitFor { pending != nil }
        canceled.cancel()
        pending?.resume(returning: playback(id: "two", deviceID: SpotifyNativeSession.device.id!))
        do { try await canceled.value; fatalError("A canceled native play must throw") } catch is CancellationError { }
        check(driver.seeks == [31], "Canceling native confirmation prevents a delayed seek")

        let originalConnection = driver.connections[0]
        session.sceneChanged(active: false)
        check(!session.isConnected && !driver.isConnected, "Backgrounding disconnects the App Remote transport")
        for control in [0, 1, 2] {
            do {
                if control == 0 { try await service.play("one", 0, SpotifyNativeSession.device.id) }
                else if control == 1 { try await service.seekOnDevice!(10, SpotifyNativeSession.device.id) }
                else { _ = try await service.currentOnDevice!(SpotifyNativeSession.device.id) }
                fatalError("An unavailable selected native device must fail")
            } catch let error as SpotifyNowPlaying.PlayError {
                check(error == .connectionLost && webWrites == 0 && webReads == 1,
                      "Disconnecting cannot redirect native controls or confirmation to an account device")
            }
        }
        session.sceneChanged(active: true)
        check(driver.tokens == ["fixture", "fixture"], "Foreground reconnect reuses the native token without new authorization")
        originalConnection(.success(()))
        check(!session.isConnected && completions.count == 1, "An old connection callback cannot revive a later attempt")
        driver.connected()
        check(session.isConnected && completions.count == 1, "Foreground reconnect does not repeat the original continuation")

        session.authorize(token: "replacement", completion: { completions.append($0) })
        let abandoned = driver.connections.last!
        session.reset()
        abandoned(.success(()))
        session.sceneChanged(active: false)
        session.sceneChanged(active: true)
        check(!session.isConnected && driver.tokens.count == 3 && completions.count == 1,
              "Logout or cancellation removes credentials and rejects late native connections")

        let failingDriver = NativeSpotifyFixture()
        let failing = SpotifyNativeSession(transport: failingDriver)
        var failure: String?
        failing.authorize(token: "fixture", completion: { failure = $0 })
        failingDriver.connections.last?(.failure(URLError(.cannotConnectToHost)))
        check(failure != nil && !failing.isConnected && !failingDriver.isConnected,
              "A failed SDK connection never reports the phone ready")
        failing.reset()

        let slowDriver = NativeSpotifyFixture()
        let slow = SpotifyNativeSession(transport: slowDriver, sleep: { _ in try await Task.sleep(for: .milliseconds(10)) })
        var timedOut = false
        slow.authorize(token: "fixture", completion: { timedOut = $0 != nil })
        try await waitFor { timedOut }
        check(!slow.isConnected && !slowDriver.isConnected, "An SDK connection with no delegate result has a finite failure path")
        slow.reset()
    }

    @MainActor static func playbackReliabilityTests() async throws {
        let provider: (Track) -> SongSheetStore = { track in
            SongSheetStore(song: SongDescriptor(track: track), service: .init(
                request: { _ in status("ready", ready: true) }, status: { _ in status("ready", ready: true) },
                lyrics: { _ in lyrics() }, sleep: { _ in try await Task.sleep(for: .seconds(60)) }))
        }
        func phone(_ id: String = "phone", active: Bool = true, restricted: Bool = false) -> SpotifyAPI.Device {
            decode(["id": id, "name": id, "type": "Smartphone", "is_active": active, "is_restricted": restricted])
        }
        let fastSleep: (Double) async throws -> Void = { _ in try await Task.sleep(for: .milliseconds(5)) }

        // A slow successful command used to fail: its playhead was already
        // more than three seconds past the requested start when we read it.
        var instant = ContinuousClock.now
        var started = false
        let delayed = SpotifyNowPlaying(service: .init(current: { started ? playback(milliseconds: 36000) : nil }, seek: { _ in },
            play: { _, _, _ in started = true; instant = instant.advanced(by: .seconds(6)) },
            devices: { [phone()] }, sleep: fastSleep), now: { instant }, sheetProvider: provider)
        try await delayed.play(trackID: "one", at: 30)
        check(delayed.playing?.isPlaying == true && delayed.livePosition() == 36,
              "A slow acknowledged start confirms using elapsed playback time")
        delayed.reset()

        // Cancellation while looking for a device must not launch Spotify later.
        var discovery: CheckedContinuation<[SpotifyAPI.Device], Never>?
        var sent = 0
        let cancel = SpotifyNowPlaying(service: .init(current: { nil }, seek: { _ in },
            play: { _, _, _ in sent += 1 }, devices: { await withCheckedContinuation { discovery = $0 } }, sleep: fastSleep), sheetProvider: provider)
        let start = Task { try await cancel.play(trackID: "one", at: 0) }
        try await waitFor { discovery != nil }
        start.cancel()
        discovery?.resume(returning: [phone()])
        do { try await start.value; fatalError("Canceled startup must throw") } catch is CancellationError { }
        check(sent == 0 && !cancel.isControlling, "Cancel before device discovery completes prevents a delayed play command")
        cancel.reset()

        // A response already in flight must not rewind a newly confirmed seek.
        var reads = 0
        var oldPoll: CheckedContinuation<SpotifyAPI.CurrentlyPlaying?, Never>?
        var destination = 12000
        let seeking = SpotifyNowPlaying(service: .init(current: {
            reads += 1
            if reads == 2 { return await withCheckedContinuation { oldPoll = $0 } }
            return playback(milliseconds: destination)
        }, seek: { destination = Int($0 * 1000) }, sleep: fastSleep), sheetProvider: provider)
        seeking.resume()
        try await waitFor { oldPoll != nil }
        let jumped = await seeking.seek(to: 45)
        check(jumped && abs((seeking.livePosition() ?? 0) - 45) < 1, "Seek succeeds only with a matching Spotify report")
        oldPoll?.resume(returning: playback(milliseconds: 12000))
        try await Task.sleep(for: .milliseconds(20))
        check(abs((seeking.livePosition() ?? 0) - 45) < 1, "Pre-seek polling cannot rewind the confirmed playhead")
        seeking.reset()

        // Spotify can acknowledge a seek before its state endpoint catches up.
        var staleReads = 0
        var wroteSeek = false
        var checkedBeforeConfirm = false
        var confirmed: SpotifyNowPlaying!
        confirmed = SpotifyNowPlaying(service: .init(current: {
            if wroteSeek {
                staleReads += 1
                if staleReads <= 3 {
                    checkedBeforeConfirm = (confirmed.livePosition() ?? 0) < 20
                    return playback(milliseconds: 12000)
                }
                return playback(milliseconds: 60000)
            }
            return playback()
        }, seek: { _ in wroteSeek = true }, sleep: fastSleep), sheetProvider: provider)
        confirmed.resume()
        try await waitFor { confirmed.playing != nil }
        let caughtUp = await confirmed.seek(to: 60)
        check(caughtUp && checkedBeforeConfirm && staleReads >= 4,
              "Acknowledgement plus stale state does not invent a successful seek")
        confirmed.reset()

        // Three rapid taps produce the in-flight command and the newest intent,
        // with no overlapping HTTP writes and no middle-position replay.
        var pendingSeek: CheckedContinuation<Void, Never>?
        var writes: [Double] = []
        var position = 12.0
        var writing = false
        var overlapped = false
        let rapid = SpotifyNowPlaying(service: .init(current: { playback(milliseconds: Int(position * 1000)) }, seek: { target in
            if writing { overlapped = true }
            writing = true
            writes.append(target)
            if writes.count == 1 { await withCheckedContinuation { pendingSeek = $0 } }
            position = target
            writing = false
        }, sleep: fastSleep), sheetProvider: provider)
        rapid.resume()
        try await waitFor { rapid.playing != nil }
        let first = Task { await rapid.seek(to: 30) }
        try await waitFor { pendingSeek != nil }
        let second = Task { await rapid.seek(to: 60) }
        try await Task.sleep(for: .milliseconds(20))
        let third = Task { await rapid.seek(to: 90) }
        try await Task.sleep(for: .milliseconds(20))
        rapid.resume(); rapid.resume() // navigation must not interrupt the command
        pendingSeek?.resume()
        _ = await (first.value, second.value, third.value)
        check(writes == [30, 90] && !overlapped, "Rapid seek taps coalesce and never overlap Spotify commands")
        check(abs((rapid.livePosition() ?? 0) - 90) < 1 && rapid.controlMessage == nil,
              "Repeated resume calls preserve the latest command and its confirmed state")
        rapid.reset()

        // Stop/reset while a command is on the wire must not resurrect its state.
        var pendingPlay: CheckedContinuation<Void, Never>?
        var confirmationReads = 0
        let background = SpotifyNowPlaying(service: .init(current: { confirmationReads += 1; return playback(milliseconds: 0) },
            seek: { _ in }, play: { _, _, _ in await withCheckedContinuation { pendingPlay = $0 } },
            devices: { [phone()] }, sleep: fastSleep), sheetProvider: provider)
        let oldStart = Task { try await background.play(trackID: "one", at: 0) }
        try await waitFor { pendingPlay != nil }
        background.reset()
        pendingPlay?.resume()
        do { try await oldStart.value; fatalError("A reset command must be canceled") } catch is CancellationError { }
        check(background.playing == nil && confirmationReads == 0 && !background.isControlling,
              "A command completing after sign-out cannot restart polling or publish playback")

        // 403 is not necessarily an expired token, and must not kill live follow.
        var forbiddenReads = 0
        let forbidden = SpotifyNowPlaying(service: .init(current: {
            forbiddenReads += 1
            if forbiddenReads == 1 { throw NSError(domain: "SpotifyAPI", code: 403) }
            return playback()
        }, seek: { _ in throw NSError(domain: "SpotifyAPI", code: 403) }, sleep: fastSleep), sheetProvider: provider)
        forbidden.resume()
        try await waitFor { forbidden.playing != nil }
        check(!forbidden.needsReauth && forbiddenReads >= 2, "A temporary 403 doesn't permanently stop live tracking")
        let refused = await forbidden.seek(to: 90)
        check(!refused && forbidden.controlMessage == SpotifyNowPlaying.PlayError.forbidden.localizedDescription,
              "An unspecified 403 is not mislabeled as a Premium requirement")
        forbidden.reset()

        // Same-song playback on another device does not confirm the phone start.
        var wrong: [String: Any] = ["progress_ms": 0, "is_playing": true, "item": [
            "id": "one", "name": "Song", "artists": [["name": "Band"]], "album": ["name": "Album"]]]
        wrong["device"] = ["id": "laptop", "name": "Laptop", "type": "Computer", "is_active": true]
        let wrongDevice = SpotifyNowPlaying(service: .init(current: { decode(wrong) }, seek: { _ in },
            play: { _, _, _ in }, devices: { [phone()] }, sleep: fastSleep), sheetProvider: provider)
        do { try await wrongDevice.play(trackID: "one", at: 0); fatalError("Wrong device must not confirm") }
        catch let error as SpotifyNowPlaying.PlayError { check(error == .notConfirmed, "Startup checks the device as well as the song") }

        do { _ = try SpotifyNowPlaying.practiceDevice([phone("a", active: false), phone("b", active: false)]); fatalError("Ambiguous phones") }
        catch let error as SpotifyNowPlaying.PlayError { check(error == .ambiguousDevice, "Several inactive phones require a choice in Spotify") }
        do { _ = try SpotifyNowPlaying.practiceDevice([phone(restricted: true)]); fatalError("Restricted phone") }
        catch let error as SpotifyNowPlaying.PlayError { check(error == .restrictedDevice, "A restricted phone is never sent a command") }
        for invalid in [Double.nan, Double.infinity, Double(Int.max)] {
            do { try await wrongDevice.play(trackID: "one", at: invalid); fatalError("Invalid position") }
            catch let error as SpotifyNowPlaying.PlayError { check(error == .invalidPosition, "Invalid positions never trap during millisecond conversion") }
        }
        wrongDevice.reset()

        // The server can apply a command even if its HTTP response is lost.
        var uncertainWrites = 0
        var uncertainPosition = 12.0
        let uncertain = SpotifyNowPlaying(service: .init(current: { playback(milliseconds: Int(uncertainPosition * 1000)) },
            seek: { uncertainWrites += 1; uncertainPosition = $0; throw URLError(.networkConnectionLost) },
            play: { _, at, _ in uncertainWrites += 1; uncertainPosition = at; throw URLError(.timedOut) },
            devices: { [phone()] }, sleep: fastSleep), sheetProvider: provider)
        try await uncertain.play(trackID: "one", at: 30)
        check(uncertainWrites == 1 && abs((uncertain.livePosition() ?? 0) - 30) < 1,
              "A timed-out play that reached Spotify is confirmed without a duplicate command")
        let uncertainSeek = await uncertain.seek(to: 60)
        check(uncertainSeek && uncertainWrites == 2 && abs((uncertain.livePosition() ?? 0) - 60) < 1,
              "A lost seek response is reconciled from playback state without replaying the seek")
        uncertain.reset()

        var limitedWrites = 0
        var cooldown: CheckedContinuation<Void, Error>?
        let controlLimited = SpotifyNowPlaying(service: .init(current: { playback() }, seek: { _ in
            limitedWrites += 1
            throw NSError(domain: "SpotifyAPI", code: 429, userInfo: ["retryAfter": 31.0])
        }, sleep: { seconds in
            if seconds > 20 { try await withCheckedThrowingContinuation { cooldown = $0 } }
            else { try await Task.sleep(for: .milliseconds(5)) }
        }), sheetProvider: provider)
        controlLimited.resume()
        try await waitFor { controlLimited.playing != nil }
        let limitedFirst = await controlLimited.seek(to: 30)
        let limitedSecond = await controlLimited.seek(to: 60)
        check(!limitedFirst && !limitedSecond && limitedWrites == 1 && controlLimited.controlMessage?.contains("31") == true,
              "A control rate limit blocks repeated taps and preserves the retry countdown")
        try await waitFor { cooldown != nil }
        controlLimited.reset()
        cooldown?.resume(throwing: CancellationError())

        var seekTarget: Double?
        var seekDevice: String?
        var boundedPosition = 12.0
        let bounded = SpotifyNowPlaying(service: .init(current: { playback(milliseconds: Int(boundedPosition * 1000), playing: false) },
            seek: { _ in fatalError("Must use targeted seek") }, seekOnDevice: { value, id in
                seekTarget = value; seekDevice = id; boundedPosition = value
            }, sleep: fastSleep), sheetProvider: provider)
        bounded.resume()
        try await waitFor { bounded.playing != nil }
        let endSeek = await bounded.seek(to: 200)
        check(endSeek && seekTarget == 199.999 && seekDevice == "phone" && bounded.playing?.isPlaying == false,
              "Seeking to the end targets the observed device, preserves pause, and cannot advance to the next track")
        bounded.reset()

    }

    @MainActor static func spotifyDeviceRecoveryTests() async throws {
        let phone: SpotifyAPI.Device = decode(["id": "phone", "name": "This phone", "type": "Smartphone", "is_active": true])
        let laptop: SpotifyAPI.Device = decode(["id": "mac", "name": "MacBook", "type": "Computer", "is_active": true])
        var discoveries = 0
        var writes = 0
        let player = SpotifyNowPlaying(service: .init(current: { playback(milliseconds: 0) }, seek: { _ in writes += 1 },
            play: { _, _, _ in writes += 1 }, devices: {
                discoveries += 1
                return discoveries < 3 ? [laptop] : [phone]
            }, sleep: { _ in try await Task.sleep(for: .milliseconds(1)) }))
        let ready = try await player.checkPracticeDevice()
        check(ready.id == "phone" && discoveries == 3 && writes == 0,
              "A newly advertised phone is found with bounded discovery retries and no playback writes")
        player.reset()

        var checksRun = 0
        let recovery = SpotifyDeviceRecovery(checkDevice: { checksRun += 1; return phone })
        let opening = recovery.openRequested()
        recovery.openCompleted(true, attempt: opening)
        recovery.sceneChanged(active: true)
        check(recovery.state == .waitingForSpotify && checksRun == 0,
              "A redundant active notification before leaving doesn't trigger a device check")
        recovery.sceneChanged(active: false)
        recovery.sceneChanged(active: true)
        check(recovery.state == .checking, "Returning from Spotify schedules a read-only device check")
        await recovery.check()
        check(recovery.state == .ready("This phone") && checksRun == 1,
              "A successful handoff offers explicit retry instead of starting playback or recording")
        recovery.sceneChanged(active: true)
        await recovery.check()
        check(checksRun == 1, "Repeated foreground events don't repeatedly query devices")

        let failedOpen = recovery.openRequested()
        recovery.openCompleted(false, attempt: failedOpen)
        if case .failed(let message) = recovery.state {
            check(message.contains("Install") && message.contains("same account"), "Missing Spotify has an actionable installation/account message")
        } else { fatalError("Failed URL open must be visible") }
        let staleOpen = recovery.openRequested()
        recovery.cancel()
        recovery.openCompleted(false, attempt: staleOpen)
        check(recovery.state == .idle, "A late open callback cannot restore a dismissed recovery screen")

        var pending: CheckedContinuation<SpotifyAPI.Device, Never>?
        let canceled = SpotifyDeviceRecovery(checkDevice: { await withCheckedContinuation { pending = $0 } })
        canceled.retry()
        let task = Task { await canceled.check() }
        try await waitFor { pending != nil }
        canceled.sceneChanged(active: false)
        pending?.resume(returning: phone)
        await task.value
        check(canceled.state == .idle, "Backgrounding invalidates an in-flight recovery check")

        let unavailable = SpotifyDeviceRecovery(checkDevice: { throw SpotifyNowPlaying.PlayError.onlyElsewhere("MacBook") })
        unavailable.retry()
        await unavailable.check()
        check(unavailable.state == .failed(SpotifyNowPlaying.PlayError.onlyElsewhere("MacBook").localizedDescription),
              "A still-unavailable phone leaves the actual error and retry path visible")
        check(SpotifyNowPlaying.PlayError.noDevice.needsDeviceRecovery &&
              SpotifyNowPlaying.PlayError.onlyElsewhere("Mac").needsDeviceRecovery &&
              SpotifyNowPlaying.PlayError.ambiguousDevice.needsDeviceRecovery &&
              SpotifyNowPlaying.PlayError.restrictedDevice.needsDeviceRecovery &&
              !SpotifyNowPlaying.PlayError.premiumRequired.needsDeviceRecovery &&
              !SpotifyNowPlaying.PlayError.notConnected.needsDeviceRecovery,
              "Device handoff is offered only for device availability errors")
    }

    @MainActor static func spotifyStartupTests() async throws {
        let phone: SpotifyAPI.Device = decode(["id": "phone", "name": "This phone", "type": "Smartphone", "is_active": true])
        let laptop: SpotifyAPI.Device = decode(["id": "mac", "name": "MacBook", "type": "Computer", "is_active": true])
        var checksRun = 0
        let recovery = SpotifyDeviceRecovery(checkDevice: { checksRun += 1; return phone })
        let attempt = recovery.openRequested(expectsAuthorization: true)
        recovery.openCompleted(true, attempt: attempt)
        recovery.sceneChanged(active: false)
        recovery.sceneChanged(active: true)
        await recovery.check()
        check(recovery.state == .awaitingAuthorization && checksRun == 0,
              "Installed/opened does not authorize playback; foreground waits for the SDK callback")
        recovery.authorizationCompleted(error: nil, attempt: attempt)
        check(recovery.state == .checking, "Authorization arriving after foreground begins discovery")
        await recovery.check()
        check(recovery.state == .ready("This phone") && checksRun == 1,
              "A successful app handoff checks exactly once and sends no playback command")
        recovery.authorizationCompleted(error: "late duplicate", attempt: attempt)
        check(recovery.state == .ready("This phone"), "Duplicate callbacks cannot overwrite a completed handoff")

        let early = recovery.openRequested(expectsAuthorization: true)
        recovery.sceneChanged(active: false)
        recovery.authorizationCompleted(error: nil, attempt: early)
        check(recovery.state == .waitingForSpotify, "Authorization in background waits for active before checking")
        recovery.sceneChanged(active: true)
        await recovery.check()
        check(recovery.state == .ready("This phone") && checksRun == 2,
              "Callback-before-foreground is handled without losing the pending song")

        let denied = recovery.openRequested(expectsAuthorization: true)
        recovery.sceneChanged(active: false)
        recovery.authorizationCompleted(error: "Permission denied", attempt: denied)
        recovery.sceneChanged(active: true)
        await recovery.check()
        check(recovery.state == .failed("Permission denied") && checksRun == 2,
              "Denied authorization never schedules automatic continuation")

        let missing = recovery.openRequested(expectsAuthorization: true)
        recovery.openCompleted(false, attempt: missing)
        if case .failed(let message) = recovery.state {
            check(message.contains("Install"), "A missing native app has an actionable installation error")
        } else { fatalError("Missing app must fail") }

        let dismissed = recovery.openRequested(expectsAuthorization: true)
        recovery.sceneChanged(active: false)
        recovery.sceneChanged(active: true)
        recovery.authorizationTimedOut(attempt: dismissed)
        if case .failed = recovery.state {
            check(checksRun == 2, "Returning without authorizing stops waiting with no automatic playback")
        } else { fatalError("Manual return cannot spin forever") }
        let newer = recovery.openRequested(expectsAuthorization: true)
        recovery.sceneChanged(active: false)
        recovery.sceneChanged(active: true)
        recovery.authorizationTimedOut(attempt: dismissed)
        recovery.authorizationCompleted(error: nil, attempt: dismissed)
        check(recovery.state == .awaitingAuthorization, "Old callbacks and deadlines cannot alter a newer handoff")
        recovery.cancel()
        recovery.authorizationCompleted(error: nil, attempt: newer)
        check(recovery.state == .idle, "Leaving the song or signing out invalidates the pending handoff")

        var pending: CheckedContinuation<SpotifyAPI.Device, Never>?
        var concurrentChecks = 0
        let concurrent = SpotifyDeviceRecovery(checkDevice: {
            concurrentChecks += 1
            return await withCheckedContinuation { pending = $0 }
        })
        concurrent.retry()
        let firstCheck = Task { await concurrent.check() }
        try await waitFor { pending != nil }
        await concurrent.check()
        check(concurrentChecks == 1, "Repeated lifecycle events share one device check")
        concurrent.cancel()
        pending?.resume(returning: phone)
        await firstCheck.value
        check(concurrent.state == .idle, "Late discovery cannot revive a canceled startup")

        var discoveries = 0
        var writes = 0
        var instant = ContinuousClock.now
        let player = SpotifyNowPlaying(service: .init(current: { nil }, seek: { _ in writes += 1 },
            play: { _, _, _ in writes += 1 }, devices: {
                discoveries += 1
                return discoveries < 7 ? [laptop] : [phone]
            }, sleep: { instant = instant.advanced(by: .seconds($0)) }), now: { instant })
        let available = try await player.checkPracticeDevice(afterAppSwitch: true)
        check(available.id == "phone" && discoveries == 7 && writes == 0,
              "Cold Spotify startup allows delayed advertisement beyond the old three reads, without playing on the Mac")
        player.reset()

        discoveries = 0
        let unavailable = SpotifyNowPlaying(service: .init(current: { nil }, seek: { _ in }, devices: {
            discoveries += 1
            instant = instant.advanced(by: .seconds(5))
            return []
        }, sleep: { instant = instant.advanced(by: .seconds($0)) }), now: { instant })
        do { _ = try await unavailable.checkPracticeDevice(afterAppSwitch: true); fatalError("Unavailable phone must fail") }
        catch let error as SpotifyNowPlaying.PlayError {
            check(error == .noDevice && discoveries == 3, "Slow discovery respects the startup deadline")
        }
        unavailable.reset()

        discoveries = 0
        let limited = SpotifyNowPlaying(service: .init(current: { nil }, seek: { _ in }, devices: {
            discoveries += 1
            throw NSError(domain: "SpotifyAPI", code: 429, userInfo: ["retryAfter": 20.0])
        }))
        do { _ = try await limited.checkPracticeDevice(afterAppSwitch: true); fatalError("Rate limit must fail") }
        catch let error as SpotifyNowPlaying.PlayError {
            check(error == .rateLimited(20) && discoveries == 1, "Startup never retries a rate-limited read")
        }
        do { _ = try await limited.checkPracticeDevice(afterAppSwitch: true); fatalError("Cooldown must block") }
        catch { check(discoveries == 1, "Further connection checks honor the existing cooldown") }
        limited.reset()

        check(SpotifyNowPlaying.PlayError.noDevice.canWakeApp && SpotifyNowPlaying.PlayError.onlyElsewhere("Mac").canWakeApp &&
              !SpotifyNowPlaying.PlayError.ambiguousDevice.canWakeApp && !SpotifyNowPlaying.PlayError.restrictedDevice.canWakeApp &&
              !SpotifyNowPlaying.PlayError.premiumRequired.canWakeApp && !SpotifyNowPlaying.PlayError.notConnected.canWakeApp &&
              !SpotifyNowPlaying.PlayError.connectionLost.canWakeApp,
              "Only missing-device errors trigger an app switch")

        check(SpotifyLaunchCallback.matches(URL(string: "chordlyze://callback#access_token=fixture")!, redirectURI: "chordlyze://callback"),
              "The registered native callback is recognized")
        for url in ["other://callback", "chordlyze://wrong", "chordlyze://callback/extra", "chordlyze://callback:42", "chordlyze://user@callback"] {
            check(!SpotifyLaunchCallback.matches(URL(string: url)!, redirectURI: "chordlyze://callback"),
                  "A different callback destination is rejected")
        }
        check(SpotifyLaunchCallback.result(accessToken: nil, error: nil) == nil &&
              SpotifyLaunchCallback.result(accessToken: "", error: nil) == nil,
              "An unrelated PKCE callback or empty SDK token cannot complete native startup")
        check(SpotifyLaunchCallback.result(accessToken: "fixture", error: nil) == .success,
              "SDK authorization success is independent of saved Web API credentials")
        if case .failure(let message) = SpotifyLaunchCallback.result(accessToken: "fixture", error: "sensitive callback detail") {
            check(!message.contains("sensitive"), "Authorization errors take precedence and do not expose raw callback data")
        } else { fatalError("Authorization error must fail") }
    }

    /// Production Live: the Spotify poller and the Live screen share one document
    /// through a cache, the poller republishes every 2 s, and the app goes to the
    /// background and back while the chart is still being made.
    @MainActor static func liveFlowTests() async throws {
        var documents: [String: SongSheetStore] = [:]
        var polls = 0
        var readyAfter = 3
        let provider: (Track) -> SongSheetStore = { track in
            if let existing = documents[track.id] { return existing }
            let store = SongSheetStore(song: SongDescriptor(track: track), service: .init(
                request: { _ in status("processing") },
                status: { _ in polls += 1; return status(polls < readyAfter ? "processing" : "ready", ready: polls >= readyAfter) },
                lyrics: { _ in lyrics() }, sleep: { _ in try await Task.sleep(for: .milliseconds(25)) }))
            documents[track.id] = store
            return store
        }
        var blip = false
        let player = SpotifyNowPlaying(service: .init(current: { blip ? nil : playback() }, seek: { _ in },
                                                      sleep: { _ in try await Task.sleep(for: .milliseconds(30)) }),
                                       sheetProvider: provider)
        player.resume()
        try await waitFor { player.playing != nil && documents["one"] != nil }
        let store = documents["one"]!
        var live = Task { await store.observe() }
        try await waitFor { store.canPractice }
        check(store.rows.contains { !$0.chords.isEmpty }, "Chart arriving while Live is open fills the shared document")

        // Background and foreground while a new chart is pending.
        documents.removeAll(); polls = 0; readyAfter = 6
        player.stop(); live.cancel(); await live.value
        player.resume()
        try await waitFor { documents["one"] != nil }
        let second = documents["one"]!
        live = Task { await second.observe() }
        try await waitFor { second.state == "processing" }
        player.stop(); live.cancel(); await live.value            // app backgrounded mid-analysis
        try await Task.sleep(for: .milliseconds(60))
        player.resume()                                          // foreground: poller restarts first
        live = Task { await second.observe() }                    // then the Live screen re-observes
        try await waitFor { second.canPractice }
        check(second.rows.contains { !$0.chords.isEmpty }, "A background/foreground cycle mid-analysis still delivers the chart")

        // Spotify briefly reports nothing playing while the chart is pending.
        documents.removeAll(); polls = 0; readyAfter = 6
        player.stop(); live.cancel(); await live.value
        player.resume()
        try await waitFor { documents["one"] != nil }
        let third = documents["one"]!
        live = Task { await third.observe() }
        try await waitFor { third.state == "processing" }
        blip = true
        try await waitFor { player.playing == nil }
        live.cancel(); await live.value                            // Live screen replaced by "Nothing playing"
        blip = false
        try await waitFor { player.playing != nil }
        live = Task { await third.observe() }
        try await waitFor { third.canPractice }
        check(third.rows.contains { !$0.chords.isEmpty }, "A momentary empty playback response does not strand the pending chart")
        live.cancel(); await live.value
        player.reset()
    }
}

extension SongSheetTests {
    @MainActor static func passageTests() async throws {
        func job(_ state: String) -> PassageJob {
            decode(["id": "proposal", "state": state, "start": 2, "end": 8, "chart_revision": "chart-one",
                    "segments": [["start": 2, "end": 8, "label": "A:min"]]])
        }
        var reads = 0, requests = 0
        let model = PassageAnalysisModel(service: .init(read: { _ in
            reads += 1
            if requests == 0 { return nil }
            return job(reads < 3 ? "processing" : "ready")
        }, request: { _, start, end, revision in
            requests += 1
            check(start == 2 && end == 8 && revision == "chart-one", "passage request carries selected times and revision")
            return job("queued")
        }, sleep: { _ in }))
        await model.follow(track: "song")
        check(requests == 0 && reads == 1 && model.loaded && model.job == nil, "opening only discovers, never starts analysis")
        await model.request(track: "song", start: 2, end: 8, revision: "chart-one")
        await model.request(track: "song", start: 2, end: 8, revision: "chart-one")
        check(requests == 1, "pending preparation cannot be submitted twice")
        await model.follow(track: "song")
        check(model.job?.state == "ready" && requests == 1, "polling follows preparation to ready without a POST")
        let reopened = PassageAnalysisModel(service: .init(read: { _ in job("ready") }, request: { _,_,_,_ in fatalError("read-only reopen") }))
        await reopened.follow(track: "song")
        check(reopened.job?.state == "ready", "result survives a new screen model")
        var failures = 0
        let offline = PassageAnalysisModel(service: .init(read: { _ in failures += 1; throw URLError(.notConnectedToInternet) }, sleep: { _ in }))
        await offline.follow(track: "song")
        check(failures == 3 && offline.error != nil && !offline.loaded, "failed discovery is bounded and visible")
        var stored = false
        let lostResponse = PassageAnalysisModel(service: .init(read: { _ in stored ? job("ready") : nil }, request: { _,_,_,_ in
            stored = true; throw URLError(.timedOut)
        }, sleep: { _ in }))
        await lostResponse.follow(track: "song")
        await lostResponse.request(track: "song", start: 2, end: 8, revision: "chart-one")
        await lostResponse.follow(track: "song")
        check(lostResponse.job?.state == "ready", "lost POST response is recovered by reading the durable result")
        let review: ChordReview = decode(["start": 2, "end": 8, "label": "A:min", "alternatives": ["C:maj"], "needs_review": true, "reason": "Close alternatives"])
        check(review.matches(job("ready").segments![0]), "review cue matches exact chord identity")
        check(!review.matches(ChordSegment(start: 2, end: 9, label: "A:min", roman: nil)), "timing edits invalidate stale evidence")
        check(!review.matches(ChordSegment(start: 2, end: 8, label: "C:maj", roman: nil)), "label edits invalidate stale evidence")
        var continuation: CheckedContinuation<PassageJob?, Error>?
        let delayed = PassageAnalysisModel(service: .init(read: { _ in try await withCheckedThrowingContinuation { continuation = $0 } }))
        let task = Task { await delayed.follow(track: "song") }
        try await waitFor { continuation != nil }
        task.cancel(); continuation?.resume(returning: job("ready")); await task.value
        check(delayed.job == nil && !delayed.loaded, "cancelled screen ignores a late status response")
    }
}
