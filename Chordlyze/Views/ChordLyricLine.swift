import SwiftUI

/// Chords above lyric tokens. The model uses word timestamps when available,
/// otherwise a clearly labeled estimate within the timestamped lyric line.
struct ChordLyricLine: View {
    struct Token: Identifiable {
        let id: Int
        let word: String
        let chords: [SheetModel.Placed]
    }

    let text: String
    let chords: [SheetModel.Placed]
    var words: [String]? = nil
    var transposeBy = 0
    var playhead: Double? = nil
    var style: ChordRowView.Style = .live
    /// Live: this is the line being sung.
    var active = false
    /// No chord is known for this line yet (not merely held from the previous row).
    var pending = false
    var onChordTap: ((String) -> Void)? = nil
    var onLyricTap: (() -> Void)? = nil
    var verdict: ((Double) -> PracticeFeedback.Verdict?)? = nil
    /// The row's span in song time, for the sweeping playhead in Live.
    var rowStart: Double = 0
    var rowEnd: Double = 0
    /// Onset of each word when the lyrics are word-timed (same order as
    /// `words`); the playhead then follows the voice instead of guessing.
    var wordTimes: [Double]? = nil

    var body: some View {
        let tokens = Self.tokens(text: text, chords: chords, words: words)
        let hasChords = !chords.isEmpty
        FlowLayout(spacing: style == .sheet ? 6 : 9) {
            ForEach(tokens) { token in
                VStack(alignment: .leading, spacing: 3) {
                    if hasChords {
                        chordRow(token.chords)
                            .frame(minHeight: style == .sheet ? 28 : 38, alignment: .bottomLeading)
                    } else if token.id == 0, pending {
                        Text("—")
                            .font(style.chordFont)
                            .foregroundStyle(Palette.tertiary)
                            .frame(minHeight: style == .sheet ? 28 : 38, alignment: .bottomLeading)
                            .accessibilityLabel("Chords not available yet")
                    } else {
                        Color.clear.frame(height: style == .sheet ? 28 : 38)
                    }
                    Text(token.word)
                        .font(style.wordFont(active: active))
                        .foregroundStyle(style.wordColor(active: active))
                        .onTapGesture { onLyricTap?() }
                }
                .anchorPreference(key: TokenAnchors.self, value: .bounds) { [token.id: $0] }
            }
        }
        .overlayPreferenceValue(TokenAnchors.self) { anchors in
            if style == .live, let playhead, rowEnd > rowStart, playhead >= rowStart, playhead < rowEnd {
                GeometryReader { geo in
                    if let point = LyricPlayhead.position(at: playhead, rowStart: rowStart, rowEnd: rowEnd,
                                                          chords: chords, wordTimes: wordTimes,
                                                          tokens: anchors.mapValues { geo[$0] },
                                                          width: geo.size.width, rtl: rtl) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.spotifyGreen.opacity(0.7))
                            .frame(width: 2, height: point.height)
                            .position(x: point.x, y: point.y)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    private var rtl: Bool { text.isRTLText }

    struct TokenAnchors: PreferenceKey {
        static var defaultValue: [Int: Anchor<CGRect>] = [:]
        static func reduce(value: inout [Int: Anchor<CGRect>], nextValue: () -> [Int: Anchor<CGRect>]) {
            value.merge(nextValue(), uniquingKeysWith: { $1 })
        }
    }

    @ViewBuilder
    private func chordRow(_ placed: [SheetModel.Placed]) -> some View {
        if placed.isEmpty {
            Text(" ").font(style.chordFont)  // keeps every word's baseline aligned
        } else {
            HStack(spacing: 6) {
                ForEach(placed) { chord in
                    ChordChip(name: chord.event.display(transposedBy: transposeBy),
                              active: playhead.map(chord.event.contains) ?? false,
                              style: style, onTap: onChordTap, verdict: verdict?(chord.event.start))
                }
            }
        }
    }

    /// Split into words and attach each chord to the word it starts on.
    static func tokens(text: String, chords: [SheetModel.Placed], words supplied: [String]? = nil) -> [Token] {
        let words = supplied ?? text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        var byWord: [Int: [SheetModel.Placed]] = [:]
        for chord in chords {
            let index = max(0, min(chord.wordIndex ?? 0, words.count - 1))
            byWord[index, default: []].append(chord)
        }
        return words.enumerated().map { index, word in
            Token(id: index, word: word, chords: byWord[index] ?? [])
        }
    }
}

/// Where the playhead sits on a lyric row: it enters at the row's leading
/// edge, reaches each timed word as it is sung (or, with line times only,
/// each chord's word as the chord starts), and finishes at the trailing
/// edge. Between those points it moves at a steady rate through the words,
/// wrapping from one visual line to the next. Pure geometry, so it can be
/// reasoned about.
enum LyricPlayhead {
    struct Point: Equatable {
        let x: CGFloat
        let y: CGFloat
        let height: CGFloat
    }
    struct Waypoint {
        let time: Double
        let x: CGFloat
        let line: CGRect  // the visual line's vertical extent
    }

    static func position(at time: Double, rowStart: Double, rowEnd: Double, chords: [SheetModel.Placed],
                         wordTimes: [Double]? = nil, tokens: [Int: CGRect], width: CGFloat, rtl: Bool) -> Point? {
        guard !tokens.isEmpty else { return nil }
        // Visual lines: tokens grouped by top edge.
        let lines = Dictionary(grouping: tokens.values, by: { $0.minY.rounded() }).values
            .map { rects in rects.reduce(rects[0]) { $0.union($1) } }
            .sorted { $0.minY < $1.minY }
        guard let first = lines.first, let last = lines.last else { return nil }
        let leading: (CGRect) -> CGFloat = { rtl ? $0.maxX : $0.minX }
        let trailing: (CGRect) -> CGFloat = { rtl ? $0.minX : $0.maxX }
        func line(containing rect: CGRect) -> CGRect { lines.first { $0.intersects(rect) } ?? first }

        var points = [Waypoint(time: rowStart, x: leading(first), line: first)]
        let timedWords = (wordTimes ?? []).enumerated().filter { $0.element > rowStart && $0.element < rowEnd }
        if !timedWords.isEmpty {
            // The voice drives the runner. Chords light at their own time above
            // their word; making them targets too would freeze the runner on the
            // word until the chord's slightly different time. Before the first
            // word it waits at the edge; after the last it finishes the line in
            // about a second and rests at the far edge.
            if let firstOnset = timedWords.first?.element, firstOnset - SheetModel.lastWordLength > rowStart {
                points.append(Waypoint(time: firstOnset - SheetModel.lastWordLength, x: leading(first), line: first))
            }
            for (index, onset) in timedWords where onset > points.last!.time {
                guard let rect = tokens[index] else { continue }
                points.append(Waypoint(time: onset, x: leading(rect), line: line(containing: rect)))
            }
            let finish = min(rowEnd, points.last!.time + SheetModel.lastWordLength)
            if finish > points.last!.time { points.append(Waypoint(time: finish, x: trailing(last), line: last)) }
            if rowEnd > finish { points.append(Waypoint(time: rowEnd, x: trailing(last), line: last)) }
        } else {
            // Line times only: chords are the only fixed points; steady motion between.
            let inside = chords.filter { $0.event.start > rowStart && $0.event.start < rowEnd }
                .sorted { $0.event.start < $1.event.start }
            for chord in inside where chord.event.start > points.last!.time {
                guard let rect = tokens[chord.wordIndex ?? 0] else { continue }
                points.append(Waypoint(time: chord.event.start, x: leading(rect), line: line(containing: rect)))
            }
            points.append(Waypoint(time: rowEnd, x: trailing(last), line: last))
        }

        let index = points.lastIndex { $0.time <= time } ?? 0
        let from = points[index]
        guard index + 1 < points.count else { return Point(x: from.x, y: from.line.midY, height: from.line.height) }
        let to = points[index + 1]
        let share = max(0, min(1, (time - from.time) / max(to.time - from.time, 0.001)))
        if from.line.minY == to.line.minY {
            return Point(x: from.x + (to.x - from.x) * share, y: from.line.midY, height: from.line.height)
        }
        // Wrap: run to the trailing edge of this line, then from the leading edge of the next.
        let firstLeg = abs(trailing(from.line) - from.x)
        let secondLeg = abs(to.x - leading(to.line))
        let total = max(firstLeg + secondLeg, 1)
        let travelled = share * total
        if travelled <= firstLeg {
            let x = from.x + (trailing(from.line) - from.x) * (firstLeg > 0 ? travelled / firstLeg : 1)
            return Point(x: x, y: from.line.midY, height: from.line.height)
        }
        let rest = travelled - firstLeg
        let x = leading(to.line) + (to.x - leading(to.line)) * (secondLeg > 0 ? rest / secondLeg : 1)
        return Point(x: x, y: to.line.midY, height: to.line.height)
    }
}
