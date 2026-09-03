import Foundation

/// Lays the chord timeline out as rows the sheet and the live view both render.
///
/// Chords belong to the audio timeline. Lyrics only say where words fall on
/// it: a chord is pinned to a word only when the lyrics carry a timestamp for
/// that word, otherwise it sits in time order across the row. Rows cover the
/// whole recording — intro, verses, breaks, ending, the part past the analyzed
/// audio — and every chord change is owned by exactly one row.
enum SheetModel {
    /// One recognized interval, [start, end). `chord` nil = no chord (N.C.).
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

    /// An event as it appears inside the row it starts in. A chord that keeps
    /// sounding into the next row is not repeated there: a row shows only
    /// the changes that happen in it.
    struct Placed: Identifiable {
        let event: Event
        /// Fraction of the row's span at which the event starts.
        let position: Double
        /// Word the event starts on; set only when the lyrics have word times.
        let wordIndex: Int?
        var id: Double { event.start }
    }

    enum Kind: Equatable {
        case lyric
        case instrumental
        /// Past the analyzed audio: the words may be known, the chords are not.
        case uncovered
    }

    struct Row: Identifiable {
        let start: Double
        let end: Double
        let kind: Kind
        /// Lyric text; empty for instrumental rows and for the continuation
        /// rows of a lyric line whose singing end is unknown.
        let text: String
        let words: [WordStamp]?
        let chords: [Placed]
        var id: Double { start }
        func contains(_ time: Double) -> Bool { time >= start && time < end }
        var isInstrumental: Bool { kind == .instrumental }
    }

    /// A wordless stretch at least this long gets its own timed row.
    static let minInstrumental: Double = 2
    /// Rows longer than this are cut into consecutive rows of this length.
    static let rowLength: Double = 8
    /// How long the last timestamped word of a line is assumed to sound. The
    /// one assumption left: word timestamps carry onsets, never ends.
    static let lastWordLength: Double = 1

    /// The chord timeline, clipped to the analyzed audio. Empty for a preview
    /// excerpt, whose offset in the song is unknown.
    static func events(_ analysis: ChordAnalysis) -> [Event] {
        guard !analysis.isPreview else { return [] }
        let coverage = analysis.coverageEnd
        return analysis.chords.compactMap { seg in
            let end = min(seg.end, coverage)
            guard end > seg.start else { return nil }
            return Event(start: seg.start, end: end, chord: seg.chord)
        }
    }

    /// The event sounding at `time`, by interval containment.
    static func activeEvent(_ events: [Event], at time: Double) -> Event? {
        events.first { $0.contains(time) }
    }

    /// `duration`: full song length when known; the timeline otherwise ends at
    /// the later of the analyzed audio and the last lyric line.
    static func build(analysis: ChordAnalysis, lines: [LyricLine], duration: Double?) -> [Row] {
        let events = events(analysis)
        let coverage = analysis.isPreview ? 0 : analysis.coverageEnd
        let songEnd = max(duration ?? 0, coverage, lines.last.map { $0.time + 1 } ?? 0)

        // Preview excerpt: the lyrics are on song time, the chords are not.
        // Plain lyric rows; the views say why there are no chords.
        if analysis.isPreview {
            return lines.enumerated().map { index, line in
                Row(start: line.time,
                    end: index + 1 < lines.count ? lines[index + 1].time : songEnd,
                    kind: .lyric, text: line.text, words: line.words, chords: [])
            }
        }

        var spans: [Span] = []
        var cursor = 0.0
        for (index, line) in lines.enumerated() {
            let next = index + 1 < lines.count ? lines[index + 1].time : songEnd
            guard next > cursor else { continue }
            if line.time - cursor >= minInstrumental {
                spans.append(Span(start: cursor, end: line.time, kind: .instrumental))
                cursor = line.time
            }
            // With word onsets the sung part is known to end; a gap after it
            // becomes its own row. Line-only timestamps say nothing about
            // where singing stops, so the whole gap stays with the line.
            var lyricEnd = next
            if let lastWord = line.words?.last, lastWord.time >= line.time,
               next - (lastWord.time + lastWordLength) >= minInstrumental {
                lyricEnd = lastWord.time + lastWordLength
            }
            spans.append(Span(start: cursor, end: lyricEnd, kind: .lyric,
                              text: line.text, words: line.words))
            if lyricEnd < next {
                spans.append(Span(start: lyricEnd, end: next, kind: .instrumental))
            }
            cursor = next
        }
        if songEnd - cursor >= minInstrumental || spans.isEmpty {
            if songEnd > cursor {
                spans.append(Span(start: cursor, end: songEnd, kind: .instrumental))
            }
        } else if let last = spans.popLast() {
            spans.append(Span(start: last.start, end: songEnd, kind: last.kind,
                              text: last.text, words: last.words))
        }

        // Past the analyzed audio nothing is known: split there, mark the rest.
        var covered: [Span] = []
        for span in spans {
            if span.start >= coverage {
                covered.append(span.uncovered())
            } else if span.end > coverage {
                covered.append(Span(start: span.start, end: coverage, kind: span.kind,
                                    text: span.text, words: span.words))
                covered.append(Span(start: coverage, end: span.end, kind: .uncovered))
            } else {
                covered.append(span)
            }
        }

        // Long rows read as time: cut them into consecutive rowLength pieces.
        // Unanalyzed stretches are one row each: there is nothing to space out.
        var rows: [Row] = []
        for span in covered {
            if span.kind == .uncovered, span.text.isEmpty, let last = rows.last, last.kind == .uncovered {
                rows[rows.count - 1] = Row(start: last.start, end: span.end, kind: .uncovered,
                                           text: last.text, words: last.words, chords: [])
                continue
            }
            var pieceStart = span.start
            var first = true
            while pieceStart < span.end {
                if span.kind == .uncovered {
                    rows.append(place(events, in: span))
                    break
                }
                var pieceEnd = min(span.end, pieceStart + rowLength)
                if span.end - pieceEnd < minInstrumental { pieceEnd = span.end }
                let piece = Span(start: pieceStart, end: pieceEnd, kind: span.kind,
                                 text: first ? span.text : "",
                                 words: first ? span.words : nil)
                rows.append(place(events, in: piece))
                pieceStart = pieceEnd
                first = false
            }
        }
        return rows
    }

    private struct Span {
        let start: Double
        let end: Double
        let kind: Kind
        var text = ""
        var words: [WordStamp]? = nil

        func uncovered() -> Span {
            Span(start: start, end: end, kind: .uncovered, text: text, words: words)
        }
    }

    private static func place(_ events: [Event], in span: Span) -> Row {
        guard span.kind != .uncovered else {
            return Row(start: span.start, end: span.end, kind: .uncovered,
                       text: span.text, words: span.words, chords: [])
        }
        let length = max(span.end - span.start, 0.001)
        var placed: [Placed] = []
        for event in events where event.start >= span.start && event.start < span.end {
            placed.append(Placed(event: event,
                                 position: (event.start - span.start) / length,
                                 wordIndex: span.words?.lastIndex(where: { $0.time <= event.start })))
        }
        return Row(start: span.start, end: span.end, kind: span.kind,
                   text: span.text, words: span.words, chords: placed)
    }
}
