import Foundation

/// Merges a chord analysis with synced lyrics into per-line chord placements.
/// Real analyzed chords are exact; beyond the analyzed window (or for preview
/// excerpts with unknown alignment) the song's loop continues as estimates.
enum SheetModel {
    struct PlacedChord: Identifiable {
        let id = UUID()
        let name: String
        let estimated: Bool
        /// Where in the line this chord lands, 0…1 (fraction of the line's time
        /// window) — used to pin the chord above the right word.
        let position: Double
    }

    struct RenderLine: Identifiable {
        let id: Double      // line start time
        let end: Double
        let text: String
        let chords: [PlacedChord]

        func contains(_ time: Double) -> Bool { time >= id && time < end }
    }

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
            let end = index + 1 < lines.count ? lines[index + 1].time : line.time + 6
            let window = max(0.5, end - line.time)
            var chords: [PlacedChord] = []
            if line.time < analyzedEnd {
                chords = real
                    .filter { $0.start >= line.time && $0.start < end }
                    .map { seg in
                        PlacedChord(name: seg.displayName, estimated: false,
                                    position: min(1, max(0, (seg.start - line.time) / window)))
                    }
            } else {
                let count = max(1, min(3, Int((window / period).rounded())))
                chords = (0..<count).map { i in
                    defer { phase += 1 }
                    return PlacedChord(name: loop[phase % loop.count], estimated: true,
                                       position: Double(i) / Double(count))
                }
            }
            result.append(RenderLine(id: line.time, end: end, text: line.text, chords: chords))
        }
        return result
    }
}
