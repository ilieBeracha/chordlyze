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
    }
    static let minInstrumental: Double = 2
    static let rowLength: Double = 8
    static let lastWordLength: Double = 1
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

    static func build(analysis: ChordAnalysis?, lines: [LyricLine], duration: Double?) -> [Row] {
        let events = events(analysis)
        let coverage = analysis?.isPreview == false ? analysis?.coverageEnd ?? 0 : 0
        var unique: [Double: LyricLine] = [:]
        for line in lines where line.time.isFinite && line.time >= 0 {
            if unique[line.time] == nil || !line.text.isEmpty { unique[line.time] = line }
        }
        let lyrics = unique.values.sorted { $0.time < $1.time }
        let suppliedEnd = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let end = suppliedEnd ?? max(coverage, lyrics.last.map { $0.time + rowLength } ?? 0)
        guard end > 0 else { return [] }
        var rows: [Row] = []

        func append(start: Double, end: Double, text: String = "", words: [WordStamp]? = nil) {
            guard end > start else { return }
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
            let start = max(cursor, line.time)
            let next = min(end, index + 1 < lyrics.count ? lyrics[index + 1].time : end)
            if start > cursor { append(start: cursor, end: start) }
            let words = line.words?.filter { $0.time.isFinite && $0.time >= start && $0.time < next }
                .sorted { $0.time < $1.time }
            if !line.text.isEmpty, let last = words?.last, next - last.time - lastWordLength >= minInstrumental {
                let sungEnd = last.time + lastWordLength
                append(start: start, end: sungEnd, text: line.text, words: words)
                append(start: sungEnd, end: next)
            } else {
                append(start: start, end: next, text: line.text, words: words?.isEmpty == false ? words : nil)
            }
            cursor = next
        }
        if cursor < end { append(start: cursor, end: end) }
        return rows
    }

    private static func place(_ events: [Event], start: Double, end: Double, kind: Kind,
                              text: String, words: [WordStamp]?) -> Row {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let held = events.first { $0.start < start && $0.end > start }
        let placed = events.filter { $0.start >= start && $0.start < end }.map { event in
            let position = max(0, (event.start - start) / max(end - start, 0.001))
            let wordIndex: Int?
            if let words, !words.isEmpty {
                wordIndex = max(0, words.lastIndex(where: { $0.time <= max(start, event.start) }) ?? 0)
            } else if !tokens.isEmpty {
                // Line timestamps do not establish word onsets: these are layout
                // estimates. Actual chord intervals stay on the audio timeline.
                let sung = sungDuration(words: tokens.count, interval: end - start)
                let share = min(1, max(0, (event.start - start) / max(sung, 0.001)))
                let weights = tokens.map { Double(max(1, $0.count)) }
                let target = share * weights.reduce(0, +)
                var consumed = 0.0
                var index = 0
                for weight in weights.dropLast() {
                    if consumed + weight > target { break }
                    consumed += weight
                    index += 1
                }
                wordIndex = index
            } else { wordIndex = nil }
            return Placed(event: event, position: position, wordIndex: wordIndex)
        }
        return Row(start: start, end: end, kind: kind, text: text, words: words, chords: placed, held: held)
    }
}

/// The chart's beat times with bars inferred on top. The backend tracks
/// beats but not downbeats; in 4/4, chord changes land on beat 1 far more
/// than elsewhere, so the beat phase most changes fall on is taken as the
/// downbeat. Everything the metronome and the sheet do with beats goes
/// through here so they agree.
struct BeatGrid: Equatable {
    static let beatsPerBar = 4
    /// How far off a beat a chord boundary may be and still count as on it.
    static let snapShare = 0.34

    let beats: [Double]
    /// Median beat spacing, in seconds.
    let period: Double
    /// Index into `beats` of a downbeat; every fourth beat from it is one.
    let phase: Int

    init?(tempo: ChordAnalysis.Tempo?, chords: [ChordSegment]) {
        guard let tempo, tempo.beats.count >= Self.beatsPerBar * 2 else { return nil }
        let beats = tempo.beats.filter(\.isFinite).sorted()
        let gaps = zip(beats, beats.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }.sorted()
        guard gaps.count >= Self.beatsPerBar, gaps[gaps.count / 2] > 0.15 else { return nil }
        self.beats = beats
        period = gaps[gaps.count / 2]
        var votes = [Int](repeating: 0, count: Self.beatsPerBar)
        for chord in chords where chord.label != "N" {
            guard let index = Self.nearestIndex(beats, to: chord.start),
                  abs(beats[index] - chord.start) <= period * Self.snapShare else { continue }
            votes[index % Self.beatsPerBar] += 1
        }
        phase = votes.indices.max { votes[$0] < votes[$1] || (votes[$0] == votes[$1] && $0 > $1) } ?? 0
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

    func isDownbeat(_ index: Int) -> Bool { (index - phase) % Self.beatsPerBar == 0 }

    /// The nearest beat when the time is within a third of a beat of it.
    func snap(_ time: Double) -> Double {
        guard let index = Self.nearestIndex(beats, to: time), abs(beats[index] - time) <= period * Self.snapShare else { return time }
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

    /// 1...4 within the bar at `time`; nil before the first beat.
    func beatInBar(at time: Double) -> Int? {
        beatIndex(at: time).map { ((($0 - phase) % Self.beatsPerBar) + Self.beatsPerBar) % Self.beatsPerBar + 1 }
    }

    /// The downbeat at or just before `time`, so a take begins on beat 1.
    /// Before the first downbeat, the first downbeat.
    func downbeat(atOrBefore time: Double) -> Double {
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

    enum CodingKeys: String, CodingKey {
        case offset, scale, anchors
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
    func matches(chartAudioSha256: String?, spotifyTrackID: String?) -> Bool {
        (self.chartAudioSha256 == nil || self.chartAudioSha256 == chartAudioSha256)
            && (self.spotifyTrackID == nil || spotifyTrackID == nil || self.spotifyTrackID == spotifyTrackID)
    }
}
