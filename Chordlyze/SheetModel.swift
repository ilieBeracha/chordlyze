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

    static func events(_ analysis: ChordAnalysis?) -> [Event] {
        guard let analysis, !analysis.isPreview else { return [] }
        return analysis.chords.compactMap { segment in
            let end = min(segment.end, analysis.coverageEnd)
            guard segment.start.isFinite, end.isFinite, segment.start >= 0, end > segment.start else { return nil }
            return Event(start: segment.start, end: end, chord: segment.chord)
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
