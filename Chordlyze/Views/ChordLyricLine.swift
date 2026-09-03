import SwiftUI

/// One lyric line with each chord pinned above the word it starts on. Only
/// used when the lyrics carry word timestamps: the word index comes from the
/// timeline, nothing here guesses.
struct ChordLyricLine: View {
    struct Token: Identifiable {
        let id: Int
        let word: String
        let chords: [SheetModel.Placed]
    }

    let text: String
    let chords: [SheetModel.Placed]
    var transposeBy = 0
    var playhead: Double? = nil
    var style: ChordRowView.Style = .live
    var onChordTap: ((String) -> Void)? = nil

    var body: some View {
        let tokens = Self.tokens(text: text, chords: chords)
        let hasChords = !chords.isEmpty
        FlowLayout(spacing: style == .sheet ? 6 : 9) {
            ForEach(tokens) { token in
                VStack(alignment: .leading, spacing: 3) {
                    if hasChords {
                        chordRow(token.chords)
                    }
                    Text(token.word)
                        .font(style.wordFont)
                        .foregroundStyle(style == .sheet ? Palette.nearWhite : .white)
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
    static func tokens(text: String, chords: [SheetModel.Placed]) -> [Token] {
        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        var byWord: [Int: [SheetModel.Placed]] = [:]
        for chord in chords {
            let index = min(chord.wordIndex ?? 0, words.count - 1)
            byWord[index, default: []].append(chord)
        }
        return words.enumerated().map { index, word in
            Token(id: index, word: word, chords: byWord[index] ?? [])
        }
    }
}
