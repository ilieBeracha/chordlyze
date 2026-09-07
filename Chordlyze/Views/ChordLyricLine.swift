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
    /// When each word stops sounding, where the transcript heard it.
    var wordEnds: [Double?]? = nil

    /// After a word has ended and before the next begins, the light settles:
    /// the pulse is the word's own length, not the gap after it.
    private var betweenWords: Bool {
        guard let currentWord, let wordEnds, currentWord < wordEnds.count, let end = wordEnds[currentWord],
              let wordPlayhead else { return false }
        return wordPlayhead > end + 0.15
    }

    private var currentWord: Int? {
        guard let wordTimes, let wordPlayhead, wordPlayhead >= rowStart, wordPlayhead < rowEnd else { return nil }
        return LyricPlayhead.currentWord(at: wordPlayhead, wordTimes: wordTimes)
    }

    /// A soft cloud of light over the voice: the sung word full white, the
    /// words either side partly lit, fading out two words away. Nothing is
    /// coloured; the rest of the line sits back in grey.
    private func glow(_ index: Int) -> Double {
        guard let currentWord else { return 0 }
        let rest = betweenWords ? 0.45 : 1.0
        switch abs(index - currentWord) {
        case 0: return rest
        case 1: return 0.55 * rest
        case 2: return 0.25 * rest
        default: return 0
        }
    }

    private func wordColor(_ index: Int) -> Color {
        guard currentWord != nil else { return style.wordColor(active: active) }
        return Color.white.opacity(0.38 + 0.62 * glow(index))
    }


    var body: some View {
        let tokens = Self.tokens(text: text, chords: chords, words: words)
        let hasChords = !chords.isEmpty
        FlowLayout(spacing: style == .sheet ? 8 : 10) {
            ForEach(tokens) { token in
                VStack(alignment: .leading, spacing: style == .sheet ? 3 : 1) {
                    if hasChords {
                        chordRow(token.chords)
                            .frame(minHeight: style == .sheet ? 24 : 30, alignment: .bottomLeading)
                    } else if token.id == 0, pending {
                        Text("—")
                            .font(style.chordFont)
                            .foregroundStyle(Palette.tertiary)
                            .frame(minHeight: style == .sheet ? 24 : 30, alignment: .bottomLeading)
                            .accessibilityLabel("Chords not available yet")
                    } else {
                        Color.clear.frame(height: style == .sheet ? 24 : 30)
                    }
                    Text(token.word)
                        .font(style.wordFont(active: active))
                        .foregroundStyle(wordColor(token.id))
                        .shadow(color: .white.opacity(glow(token.id) * 0.45), radius: 10)
                        .animation(.easeOut(duration: 0.14), value: currentWord)
                        .animation(.easeInOut(duration: 0.35), value: betweenWords)
                        .animation(.easeInOut(duration: 0.45), value: active)
                        .onTapGesture { onLyricTap?() }
                        // The word's own text bounds, not the word-and-chords column.
                        .anchorPreference(key: WordAnchors.self, value: .bounds) { [token.id: $0] }
                }
            }
        }
        .overlayPreferenceValue(WordAnchors.self) { anchors in
            // The runner only on lines without word timing: with words timed, the
            // sung word lights and a moving line just makes the player chase it.
            if style == .live, wordTimes == nil, let wordPlayhead, rowEnd > rowStart, wordPlayhead >= rowStart, wordPlayhead < rowEnd {
                GeometryReader { geo in
                    let points = LyricPlayhead.waypoints(rowStart: rowStart, rowEnd: rowEnd, words: anchors.mapValues { geo[$0] },
                                                         wordTimes: nil,
                                                         chordStarts: chords.map { ($0.event.start, $0.wordIndex ?? 0) }, rtl: rtl)
                    if let point = LyricPlayhead.position(at: wordPlayhead, along: points, rtl: rtl) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.spotifyGreen.opacity(0.5))
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
            HStack(spacing: 10) {
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
