import CoreGraphics
import Foundation

/// The guitar tab behind a Songsterr chart: its written measures, and each
/// bar as played (repeats unrolled) with its time in the recording.
struct SongTab: Decodable, Equatable {
    struct Note: Decodable, Equatable {
        /// 0 is the highest-pitched string.
        let string: Int
        let fret: Int
        var tie: Bool? = nil
        var dead: Bool? = nil

        /// A muted note shows as x; a tied note (drawn dimmed) keeps its fret.
        var label: String { dead == true ? "x" : "\(fret)" }
    }

    struct Beat: Decodable, Equatable {
        /// Length as a fraction of a whole note, tuplets and dots included.
        let duration: [Int]
        var rest: Bool? = nil
        var chord: String? = nil
        let notes: [Note]

        var length: Double {
            duration.count == 2 && duration[1] > 0 ? Double(duration[0]) / Double(duration[1]) : 0
        }
    }

    struct Measure: Decodable, Equatable {
        var marker: String? = nil
        let beats: [Beat]
    }

    /// One played bar: which written measure, and when it sounds.
    struct Bar: Decodable, Equatable {
        let measure: Int
        let start: Double
        let end: Double
    }

    let name: String
    /// MIDI note per string, highest string first.
    let tuning: [Int]
    let capo: Int
    let measures: [Measure]
    let bars: [Bar]

    var strings: Int { tuning.count }

    /// The bars starting in [start, end), as measures in playing order.
    func measures(from start: Double, to end: Double) -> [Measure] {
        bars.filter { $0.start >= start && $0.start < end && measures.indices.contains($0.measure) }
            .map { measures[$0.measure] }
    }
}

/// Lays measures out in rows that fit the screen. Beats take room in
/// proportion to their length, never less than a fret number needs. Rows
/// break between measures; a measure wider than a row continues on the next.
enum TabLayout {
    static let wholeNoteWidth: CGFloat = 120
    static let minBeatWidth: CGFloat = 22
    /// Space between a bar line and the first or last beat.
    static let barPadding: CGFloat = 8

    struct Placed: Equatable {
        let measure: Int
        let beat: Int
        /// Centre of the beat's column from the row's left edge.
        let x: CGFloat
    }

    struct Marker: Equatable {
        let x: CGFloat
        let text: String
    }

    struct Row: Equatable {
        var beats: [Placed] = []
        /// Bar lines, from the row's left edge.
        var bars: [CGFloat] = []
        /// Section names at the measure starts they label.
        var markers: [Marker] = []
        var width: CGFloat = 0
    }

    static func beatWidth(_ beat: SongTab.Beat) -> CGFloat {
        max(minBeatWidth, wholeNoteWidth * beat.length)
    }

    static func rows(_ measures: [SongTab.Measure], width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        func finish() {
            if !row.beats.isEmpty { rows.append(row) }
            row = Row()
        }
        for (m, measure) in measures.enumerated() {
            let measureWidth = measure.beats.map(beatWidth).reduce(barPadding * 2, +)
            if !row.beats.isEmpty && row.width + measureWidth > width { finish() }
            if row.bars.last != row.width { row.bars.append(row.width) }
            if let marker = measure.marker { row.markers.append(Marker(x: row.width, text: marker)) }
            row.width += barPadding
            for (b, beat) in measure.beats.enumerated() {
                let w = beatWidth(beat)
                if row.width + w + barPadding > width && row.beats.last?.measure == m {
                    // The measure continues on the next row, without a bar line between.
                    finish()
                    row.width = barPadding
                }
                row.beats.append(Placed(measure: m, beat: b, x: row.width + w / 2))
                row.width += w
            }
            row.width += barPadding
            row.bars.append(row.width)
        }
        finish()
        return rows
    }
}
