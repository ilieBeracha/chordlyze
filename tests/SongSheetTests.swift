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
private func status(_ state: String, epoch: String = "fresh", ready: Bool = false, saved: Bool? = nil) -> SongStatus {
    var result: [String: Any] = ["job": ["state": state, "worker_online": true], "library_generation": epoch]
    if let saved { result["saved"] = saved }
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
        runnerTests()
        try await documentTests()
        try await cancellationTests()
        try await playbackTests()
        recentPlaysTests()
        print("Song sheet and playback: \(checks)/\(checks) checks passed")
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
        // Beat grid: 120 BPM, chord changes on beats 4, 8, 12 (index 3 mod 4 = 3) -> those are downbeats.
        let beats = (0..<32).map { Double($0) * 0.5 }
        let gridChart: ChordAnalysis = decode(["chords": [["start": 0, "end": 1.53, "label": "C:maj"], ["start": 1.53, "end": 3.48, "label": "G:maj"],
                                                          ["start": 3.48, "end": 5.5, "label": "A:min"], ["start": 5.5, "end": 16, "label": "F:maj"]],
                                               "source": "youtube", "audio_duration": 16, "tempo": ["bpm": 120, "beats": beats]])
        let grid = BeatGrid(tempo: gridChart.tempo, chords: gridChart.chords)!
        check(grid.period == 0.5 && grid.phase == 3, "Bar phase is the beat most chord changes land on")
        check(grid.snap(1.53) == 1.5 && grid.snap(3.48) == 3.5 && grid.snap(1.3) == 1.3, "Boundaries within a third of a beat snap to it; others stay")
        check(SheetModel.events(gridChart).map(\.start) == [0, 1.5, 3.5, 5.5], "Sheet events change on the beat")
        check(grid.beatInBar(at: 1.5) == 1 && grid.beatInBar(at: 2.9) == 3 && grid.beatInBar(at: 3.5) == 1, "Beat within the bar counts from the inferred downbeat")
        check(grid.downbeat(atOrBefore: 4.2) == 3.5 && grid.downbeat(atOrBefore: 0.2) == 1.5, "A take begins on the bar at or before its range, or the first bar")
        let clicks = grid.clicks(from: 1.5, to: 4)
        check(clicks.map(\.offset) == [0, 0.5, 1, 1.5, 2] && clicks.map(\.downbeat) == [true, false, false, false, true], "Clicks are offsets from the take start with beat 1 marked")
        check(BeatGrid(tempo: nil, chords: []) == nil && BeatGrid(tempo: decode(["bpm": 100, "beats": [0, 0.6, 1.2]], as: ChordAnalysis.Tempo.self), chords: []) == nil, "Too few beats give no grid")
        // Line-timed lyrics: the words end before the next line starts, so a chord
        // halfway through the singing sits over the middle word, not an early one.
        let lineTimed = SheetModel.build(analysis: chart([["start": 0, "end": 2.4, "label": "C:maj"], ["start": 2.4, "end": 20, "label": "G:maj"]]),
                                     lines: [LyricLine(time: 0, text: "one two three four", words: nil), LyricLine(time: 8, text: "next", words: nil)], duration: 20)
        check(SheetModel.sungDuration(words: 4, interval: 8) == 4.8 && SheetModel.sungDuration(words: 12, interval: 4) == 4,
              "Singing is estimated at half a second a word, at least 60% of the gap, never past it")
        check(lineTimed.first?.chords.map(\.wordIndex) == [0, 2], "A chord 2.4 s into an 8 s gap sits over the third word, not the second")
        check(status("ready", saved: true).saved == true && status("ready").saved == nil, "The saved flag is optional in the status")
        // Timing calibration: spotify = scale * chart + offset, fitted from listened anchors.
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
            current: { device.map { playback(id: "one", milliseconds: Int($0.offset * 1000), playing: $0.playing) } },
            seek: { _ in },
            play: { id, at, deviceID in
                targeted.append(deviceID)
                if let playFailure { throw NSError(domain: "SpotifyAPI", code: playFailure) }
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
        catch let error as SpotifyNowPlaying.PlayError { check(error == .premiumRequired, "403 means Premium is required") }
        playFailure = nil
        stall = true
        do { try await starter.play(trackID: "one", at: 5); fatalError("An unconfirmed start must fail") }
        catch let error as SpotifyNowPlaying.PlayError { check(error == .notConfirmed, "Play never assumes playback Spotify did not report") }
        check(started.count == 3, "Failed requests never reach Spotify twice")
        starter.reset()
        let unconnected = SpotifyNowPlaying(sheetProvider: provider)
        do { try await unconnected.play(trackID: "one", at: 0); fatalError("Signed out cannot start playback") }
        catch let error as SpotifyNowPlaying.PlayError { check(error == .notConnected, "Play without a Spotify session is an explicit error") }

        check(requested == 0, "Playing a song never requests its analysis")
        try await liveFlowTests()
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
