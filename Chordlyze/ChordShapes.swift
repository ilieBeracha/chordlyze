import Foundation

/// Guitar fingerings and piano voicings. Open-position chords are the shapes
/// every player knows; everything else comes from movable barre forms, so
/// any root with a known quality has a diagram.
enum ChordShapes {
    /// 6 strings low-E→high-E: -1 muted, 0 open, n = fret. `baseFret` shifts the grid.
    struct GuitarShape: Equatable {
        let frets: [Int]
        let baseFret: Int

        init(_ frets: [Int], base: Int = 1) {
            self.frets = frets
            self.baseFret = base
        }

        /// Highest fret pressed; 0 for an all-open shape.
        var top: Int { frets.max() ?? 0 }
    }

    /// Open-position shapes, keyed by display name in root position.
    static let open: [String: GuitarShape] = [
        "C":  .init([-1, 3, 2, 0, 1, 0]),
        "D":  .init([-1, -1, 0, 2, 3, 2]),
        "E":  .init([0, 2, 2, 1, 0, 0]),
        "G":  .init([3, 2, 0, 0, 0, 3]),
        "A":  .init([-1, 0, 2, 2, 2, 0]),
        "Dm": .init([-1, -1, 0, 2, 3, 1]),
        "Em": .init([0, 2, 2, 0, 0, 0]),
        "Am": .init([-1, 0, 2, 2, 1, 0]),
        "C7": .init([-1, 3, 2, 3, 1, 0]),
        "D7": .init([-1, -1, 0, 2, 1, 2]),
        "E7": .init([0, 2, 0, 1, 0, 0]),
        "G7": .init([3, 2, 0, 0, 0, 1]),
        "A7": .init([-1, 0, 2, 0, 2, 0]),
        "B7": .init([-1, 2, 1, 2, 0, 2]),
        "Cmaj7": .init([-1, 3, 2, 0, 0, 0]),
        "Dmaj7": .init([-1, -1, 0, 2, 2, 2]),
        "Emaj7": .init([0, 2, 1, 1, 0, 0]),
        "Gmaj7": .init([3, 2, 0, 0, 0, 2]),
        "Amaj7": .init([-1, 0, 2, 1, 2, 0]),
        "Dm7": .init([-1, -1, 0, 2, 1, 1]),
        "Em7": .init([0, 2, 0, 0, 0, 0]),
        "Am7": .init([-1, 0, 2, 0, 1, 0]),
        "Dsus2": .init([-1, -1, 0, 2, 3, 0]),
        "Dsus4": .init([-1, -1, 0, 2, 3, 3]),
        "Esus4": .init([0, 2, 2, 2, 0, 0]),
        "Asus2": .init([-1, 0, 2, 2, 0, 0]),
        "Asus4": .init([-1, 0, 2, 2, 3, 0]),
        "Csus2": .init([-1, 3, 0, 0, 1, 3]),
        "Gsus4": .init([3, 3, 0, 0, 1, 3]),
        "C6": .init([-1, 3, 2, 2, 1, 0]),
        "A6": .init([-1, 0, 2, 2, 2, 2]),
        "Am6": .init([-1, 0, 2, 2, 1, 2]),
        "E9": .init([0, 2, 0, 1, 0, 2]),
        "A9": .init([-1, 0, 2, 4, 2, 3]),
        "E7sus4": .init([0, 2, 0, 2, 0, 0]),
        "A7sus4": .init([-1, 0, 2, 0, 3, 0]),
    ]

    /// Movable forms: fret offsets from the root fret, per string; nil = muted.
    /// `rootString` 6 puts the root on the low E (E form), 5 on the A (A form).
    private struct Form {
        let rootString: Int
        let offsets: [Int?]
    }

    /// Forms by Harte quality. Where both forms exist the lower one on the neck wins.
    private static let forms: [String: [Form]] = [
        "maj": [Form(rootString: 6, offsets: [0, 2, 2, 1, 0, 0]), Form(rootString: 5, offsets: [nil, 0, 2, 2, 2, 0])],
        "min": [Form(rootString: 6, offsets: [0, 2, 2, 0, 0, 0]), Form(rootString: 5, offsets: [nil, 0, 2, 2, 1, 0])],
        "7": [Form(rootString: 6, offsets: [0, 2, 0, 1, 0, 0]), Form(rootString: 5, offsets: [nil, 0, 2, 0, 2, 0])],
        "maj7": [Form(rootString: 6, offsets: [0, 2, 1, 1, 0, 0]), Form(rootString: 5, offsets: [nil, 0, 2, 1, 2, 0])],
        "min7": [Form(rootString: 6, offsets: [0, 2, 0, 0, 0, 0]), Form(rootString: 5, offsets: [nil, 0, 2, 0, 1, 0])],
        "sus2": [Form(rootString: 5, offsets: [nil, 0, 2, 2, 0, 0]), Form(rootString: 6, offsets: [0, 2, 2, -1, 0, 0])],
        "sus4": [Form(rootString: 6, offsets: [0, 2, 2, 2, 0, 0]), Form(rootString: 5, offsets: [nil, 0, 2, 2, 3, 0])],
        "sus4(b7)": [Form(rootString: 6, offsets: [0, 2, 0, 2, 0, 0]), Form(rootString: 5, offsets: [nil, 0, 2, 0, 3, 0])],
        "dim": [Form(rootString: 5, offsets: [nil, 0, 1, 2, 1, nil]), Form(rootString: 6, offsets: [0, 1, 2, 0, nil, nil])],
        "dim7": [Form(rootString: 5, offsets: [nil, 0, 1, -1, 1, nil]), Form(rootString: 6, offsets: [0, nil, -1, 0, -1, nil])],
        "hdim7": [Form(rootString: 5, offsets: [nil, 0, 1, 0, 1, nil]), Form(rootString: 6, offsets: [0, nil, 0, 0, -1, nil])],
        "aug": [Form(rootString: 5, offsets: [nil, 0, 3, 2, 2, nil]), Form(rootString: 6, offsets: [0, nil, 2, 1, 1, nil])],
        "maj6": [Form(rootString: 5, offsets: [nil, 0, 2, 2, 2, 2]), Form(rootString: 6, offsets: [0, nil, 2, 1, 2, nil])],
        "min6": [Form(rootString: 5, offsets: [nil, 0, 2, 2, 1, 2]), Form(rootString: 6, offsets: [0, nil, 2, 0, 2, nil])],
        "minmaj7": [Form(rootString: 5, offsets: [nil, 0, 2, 1, 1, nil]), Form(rootString: 6, offsets: [0, nil, 1, 0, 0, nil])],
        "9": [Form(rootString: 5, offsets: [nil, 0, -1, 0, 0, 0]), Form(rootString: 6, offsets: [0, nil, 0, 1, 0, 2])],
        "maj9": [Form(rootString: 5, offsets: [nil, 0, -1, 1, 0, nil]), Form(rootString: 6, offsets: [0, nil, 1, 1, 0, 2])],
        "min9": [Form(rootString: 5, offsets: [nil, 0, -2, 0, 0, 0]), Form(rootString: 6, offsets: [0, nil, 0, 0, 0, 2])],
        "11": [Form(rootString: 5, offsets: [nil, 0, 0, 0, 0, 0]), Form(rootString: 6, offsets: [0, 0, 0, nil, 0, 0])],
        "13": [Form(rootString: 6, offsets: [0, nil, 0, 1, 2, nil]), Form(rootString: 5, offsets: [nil, 0, -1, 0, 0, 2])],
    ]

    /// Pitch class of each open string, low E first.
    private static let openStrings = [4, 9, 2, 7, 11, 4]
    /// Highest fret a shape may reach; above it the form an octave lower is used.
    private static let highestFret = 15

    /// How to play a chord by its display name ("F#m7/A" plays as F#m7);
    /// nil for "N.C." or a quality without a form.
    static func guitar(_ display: String) -> GuitarShape? {
        guard let chord = Chord(display: display) else { return nil }
        return guitar(chord.withoutBass)
    }

    static func guitar(_ chord: Chord) -> GuitarShape? {
        let chord = chord.withoutBass
        if let shape = open[chord.display] { return shape }
        guard let forms = forms[chord.quality.harte] else { return nil }
        let candidates = forms.compactMap { form -> GuitarShape? in
            let string = openStrings[6 - form.rootString]
            var root = ((chord.root - string) % 12 + 12) % 12
            // A form whose lowest offset digs below the nut moves up an octave.
            let lowest = form.offsets.compactMap { $0 }.min() ?? 0
            if root + lowest < 0 { root += 12 }
            let frets = form.offsets.map { $0.map { root + $0 } ?? -1 }
            guard let top = frets.max(), top <= highestFret else { return nil }
            return GuitarShape(frets, base: baseFret(for: frets))
        }
        return candidates.min { $0.top < $1.top }
    }

    /// The grid shows four frets: from the nut when the shape fits there,
    /// else from the lowest fretted note.
    static func baseFret(for frets: [Int]) -> Int {
        let pressed = frets.filter { $0 > 0 }
        guard let top = pressed.max(), let low = pressed.min(), top > 4 else { return 1 }
        return max(1, top - low <= 3 ? low : top - 3)
    }

    /// Pitch classes (0 = C) sounding in the chord, for the piano strip; nil
    /// for a quality the app cannot voice.
    static func pianoNotes(for display: String) -> [Int]? {
        Chord(display: display)?.pitchClasses
    }
}
