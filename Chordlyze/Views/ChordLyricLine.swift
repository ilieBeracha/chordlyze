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
    var onChordTap: ((String) -> Void)? = nil
    var onLyricTap: (() -> Void)? = nil

    var body: some View {
        let tokens = Self.tokens(text: text, chords: chords, words: words)
        let hasChords = !chords.isEmpty
        FlowLayout(spacing: style == .sheet ? 6 : 9) {
            ForEach(tokens) { token in
                VStack(alignment: .leading, spacing: 3) {
                    if hasChords {
                        chordRow(token.chords)
                            .frame(minHeight: style == .sheet ? 28 : 38, alignment: .bottomLeading)
                    } else if token.id == 0 {
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
            }
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
                              style: style, onTap: onChordTap)
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
