import Combine
import Foundation

enum Config { static let backendBaseURL = URL(string: "http://127.0.0.1:1")! }
@MainActor final class SpotifyAuth { func validToken() async throws -> String { fatalError("Tests must not authenticate") } }

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
private func status(_ state: String, epoch: String = "fresh", ready: Bool = false) -> SongStatus {
    var result: [String: Any] = ["job": ["state": state, "worker_online": true], "library_generation": epoch]
    if ready { result["analysis"] = ["chords": [["start": 0, "end": 20, "label": "C:maj"]], "source": "youtube", "audio_duration": 20] }
    return decode(result)
}
private func lyrics(_ text: String = "First words") -> BackendClient.LyricsResult {
    decode(["lines": [["time": 2, "text": text], ["time": 8, "text": "Second line"]], "synced": true])
}
private func playback(id: String = "one", milliseconds: Int? = 12000, playing: Bool = true) -> SpotifyAPI.CurrentlyPlaying {
    decode(["progress_ms": milliseconds.map { $0 as Any } ?? NSNull(), "is_playing": playing, "item": [
        "id": id, "name": "Song", "artists": [["name": "Band"]], "album": ["name": "Album"], "duration_ms": 200000]])
}

@main struct SongSheetTests {
    @MainActor static func main() async throws {
        modelTests()
        try await documentTests()
        try await cancellationTests()
        try await playbackTests()
        print("Song sheet and playback: \(checks)/\(checks) checks passed")
    }

    @MainActor static func modelTests() {
        let lines = [LyricLine(time: 2, text: "One two three", words: nil), LyricLine(time: 8, text: "Four five six", words: nil)]
        let rows = SheetModel.build(analysis: chart(), lines: lines, duration: 20)
        let sung = rows.filter { !$0.text.isEmpty }
        check(sung.count == 2, "Every lyric line is retained")
        check(sung.allSatisfy { $0.chords.first?.event.chord?.display == "C" }, "Held chords repeat above later lyric lines")
        check(sung[1].chords[0].position == 0 && sung[1].chords[0].wordIndex == 0, "Held chord is above the first word")
        check(sung[1].end == 20 && sung[1].text == "Four five six", "Long lyric lines are not cut into blank eight-second rows")
        check(rows.first?.isInstrumental == true, "Intro has its own chord row")
        check(SheetModel.activeRow(rows, at: 9)?.id == 8, "Live selects current row by interval")
        check(SheetModel.activeRow(rows, at: 20) == nil, "Live does not hold the last lyric forever past song end")
        check(SheetModel.activeRow(rows, at: 3)?.id == 2, "Backward seek selects the earlier line")
        let pending = SheetModel.build(analysis: nil, lines: lines, duration: 20)
        check(pending.filter { !$0.text.isEmpty }.map(\.text) == lines.map(\.text), "Lyrics appear while analysis is pending")
        check(pending.allSatisfy { $0.chords.isEmpty }, "Pending analysis never invents chords")
        let preview = SheetModel.build(analysis: chart(preview: true), lines: lines, duration: 20)
        check(preview.filter { !$0.text.isEmpty }.count == 2 && preview.allSatisfy { $0.chords.isEmpty }, "Unknown-offset previews never masquerade as aligned chords")
        let blank = SheetModel.build(analysis: chart(), lines: [lines[0], LyricLine(time: 5, text: "", words: nil), lines[1]], duration: 20)
        check(blank.first { $0.start == 5 }?.isInstrumental == true, "Blank timed lyric creates a real instrumental break")
        check(blank.first { $0.start == 5 }?.chords.count == 1, "Instrumental break keeps held chords")
        let changed = chart([["start": 0, "end": 5, "label": "C:maj"], ["start": 5, "end": 20, "label": "G:7"]])
        let changedRows = SheetModel.build(analysis: changed, lines: lines, duration: 20)
        check(changedRows.first { $0.start == 2 }?.chords.count == 2, "Chord changes remain above the lyric line")
        check(changedRows.first { $0.start == 8 }?.chords.first?.event.chord?.display == "G7", "Later row carries the correct changed chord")
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
        let untimed = SheetModel.build(analysis: changed, lines: [], duration: 20, untimedLyrics: true)
        check(!untimed.isEmpty && untimed.allSatisfy { $0.text.isEmpty && $0.kind == .chords }, "Untimed lyrics never become timed rows")
        check(SheetModel.activeRow(untimed, at: 6)?.chords.contains { $0.event.contains(6) } == true, "Chord rows still follow the recording")
        check(SheetModel.build(analysis: changed, lines: [], duration: 20).allSatisfy { $0.isInstrumental }, "Without any lyrics, blank rows stay instrumental")
    }

    @MainActor static func documentTests() async throws {
        let song = SongDescriptor(trackID: "fixture", title: "Song", artist: "Band", album: "Album", duration: 20)
        var requests = 0, polls = 0
        let service = SongSheetStore.Service(request: { descriptor, _ in
            requests += 1
            check(descriptor.album == "Album" && descriptor.duration == 20, "Every surface sends real song duration and album")
            return status("queued")
        }, status: { _ in polls += 1; return status(polls < 3 ? "processing" : "ready", ready: polls >= 3) },
        lyrics: { _ in lyrics() }, sleep: { _ in try await Task.sleep(for: .milliseconds(25)) })
        let sheet = SongSheetStore(song: song, service: service)
        let first = Task { await sheet.observe() }
        let second = Task { await sheet.observe() }
        try await waitFor { !sheet.lyricsLoading }
        check(sheet.analysis == nil && sheet.rows.contains { !$0.text.isEmpty }, "Lyrics do not wait for recognition")
        try await waitFor { sheet.canPractice }
        check(requests == 1, "Two screens share one analysis request")
        check(sheet.rows.filter { !$0.text.isEmpty }.allSatisfy { !$0.chords.isEmpty }, "Finished analysis fills existing lyric rows automatically")
        first.cancel(); await first.value
        let previousPolls = polls
        try await waitFor { polls > previousPolls }
        check(sheet.canPractice, "Leaving one screen cannot stop another screen's document")
        second.cancel(); await second.value
        let stopped = polls
        try await Task.sleep(for: .milliseconds(70))
        check(polls == stopped, "Leaving the final screen cancels background polling")
        let resumed = Task { await sheet.observe() }
        try await waitFor { requests == 2 }
        check(requests == 2, "Reentry performs a fresh request instead of remaining stuck")
        resumed.cancel(); await resumed.value

        let plain = SongSheetStore(song: song, service: .init(request: { _, _ in status("ready", ready: true) },
            status: { _ in status("ready", ready: true) },
            lyrics: { _ in decode(["lines": [["time": 1, "text": "Guessed one"], ["time": 18.6, "text": "Guessed two"]], "synced": false]) },
            sleep: { _ in try await Task.sleep(for: .milliseconds(25)) }))
        let plainTask = Task { await plain.observe() }
        try await waitFor { plain.canPractice && !plain.lyricsLoading }
        check(plain.rows.allSatisfy { $0.text.isEmpty } && plain.rows.contains { $0.kind == .chords }, "Guessed lyric times never drive the runner")
        check(plain.untimedLyrics == ["Guessed one", "Guessed two"], "Untimed lyrics stay readable")
        check(SheetModel.activeRow(plain.rows, at: 5)?.chords.first?.event.chord?.display == "C", "Chords still follow the recording without timed lyrics")
        plainTask.cancel(); await plainTask.value

        var lookups = 0
        let alignedStatus: SongStatus = decode([
            "job": ["state": "ready", "worker_online": true], "library_generation": "fresh",
            "analysis": ["chords": [["start": 0, "end": 20, "label": "C:maj"]], "source": "youtube", "audio_duration": 20],
            "lyrics": ["synced": true, "matched": "aligned", "lines": [
                ["time": 3, "text": "Timed one", "words": [["time": 3, "text": "Timed"], ["time": 3.5, "text": "one"]]],
                ["time": 12, "text": "Timed two"]]]])
        let aligned = SongSheetStore(song: song, service: .init(request: { _, _ in alignedStatus },
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
        check(aligned.rows.first { $0.text == "Timed one" }?.chords.first?.wordIndex == 0, "Word times from the recording place chords")
        check(aligned.untimedLyrics.isEmpty && !aligned.lyricsLoading, "A late catalog result cannot overwrite recording-timed lyrics")
        alignedTask.cancel(); await alignedTask.value

        var resetPolls = 0
        let resetting = SongSheetStore(song: song, service: .init(request: { _, _ in status("ready", ready: true) },
            status: { _ in resetPolls += 1; return status("missing", epoch: "after-reset") },
            lyrics: { _ in lyrics() }, sleep: { _ in try await Task.sleep(for: .milliseconds(25)) }))
        let resetTask = Task { await resetting.observe() }
        try await waitFor { resetting.state == "missing" }
        check(resetting.analysis == nil && resetting.rows.allSatisfy { $0.chords.isEmpty }, "Reset removes old charts from an already open view")
        check(!resetting.canPractice, "A cleared reference cannot start practice")
        resetTask.cancel(); await resetTask.value

        var attempts = 0
        let recovering = SongSheetStore(song: song, service: .init(request: { _, _ in
            attempts += 1
            if attempts == 1 { throw URLError(.timedOut) }
            return status("ready", ready: true)
        }, status: { _ in status("ready", ready: true) }, lyrics: { _ in lyrics() },
        sleep: { _ in try await Task.sleep(for: .milliseconds(10)) }))
        let recovery = Task { await recovering.observe() }
        try await waitFor { recovering.canPractice }
        check(attempts == 2, "A failed initial request recovers in place")
        recovery.cancel(); await recovery.value
    }

    @MainActor static func cancellationTests() async throws {
        var pending: CheckedContinuation<SongStatus, Never>?
        var pendingLyrics: CheckedContinuation<BackendClient.LyricsResult?, Never>?
        var requests = 0, lyricCalls = 0
        let sheet = SongSheetStore(song: SongDescriptor(trackID: "canceled", title: "Song", artist: "Band", duration: 20),
            service: .init(request: { _, _ in
                requests += 1
                if requests == 1 { return await withCheckedContinuation { pending = $0 } }
                return status("ready", ready: true)
            }, status: { _ in status("ready", ready: true) }, lyrics: { _ in
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
        let provider: (Track) -> SongSheetStore = { track in
            SongSheetStore(song: SongDescriptor(track: track), service: .init(
                request: { _, _ in status("ready", ready: true) }, status: { _ in status("ready", ready: true) },
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
    }
}
