import SwiftUI

/// Chords above lyric tokens only where reliable word timestamps support it.
/// Changes between timed words occupy their own cells, preserving chronology
/// without detaching valid anchors elsewhere in the phrase.
struct ChordLyricLine: View {
    struct Token: Identifiable {
        let id: Int
        let wordIndex: Int?
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
        let tokens = Self.tokens(text: text, chords: chords, words: words, wordTimes: wordTimes)
        let hasChords = !chords.isEmpty
        ChordLyricFlow(spacing: style == .sheet ? 8 : 10) {
            ForEach(tokens) { token in
                VStack(alignment: .leading, spacing: style == .sheet ? 3 : 1) {
                    if hasChords {
                        chordRow(token.chords)
                            .frame(minHeight: style == .sheet ? 24 : 30, alignment: .bottomLeading)
                    }
                    Text(token.word.isEmpty ? " " : token.word)
                        .font(style.wordFont(active: active))
                        .foregroundStyle(wordColor(token.wordIndex ?? -100))
                        .opacity(token.word.isEmpty ? 0 : 1)
                        .accessibilityHidden(token.word.isEmpty)
                        .shadow(color: .white.opacity((token.wordIndex.map(glow) ?? 0) * 0.45), radius: 10)
                        .animation(.easeOut(duration: 0.14), value: currentWord)
                        .animation(.easeInOut(duration: 0.35), value: betweenWords)
                        .animation(.easeInOut(duration: 0.45), value: active)
                        .onTapGesture { if !token.word.isEmpty { onLyricTap?() } }
                }
            }
        }
        .overlayPreferenceValue(ChangeAnchors.self) { anchors in
            // Mixed rows previously had a timed cursor in their detached band.
            // Keep that cursor, now following the actual in-line chord bounds.
            if style == .live, chords.contains(where: { $0.wordIndex == nil }),
               let playhead, let first = chords.first,
               playhead >= first.event.start, playhead >= rowStart, playhead < rowEnd {
                GeometryReader { geometry in
                    let ordered = chords.sorted { $0.event.start < $1.event.start }
                    let bounds = Dictionary(uniqueKeysWithValues: ordered.enumerated().compactMap { index, chord in
                        anchors[chord.event.start].map { (index, geometry[$0]) }
                    })
                    let points = LyricPlayhead.waypoints(rowStart: rowStart, rowEnd: rowEnd, words: bounds,
                        wordTimes: nil, chordStarts: ordered.enumerated().map { ($0.element.event.start, $0.offset) }, rtl: text.isRTLText)
                    if let point = LyricPlayhead.position(at: playhead, along: points, rtl: text.isRTLText, eased: false) {
                        RoundedRectangle(cornerRadius: 1).fill(Color.spotifyGreen.opacity(0.5))
                            .frame(width: 2, height: point.height + 4)
                            .position(x: point.x, y: point.y).allowsHitTesting(false)
                    }
                }
            }
        }
    }

    private struct ChangeAnchors: PreferenceKey {
        static var defaultValue: [Double: Anchor<CGRect>] = [:]
        static func reduce(value: inout [Double: Anchor<CGRect>], nextValue: () -> [Double: Anchor<CGRect>]) {
            value.merge(nextValue(), uniquingKeysWith: { $1 })
        }
    }

    @ViewBuilder
    private func chordRow(_ placed: [SheetModel.Placed]) -> some View {
        if placed.isEmpty {
            Text(" ").font(style.chordFont)  // keeps every word's baseline aligned
        } else {
            ChordLyricFlow(spacing: 10) {
                ForEach(placed) { chord in
                    ChordChip(name: chord.event.display(transposedBy: transposeBy),
                              active: playhead.map(chord.event.contains) ?? false,
                              style: style, playing: playhead != nil, onTap: onChordTap, verdict: verdict?(chord.event.start))
                        .anchorPreference(key: ChangeAnchors.self, value: .bounds) { [chord.event.start: $0] }
                }
            }
        }
    }

    /// Split into words and attach each chord to the word it starts on.
    static func tokens(text: String, chords: [SheetModel.Placed], words supplied: [String]? = nil,
                       wordTimes: [Double]? = nil) -> [Token] {
        let words = supplied ?? text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        var byWord: [Int: [SheetModel.Placed]] = [:]
        var beforeWord: [Int: [SheetModel.Placed]] = [:]
        for chord in chords.sorted(by: { $0.event.start < $1.event.start }) {
            if let index = chord.wordIndex, words.indices.contains(index) {
                byWord[index, default: []].append(chord)
            } else {
                let next = wordTimes?.firstIndex(where: { $0 > chord.event.start }) ?? words.count
                beforeWord[min(next, words.count), default: []].append(chord)
            }
        }
        var result: [Token] = []
        for index in 0...words.count {
            for chord in beforeWord[index] ?? [] {
                result.append(Token(id: result.count, wordIndex: nil, word: "", chords: [chord]))
            }
            if index < words.count {
                result.append(Token(id: result.count, wordIndex: index, word: words[index], chords: byWord[index] ?? []))
            }
        }
        return result
    }
}

/// Wrap whole word/chord cells together, constrain oversized cells to the
/// viewport, and align lyric baselines after measuring the whole visual row.
/// Only these song rows use it; other screens retain their existing layout.
struct ChordLyricFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            // SwiftUI handles RTL mirroring for custom layouts.
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private func arrange(width: CGFloat?, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let limit = max(1, width ?? .infinity)
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0, usedWidth: CGFloat = 0
        var rowStart = 0
        func finishRow() {
            for index in rowStart..<frames.count { frames[index].origin.y = y + height - frames[index].height }
        }
        for subview in subviews {
            let natural = subview.sizeThatFits(.unspecified)
            let measured = subview.sizeThatFits(ProposedViewSize(width: min(natural.width, limit), height: nil))
            let size = CGSize(width: min(measured.width, limit), height: measured.height)
            if x > 0, x + size.width > limit {
                finishRow()
                y += height + spacing
                x = 0; height = 0; rowStart = frames.count
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + spacing
            height = max(height, size.height)
            usedWidth = max(usedWidth, x - spacing)
        }
        finishRow()
        return (CGSize(width: usedWidth, height: y + height), frames)
    }
}
