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
    /// The row's span in song time, for the runner in Live.
    var rowStart: Double = 0
    var rowEnd: Double = 0
    /// Onset of each word when the lyrics are word-timed (same order as
    /// `words`); the runner and the word highlight then follow the voice.
    var wordTimes: [Double]? = nil
    /// Calibrated song time for the words, without the chord display lead:
    /// a word is sung when it is sung, chords may be shown a little early.
    var wordPlayhead: Double? = nil

    private var currentWord: Int? {
        guard let wordTimes, let wordPlayhead, wordPlayhead >= rowStart, wordPlayhead < rowEnd else { return nil }
        return LyricPlayhead.currentWord(at: wordPlayhead, wordTimes: wordTimes)
    }

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
                        .foregroundStyle(currentWord == token.id ? Color.spotifyGreen : style.wordColor(active: active))
                        .onTapGesture { onLyricTap?() }
                        // The word's own text bounds, not the word-and-chords column.
                        .anchorPreference(key: WordAnchors.self, value: .bounds) { [token.id: $0] }
                }
            }
        }
        .overlayPreferenceValue(WordAnchors.self) { anchors in
            if style == .live, let wordPlayhead, rowEnd > rowStart, wordPlayhead >= rowStart, wordPlayhead < rowEnd {
                GeometryReader { geo in
                    let points = LyricPlayhead.waypoints(rowStart: rowStart, rowEnd: rowEnd, words: anchors.mapValues { geo[$0] },
                                                         wordTimes: wordTimes,
                                                         chordStarts: chords.map { ($0.event.start, $0.wordIndex ?? 0) }, rtl: rtl)
                    if let point = LyricPlayhead.position(at: wordPlayhead, along: points, rtl: rtl) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.spotifyGreen.opacity(0.7))
                            .frame(width: 2, height: point.height + 6)
                            .position(x: point.x, y: point.y)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    private var rtl: Bool { text.isRTLText }

    struct WordAnchors: PreferenceKey {
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
