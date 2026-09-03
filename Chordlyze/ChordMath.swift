import Foundation

/// Transposition + capo suggestion over display chord names ("C", "F#m", "B°", "C/E").
enum ChordMath {
    /// Easy open-position shapes on guitar.
    private static let openShapes: Set<String> = ["C", "A", "G", "E", "D", "Am", "Em", "Dm"]

    /// "F#m" shifted by −2 → "Em"; a slash bass moves with it. Non-chords pass through untouched.
    static func transpose(_ display: String, by semitones: Int) -> String {
        guard semitones != 0, let chord = Chord(display: display) else { return display }
        return chord.transposed(by: semitones).display
    }

    /// Capo fret (0–9) that turns the most playing time into open shapes.
    /// Display chords are the original transposed DOWN by the capo.
    static func autoCapo(names durations: [(display: String, duration: Double)]) -> Int {
        var best = (capo: 0, score: -1.0)
        for capo in 0...9 {
            var score = 0.0
            for (display, duration) in durations {
                if openShapes.contains(transpose(display, by: -capo)) {
                    score += duration
                }
            }
            if score > best.score {
                best = (capo, score)
            }
        }
        return best.capo
    }
}
