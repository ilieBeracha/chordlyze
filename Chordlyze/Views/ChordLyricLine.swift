import SwiftUI

/// Chords above lyric tokens only where reliable word timestamps support it.
/// Rows with unanchored changes use ChordRowView's separate sequence instead
/// of inserting chords beside guessed word positions.
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
    var onChordTap: ((String) -> Void)? = nil
    var onLyricTap: (() -> Void)? = nil
    var verdict: ((Double) -> PracticeFeedback.Verdict?)? = nil
    var body: some View {
        let tokens = Self.tokens(text: text, chords: chords, words: words)
        ChordLyricFlow(spacing: style == .sheet ? 8 : 10) {
            ForEach(tokens) { token in
                VStack(alignment: .leading, spacing: style == .sheet ? 3 : 1) {
                    // The flow aligns each visual row at the lyric baseline.
                    // A wrapped row with no chord needs no empty chord band.
                    if !token.chords.isEmpty {
                        chordRow(token.chords)
                            .frame(minHeight: style == .sheet ? 24 : 30, alignment: .bottomLeading)
                    }
                    Text(token.word.isEmpty ? " " : token.word)
                        .font(style.wordFont)
                        .foregroundStyle(style == .live ? Color.white.opacity(0.86) : Palette.nearWhite)
                        .opacity(token.word.isEmpty ? 0 : 1)
                        .accessibilityHidden(token.word.isEmpty)
                        .onTapGesture { if !token.word.isEmpty { onLyricTap?() } }
                }
            }
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
                }
            }
        }
    }

    /// Split into words and attach each chord to the word it starts on.
    static func tokens(text: String, chords: [SheetModel.Placed], words supplied: [String]? = nil) -> [Token] {
        let words = supplied ?? text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        var byWord: [Int: [SheetModel.Placed]] = [:]
        var beforeWord: [Int: [SheetModel.Placed]] = [:]
        for chord in chords.sorted(by: { $0.event.start < $1.event.start }) {
            if let index = chord.wordIndex, words.indices.contains(index) {
                byWord[index, default: []].append(chord)
            } else {
                // Defensive fallback only: production rows route every
                // unanchored change through the separate chord sequence.
                beforeWord[words.count, default: []].append(chord)
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
        // Measurement and placement must wrap at the same width. Returning
        // only the occupied width lets a parent give us a narrower frame;
        // placing at that width can then require an unmeasured extra line.
        let measuredWidth = width.flatMap { $0.isFinite ? max(1, $0) : nil } ?? usedWidth
        return (CGSize(width: measuredWidth, height: y + height), frames)
    }
}
