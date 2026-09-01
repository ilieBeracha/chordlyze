import Foundation

/// Merges a chord analysis with synced lyrics into per-line chord placements.
/// Real analyzed chords are exact; beyond the analyzed window (or for preview
/// excerpts with unknown alignment) the song's loop continues as estimates.
/// Long gaps between sung lines become chord-only instrumental lines.
enum SheetModel {
    struct PlacedChord: Identifiable {
        let id = UUID()
        let name: String
        let estimated: Bool
        /// Where in the line's sung window this chord lands, 0…1 — used to pin
        /// the chord above the right word.
        let position: Double
        /// Exact word this chord strikes on, when the lyrics carry word-level
        /// timestamps. Overrides the interpolated `position`.
        var wordIndex: Int? = nil
    }

    struct RenderLine: Identifiable {
        let id: Double      // line start time
        let end: Double
        let text: String
        let chords: [PlacedChord]
        var isInstrumental = false

        func contains(_ time: Double) -> Bool { time >= id && time < end }
    }

    /// Gap longer than this after a sung line becomes its own instrumental line.
    private static let breakThreshold: Double = 5

    static func build(analysis: ChordAnalysis, lines: [LyricLine]) -> [RenderLine] {
        let real = analysis.chords.filter { $0.label != "N" }
        guard !real.isEmpty else {
            return lines.enumerated().map { index, line in
                RenderLine(id: line.time,
                           end: index + 1 < lines.count ? lines[index + 1].time : line.time + 6,
                           text: line.text, chords: [])
            }
        }

        var loop: [String] = []
        for seg in real where loop.last != seg.displayName {
            if loop.count == 8 { break }
            loop.append(seg.displayName)
        }
        let durations = real.map(\.duration).sorted()
        let period = max(1.5, durations[durations.count / 2])

        let previewMode = analysis.source == "itunes_preview"
        let analyzedEnd = previewMode ? 0 : (real.last?.end ?? 0)

        var phase = 0
        var result: [RenderLine] = []
        for (index, line) in lines.enumerated() {
            let gapEnd = index + 1 < lines.count ? lines[index + 1].time : line.time + 6
            let gap = max(0.5, gapEnd - line.time)

            if line.time < analyzedEnd {
                // How long the line is actually sung; the rest of the gap is music.
                // Word timestamps (enhanced LRC) beat the syllable estimate.
                let sung: Double
                if let lastWord = line.words?.last, lastWord.time > line.time {
                    sung = min(gap, lastWord.time - line.time + 1.2)
                } else {
                    sung = min(gap, sungDuration(line.text))
                }
                let breakLength = gap - sung
                let splitAt = breakLength > breakThreshold ? line.time + sung : gapEnd

                let chords = real
                    .filter { $0.start >= line.time && $0.start < splitAt }
                    .map { seg in
                        PlacedChord(name: seg.displayName, estimated: false,
                                    position: min(1, max(0, (seg.start - line.time) / sung)),
                                    wordIndex: line.words?.lastIndex(where: { $0.time <= seg.start }))
                    }
                result.append(RenderLine(id: line.time, end: splitAt,
                                         text: line.text, chords: chords))

                if splitAt < gapEnd {
                    let breakChords = real
                        .filter { $0.start >= splitAt && $0.start < gapEnd }
                        .map { seg in
                            PlacedChord(name: seg.displayName, estimated: false,
                                        position: min(1, max(0, (seg.start - splitAt) / (gapEnd - splitAt))))
                        }
                    result.append(RenderLine(id: splitAt, end: gapEnd, text: "♪",
                                             chords: breakChords, isInstrumental: true))
                }
            } else {
                // Beyond the analyzed window: loop the progression as estimates.
                let count = max(1, min(3, Int((gap / period).rounded())))
                let chords = (0..<count).map { i in
                    defer { phase += 1 }
                    return PlacedChord(name: loop[phase % loop.count], estimated: true,
                                       position: Double(i) / Double(count))
                }
                result.append(RenderLine(id: line.time, end: gapEnd,
                                         text: line.text, chords: chords))
            }
        }
        return result
    }

    // MARK: - Singing-time estimation

    /// Rough seconds a lyric line takes to sing: syllables at a moderate pace.
    static func sungDuration(_ text: String) -> Double {
        min(max(Double(syllableCount(text)) * 0.35, 1.5), 8)
    }

    /// Vowel-group syllable estimate; non-Latin scripts fall back to word count.
    static func syllableCount(_ text: String) -> Int {
        let vowels = Set("aeiouyAEIOUYàèéìòùáéíóúäëïöü")
        var count = 0
        var inGroup = false
        for ch in text {
            if vowels.contains(ch) {
                if !inGroup { count += 1; inGroup = true }
            } else {
                inGroup = false
            }
        }
        let words = text.split(separator: " ").count
        return max(count, words, 1)
    }

    /// Per-word syllable weights for pinning chords to words (0-weight never wins).
    static func syllableWeights(words: [String]) -> [Int] {
        words.map { max(1, syllableCount($0)) }
    }
}
