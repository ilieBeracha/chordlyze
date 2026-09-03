import SwiftUI

/// One lyric line with each chord pinned above the word where it lands
/// (chord time interpolated into the line's time window, ChordPro-style).
struct ChordLyricLine: View {
    struct Token: Identifiable {
        let id: Int
        let word: String
        let chords: [SheetModel.PlacedChord]
    }

    let text: String
    let chords: [SheetModel.PlacedChord]
    var wordFont: Font = .system(size: 30, weight: .bold, design: .rounded)
    var chordFont: Font = .system(size: 18, weight: .heavy, design: .rounded)
    var onChordTap: ((String) -> Void)? = nil

    var body: some View {
        let tokens = Self.tokens(text: text, chords: chords)
        let hasChords = !chords.isEmpty
        FlowLayout(spacing: 9) {
            ForEach(tokens) { token in
                VStack(alignment: .leading, spacing: 3) {
                    if hasChords {
                        chordRow(token.chords)
                    }
                    Text(token.word)
                        .font(wordFont)
                        .foregroundStyle(.white)
                }
            }
        }
    }

    @ViewBuilder
    private func chordRow(_ placed: [SheetModel.PlacedChord]) -> some View {
        if placed.isEmpty {
            Text(" ").font(chordFont)  // keeps every word's baseline aligned
        } else {
            HStack(spacing: 6) {
                ForEach(placed) { chord in
                    Button {
                        onChordTap?(chord.name)
                    } label: {
                        Text(chord.name)
                            .font(chordFont)
                            .foregroundStyle(Color.spotifyGreen)
                    }
                    .buttonStyle(.plain)
                    .disabled(onChordTap == nil)
                }
            }
        }
    }

    /// Split into words and attach each chord to the word its position lands on.
    /// Words are weighted by syllable count — singing time tracks syllables,
    /// not characters.
    static func tokens(text: String, chords: [SheetModel.PlacedChord]) -> [Token] {
        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let weights = SheetModel.syllableWeights(words: words).map(Double.init)
        let total = weights.reduce(0, +)

        // Fractional syllable range each word covers.
        var ranges: [(start: Double, end: Double)] = []
        var consumed = 0.0
        for weight in weights {
            let start = consumed / total
            consumed += weight
            ranges.append((start, consumed / total))
        }

        var byWord: [Int: [SheetModel.PlacedChord]] = [:]
        for chord in chords {
            // Exact word timestamp wins; otherwise syllable interpolation.
            let index = chord.wordIndex.map { min($0, words.count - 1) }
                ?? ranges.lastIndex(where: { $0.start <= chord.position }) ?? 0
            byWord[index, default: []].append(chord)
        }
        return words.enumerated().map { index, word in
            Token(id: index, word: word, chords: byWord[index] ?? [])
        }
    }
}
