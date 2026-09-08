import Foundation

/// One timeline for every surface. A chord is shown once, where it starts;
/// a row never repeats the chord still sounding from the previous row.
/// Blank LRC timestamps preserve instrumental breaks.
enum SheetModel {
    struct Event: Identifiable, Equatable {
        let start: Double
        let end: Double
        let chord: Chord?
        var id: Double { start }
        func contains(_ time: Double) -> Bool { time >= start && time < end }
        func display(transposedBy semitones: Int) -> String {
            chord?.transposed(by: semitones).display ?? "N.C."
        }
    }
    struct Placed: Identifiable {
        let event: Event
        let position: Double
        let wordIndex: Int?
        var id: Double { event.start }
    }
    enum Kind: Equatable { case lyric, instrumental, uncovered }
    struct Row: Identifiable {
        let start: Double
        let end: Double
        let kind: Kind
        let text: String
        let words: [WordStamp]?
        /// Chord changes inside this row, in time order.
        let chords: [Placed]
        /// The chord that started in an earlier row and is still sounding at
        /// this row's start. Never drawn; it only tells the row it has chords.
        let held: Event?
        var id: Double { start }
        func contains(_ time: Double) -> Bool { time >= start && time < end }
        var isInstrumental: Bool { kind == .instrumental }
        /// Timing gaps remain in the model for playback, but do not create blank
        /// rows on screen. SongSheetStatus explains missing analysis once.
        var hasVisibleContent: Bool { !text.isEmpty || !chords.isEmpty }
    }
    static let minInstrumental: Double = 2
    static let rowLength: Double = 8
    static let lastWordLength: Double = 1
    /// A silence this long inside a word-timed line, with chord changes in
    /// it, splits the line around an instrumental row.
    static let pauseSplit: Double = 3
    /// Line-timed lyrics: a line is sung over roughly half a second a word,
    /// and never over less than this share of the gap to the next line.
    static let secondsPerWord: Double = 0.5
    static let minimumSungShare: Double = 0.6

    /// Seconds of a line-timed row that carry words. The interval to the next
    /// line includes the breath or fill before it; placing chords over the
    /// whole interval put them early on the line.
    static func sungDuration(words: Int, interval: Double) -> Double {
        guard interval > 0, words > 0 else { return interval }
        return min(interval, max(secondsPerWord * Double(words), minimumSungShare * interval))
    }

    /// Chord events on the beat grid when the chart has one: a boundary the
    /// recognizer put within a third of a beat of a beat moves onto it, so
    /// chords change where the click lands and where a player expects.
    static func events(_ analysis: ChordAnalysis?) -> [Event] {
        guard let analysis, !analysis.isPreview else { return [] }
        let grid = BeatGrid(tempo: analysis.tempo, chords: analysis.chords)
        let snap: (Double) -> Double = { grid?.snap($0) ?? $0 }
        return analysis.chords.compactMap { segment in
            let start = snap(segment.start)
            let end = min(snap(segment.end), analysis.coverageEnd)
            guard start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
            return Event(start: start, end: end, chord: segment.chord)
        }.sorted { $0.start < $1.start }
    }
    static func activeEvent(_ events: [Event], at time: Double) -> Event? {
        events.first { $0.contains(time) }
    }
    static func activeRow(_ rows: [Row], at time: Double) -> Row? {
        rows.first { $0.contains(time) }
    }
    /// The chord rail: the sounding chord (or, in a gap, the first to come)
    /// and the next changes of chord after it, up to `count` in all. Events
    /// that show the same chord as the one before them are one entry; a
    /// no-chord stretch has nothing to finger and is skipped.
    static func changes(_ events: [Event], from time: Double, count: Int) -> [Event] {
        var out: [Event] = []
        for event in events where event.end > time && event.chord != nil {
            if let last = out.last, last.chord == event.chord { continue }
            out.append(event)
            if out.count == count { break }
        }
        return out
    }
    /// The next change of chord after `time`: a following event with the same
    /// chord (a bass or voicing the sheet shows alike) is not "next".
    static func nextEvent(_ events: [Event], after time: Double) -> Event? {
        let sounding = activeEvent(events, at: time)?.chord
        return events.first { $0.start > time && $0.chord != sounding }
    }

    static func build(analysis: ChordAnalysis?, lines: [LyricLine], duration: Double?) -> [Row] {
        let events = events(analysis)
        let coverage = analysis?.isPreview == false ? analysis?.coverageEnd ?? 0 : 0
        var unique: [Double: LyricLine] = [:]
        for line in lines where line.time.isFinite && line.time >= 0 {
            if let previous = unique[line.time], !previous.text.isEmpty, !line.text.isEmpty,
               previous.text != line.text {
                // Shared timestamps are not permission to discard another lyric.
                unique[line.time] = LyricLine(time: line.time, text: previous.text + " " + line.text, words: nil)
            } else if unique[line.time] == nil || !line.text.isEmpty { unique[line.time] = line }
        }
        let lyrics = unique.values.sorted { $0.time < $1.time }
        var starts = lyrics.map(\.time)
        // A chord can anticipate a phrase by a fraction of a second. Associate
        // it visually with that phrase only after the preceding word has ended.
        // Event timestamps themselves remain untouched for playback and scoring.
        for index in lyrics.indices.dropFirst() {
            let line = lyrics[index], previous = lyrics[index - 1]
            guard !line.text.isEmpty, !previous.text.isEmpty,
                  let priorWords = completeWords(previous, before: line.time), let last = priorWords.last,
                  let event = events.last(where: { $0.chord != nil && $0.start < line.time && $0.end > line.time }),
                  line.time - event.start <= 0.35,
                  event.start > previous.time,
                  event.start >= (last.end ?? (last.time + 0.5)) else { continue }
            starts[index] = event.start
        }
        let suppliedEnd = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let end = suppliedEnd ?? max(coverage, lyrics.last.map { $0.time + rowLength } ?? 0)
        guard end > 0 else { return [] }
        var rows: [Row] = []

        func append(start: Double, end: Double, text: String = "", words: [WordStamp]? = nil) {
            guard end > start else { return }
            // A wordless sliver shorter than half a second is rounding between
            // neighbours unless it carries a real chord change.
            if text.isEmpty, end - start < 0.5,
               !events.contains(where: { $0.start >= start && $0.start < end }) { return }
            let kind: Kind = start >= coverage ? .uncovered : (text.isEmpty ? .instrumental : .lyric)
            // A catalog duration a fraction longer than the analyzed audio is not a pending part.
            if kind == .uncovered, end - start < 1 { return }
            // A lyric line stays intact. Eight-second splits previously lost words.
            if !text.isEmpty || kind == .uncovered {
                rows.append(place(events, start: start, end: end, kind: kind, text: text, words: words))
            } else {
                var cursor = start
                while cursor < end {
                    let next = min(end, cursor + rowLength, cursor < coverage ? coverage : end)
                    guard next > cursor else { break }
                    rows.append(place(events, start: cursor, end: next,
                                      kind: cursor >= coverage ? .uncovered : .instrumental, text: "", words: nil))
                    cursor = next
                }
            }
        }
        var cursor = 0.0
        for (index, line) in lyrics.enumerated() where line.time < end {
            let start = max(cursor, starts[index])
            let next = min(end, index + 1 < lyrics.count ? starts[index + 1] : end)
            if start > cursor { append(start: cursor, end: start) }
            let words = completeWords(line, before: next)
            if !line.text.isEmpty, let words, !words.isEmpty {
                // A long pause inside a line that carries chord changes is sung as
                // two parts with an instrumental between; drawn that way, the
                // chords of the pause are not stacked above the last word before it.
                // Only a change just before the next word may anticipate that
                // word. Earlier changes stay in the rest, even a single change.
                var partStart = start
                if let first = words.first, first.time - start > 0.35 {
                    let anticipation = events.last { $0.start >= start && $0.start <= first.time && first.time - $0.start <= 0.35 }
                    partStart = anticipation?.start ?? first.time
                    append(start: start, end: partStart)
                }
                var part: [WordStamp] = []
                for (index, word) in words.enumerated() {
                    part.append(word)
                    guard index + 1 < words.count else { break }
                    let nextOnset = words[index + 1].time
                    let sungEnd = min(nextOnset, word.end ?? (word.time + lastWordLength))
                    let changes = events.filter { $0.start >= sungEnd && $0.start < nextOnset }.map(\.start)
                    if nextOnset - sungEnd >= pauseSplit, let lastChange = changes.last {
                        let resume = nextOnset - lastChange <= 0.35 ? lastChange : nextOnset
                        append(start: partStart, end: sungEnd, text: part.map(\.text).joined(separator: " "), words: part)
                        append(start: sungEnd, end: resume)
                        partStart = resume
                        part = []
                    }
                }
                let text = partStart == start ? line.text : part.map(\.text).joined(separator: " ")
                if let last = part.last, next - (last.end ?? (last.time + lastWordLength)) >= minInstrumental {
                    let sungEnd = last.end ?? (last.time + lastWordLength)
                    append(start: partStart, end: sungEnd, text: text, words: part)
                    append(start: sungEnd, end: next)
                } else {
                    append(start: partStart, end: next, text: text, words: part)
                }
            } else {
                append(start: start, end: next, text: line.text, words: nil)
            }
            cursor = next
        }
        if cursor < end { append(start: cursor, end: end) }
        return rows
    }

    /// Only a complete word array may replace the authoritative lyric text.
    /// A partial, out-of-range or reordered array falls back to line timing.
    static func completeWords(_ line: LyricLine, before end: Double) -> [WordStamp]? {
        guard let words = line.words, !words.isEmpty,
              words.allSatisfy({ word in
                  word.time.isFinite && word.time >= line.time && word.time < end
                      && (word.end.map { $0.isFinite && $0 > word.time && $0 - word.time <= 8 } ?? true)
              }),
              zip(words, words.dropFirst()).allSatisfy({ $0.time <= $1.time }),
              normalizedLyric(words.map(\.text).joined(separator: " ")) == normalizedLyric(line.text) else { return nil }
        return words
    }

    private static func normalizedLyric(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    private static func place(_ events: [Event], start: Double, end: Double, kind: Kind,
                              text: String, words: [WordStamp]?) -> Row {
        let held = events.first { $0.start < start && $0.end > start }
        let placed = events.filter { $0.start >= start && $0.start < end }.map { event in
            let position = max(0, (event.start - start) / max(end - start, 0.001))
            let wordIndex: Int?
            if let words, !words.isEmpty {
                if let sounding = words.lastIndex(where: { $0.time <= event.start }),
                   event.start < (words[sounding].end ?? (words[sounding].time + 0.75)) {
                    wordIndex = sounding
                } else if let upcoming = words.firstIndex(where: { $0.time > event.start && $0.time - event.start <= 0.35 }) {
                    wordIndex = upcoming
                } else { wordIndex = nil }
            // A line timestamp says nothing about which word a change starts on.
            } else { wordIndex = nil }
            return Placed(event: event, position: position, wordIndex: wordIndex)
        }
        return Row(start: start, end: end, kind: kind, text: text, words: words, chords: placed, held: held)
    }
}

/// One timing model for the chart, navigation and metronome. New analyses use
/// detected beat positions; legacy 4/4 inference remains readable but never
/// qualifies as a detected bar map or enables exact bar-range selection.
struct BeatGrid: Equatable {
    static let beatsPerBar = 4 // Legacy fallback only.
    static let snapShare = 0.34
    let beats: [Double]
    let period: Double
    let phase: Int
    let positions: [Int]?
    let bars: [ChordAnalysis.Tempo.Bar]
    let sections: [ChordAnalysis.Tempo.Section]
    var isEstimated: Bool { positions == nil }

    init?(tempo: ChordAnalysis.Tempo?, chords: [ChordSegment]) {
        guard let tempo, tempo.beats.count >= (tempo.rhythmVersion == nil ? 8 : 2),
              tempo.beats.allSatisfy({ $0.isFinite && $0 >= 0 }),
              zip(tempo.beats, tempo.beats.dropFirst()).allSatisfy({ $0 < $1 }) else { return nil }
        beats = tempo.beats
        let gaps = zip(beats, beats.dropFirst()).map { $1 - $0 }.sorted()
        guard gaps[gaps.count / 2] > 0.15 else { return nil }
        period = gaps[gaps.count / 2]
        if tempo.rhythmVersion != nil {
            let p = tempo.beatPositions ?? []
            let validPositions = tempo.rhythmVersion == 1 && p.count == beats.count && p.allSatisfy { (0...12).contains($0) }
            positions = validPositions ? p : []
            phase = validPositions ? p.firstIndex(of: 1) ?? 0 : 0
            let candidates = tempo.bars ?? []
            let times = beats
            let indices = Dictionary(uniqueKeysWithValues: times.enumerated().map { ($0.element, $0.offset) })
            let valid = validPositions && candidates.enumerated().allSatisfy { index, bar in
                guard bar.start.isFinite, bar.end.isFinite, bar.start < bar.end,
                      (2...12).contains(bar.beats), let a = indices[bar.start],
                      let b = indices[bar.end], b-a == bar.beats,
                      Array(p[a..<b]) == Array(1...bar.beats), p[b] == 1,
                      index == 0 || candidates[index-1].end <= bar.start else { return false }
                let gaps = zip(times[a..<b], times[(a+1)...b]).map { $1-$0 }
                return gaps.max()! <= gaps.min()! * 1.8
            }
            bars = valid ? candidates : []
            let checkedBars = bars
            let proposed = tempo.sections ?? []
            var previousEnd = 0
            var occurrences: [String: Int] = [:]
            let validSections = proposed.allSatisfy { section in
                guard section.startBar == previousEnd+1, section.endBar >= section.startBar,
                      section.endBar <= checkedBars.count, !section.label.isEmpty,
                      section.label.count <= 3, section.label.allSatisfy({ $0.isASCII && $0.isUppercase }),
                      section.start == checkedBars[section.startBar-1].start,
                      section.end == checkedBars[section.endBar-1].end else { return false }
                let range = Array(checkedBars[(section.startBar-1)..<section.endBar])
                guard zip(range, range.dropFirst()).allSatisfy({ $0.end == $1.start }) else { return false }
                occurrences[section.label, default: 0] += 1
                guard section.occurrence == occurrences[section.label] else { return false }
                previousEnd = section.endBar
                return true
            }
            sections = validSections && previousEnd == bars.count ? proposed : []
        } else {
            positions = nil
            bars = []; sections = []
            var votes = [Int](repeating: 0, count: Self.beatsPerBar)
            for chord in chords where chord.label != "N" {
                guard let index = Self.nearestIndex(beats, to: chord.start),
                      abs(beats[index] - chord.start) <= period * Self.snapShare else { continue }
                votes[index % Self.beatsPerBar] += 1
            }
            phase = votes.indices.max { votes[$0] < votes[$1] || (votes[$0] == votes[$1] && $0 > $1) } ?? 0
        }
    }

    /// One-based, inclusive bar selection. Refuse a selection spanning a gap.
    func barRange(first: Int, last: Int) -> ClosedRange<Double>? {
        guard first >= 1, last >= first, last <= bars.count else { return nil }
        let range = Array(bars[(first-1)..<last])
        guard zip(range, range.dropFirst()).allSatisfy({ $0.end == $1.start }) else { return nil }
        return bars[first-1].start...bars[last-1].end
    }

    func barNumber(at time: Double) -> Int? {
        bars.firstIndex { $0.start <= time && time < $0.end }.map { $0+1 }
    }

    func beatsInBar(at time: Double) -> Int {
        if let index = barNumber(at: time) { return bars[index-1].beats }
        if let bar = bars.last(where: { $0.start <= time }) ?? bars.first { return bar.beats }
        if let positions, let index = beatIndex(at: time), positions.contains(1) {
            var first = index
            while first > 0 && positions[first] != 1 { first -= 1 }
            let last = positions[(first+1)...].firstIndex(of: 1) ?? positions.endIndex
            return max(1, positions[first..<last].max() ?? 4)
        }
        return Self.beatsPerBar
    }

    /// Use the nearby beat spacing for count-in even when tempo changes later.
    func period(at time: Double) -> Double {
        guard let i = beatIndex(at: time), i+1 < beats.count else { return period }
        return beats[i+1]-beats[i]
    }

    static func nearestIndex(_ beats: [Double], to time: Double) -> Int? {
        guard !beats.isEmpty else { return nil }
        var low = 0, high = beats.count
        while low < high {
            let mid = (low + high) / 2
            if beats[mid] < time { low = mid + 1 } else { high = mid }
        }
        if low == 0 { return 0 }
        if low == beats.count { return beats.count - 1 }
        return time - beats[low - 1] <= beats[low] - time ? low - 1 : low
    }

    func isDownbeat(_ index: Int) -> Bool {
        guard beats.indices.contains(index) else { return false }
        if let positions { return positions.indices.contains(index) && positions[index] == 1 }
        return (index - phase) % Self.beatsPerBar == 0
    }

    /// The nearest beat when the time is within a third of a beat of it.
    func snap(_ time: Double) -> Double {
        guard let index = Self.nearestIndex(beats, to: time), abs(beats[index] - time) <= period(at: time) * Self.snapShare else { return time }
        return beats[index]
    }

    /// Index of the last beat at or before `time`; nil before the first beat.
    func beatIndex(at time: Double) -> Int? {
        var low = 0, high = beats.count
        while low < high {
            let mid = (low + high) / 2
            if beats[mid] <= time { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? nil : low - 1
    }

    /// Detected position within the bar; nil before the first beat or when unknown.
    func beatInBar(at time: Double) -> Int? {
        guard let index = beatIndex(at: time) else { return nil }
        if let positions { return positions.indices.contains(index) && positions[index] > 0 ? positions[index] : nil }
        return (((index - phase) % Self.beatsPerBar) + Self.beatsPerBar) % Self.beatsPerBar + 1
    }

    /// The downbeat at or just before `time`, so a take begins on beat 1.
    /// Before the first downbeat, the first downbeat.
    func downbeat(atOrBefore time: Double) -> Double {
        if let positions, !positions.contains(1) { return beatIndex(at: time).map { beats[$0] } ?? beats[0] }
        if let index = beatIndex(at: time) {
            var k = index
            while k >= 0 { if isDownbeat(k) { return beats[k] }; k -= 1 }
        }
        return beats[beats.indices.first(where: isDownbeat) ?? 0]
    }

    /// Beats in [start, end) as offsets from `start`, with which are downbeats.
    func clicks(from start: Double, to end: Double) -> [(offset: Double, downbeat: Bool)] {
        beats.indices.filter { beats[$0] >= start && beats[$0] < end }
            .map { (beats[$0] - start, isDownbeat($0)) }
    }
}

/// How the chart's timeline maps onto the Spotify recording the listener
/// hears: spotify = scale * chart + offset. The chart was measured on a
/// different recording of the song, so the two can start at different
/// moments and, rarely, run at slightly different speeds. Fitted from
/// anchors the listener confirmed by ear; identity checks mark it stale
/// when the chart or the Spotify track changes.
struct TimingMap: Codable, Equatable {
    struct Anchor: Codable, Equatable {
        let chart: Double
        let spotify: Double
    }
    var offset: Double = 0
    var scale: Double = 1
    var anchors: [Anchor] = []
    var verifiedError: Double? = nil
    var chartAudioSha256: String? = nil
    var spotifyTrackID: String? = nil
    var chartRevision: String? = nil
    var method: String? = nil
    var matchScore: Double? = nil
    var matchMargin: Double? = nil
    var driftMeasured: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case offset, scale, anchors, method
        case chartRevision = "chart_revision", matchScore = "match_score", matchMargin = "match_margin", driftMeasured = "drift_measured"
        case verifiedError = "verified_error", chartAudioSha256 = "chart_audio_sha256", spotifyTrackID = "spotify_track_id"
    }

    static let identity = TimingMap()

    func chartTime(_ spotify: Double) -> Double { (spotify - offset) / scale }
    func spotifyTime(_ chart: Double) -> Double { scale * chart + offset }
    var isIdentity: Bool { offset == 0 && scale == 1 }

    /// Fitted from anchors: one gives the offset at scale 1; two or more give
    /// offset and scale by least squares, with scale kept within ten percent.
    static func fit(_ anchors: [Anchor], chartAudioSha256: String?, spotifyTrackID: String?) -> TimingMap? {
        let valid = anchors.filter { $0.chart.isFinite && $0.spotify.isFinite }
        guard let first = valid.first else { return nil }
        var map = TimingMap(anchors: valid, chartAudioSha256: chartAudioSha256, spotifyTrackID: spotifyTrackID)
        let span = (valid.map(\.chart).max() ?? 0) - (valid.map(\.chart).min() ?? 0)
        if valid.count < 2 || span < 20 {
            // Too close together to measure speed: offset only.
            map.offset = valid.map { $0.spotify - $0.chart }.reduce(0, +) / Double(valid.count)
            return map
        }
        let n = Double(valid.count)
        let meanC = valid.map(\.chart).reduce(0, +) / n
        let meanS = valid.map(\.spotify).reduce(0, +) / n
        let cov = valid.reduce(0) { $0 + ($1.chart - meanC) * ($1.spotify - meanS) }
        let varC = valid.reduce(0) { $0 + ($1.chart - meanC) * ($1.chart - meanC) }
        map.scale = min(1.1, max(0.9, cov / varC))
        map.offset = meanS - map.scale * meanC
        _ = first
        return map
    }

    /// Stale when the chart or the Spotify recording it was made for changed.
    func matches(chartAudioSha256: String?, spotifyTrackID: String?, chartRevision: String? = nil) -> Bool {
        (self.chartAudioSha256 == nil || self.chartAudioSha256 == chartAudioSha256)
            && (self.spotifyTrackID == nil || spotifyTrackID == nil || self.spotifyTrackID == spotifyTrackID)
            && (self.chartRevision == nil || self.chartRevision == chartRevision)
    }
}

/// Three separated windows, rather than an entire song upload. Playback must
/// remain continuous within a window; a seek or stale clock invalidates it.
enum AutomaticSyncPlan {
    struct Window: Equatable { let start: Double; let duration: Double }
    static func windows(duration: Double) -> [Window] {
        guard duration.isFinite, duration >= 45 else { return [] }
        let length = min(22, max(12, duration * 0.16))
        return [0.15, 0.5, 0.85].map {
            Window(start: max(0, min(duration - length - 1, duration * $0 - length / 2)), duration: length)
        }
    }
    static func uninterrupted(start: Double, position: Double, elapsed: Double) -> Bool {
        start.isFinite && position.isFinite && elapsed.isFinite && elapsed >= 0
            && abs(position - start - elapsed) <= 0.65
    }
}
