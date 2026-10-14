import CoreGraphics
import Foundation

private var checks = 0
private func check(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !value() { fatalError(message) }
}

private func beat(_ n: Int, _ d: Int) -> SongTab.Beat {
    SongTab.Beat(duration: [n, d], notes: [SongTab.Note(string: 0, fret: 3)])
}

@main struct SongTabTests {
    static func main() {
        // The backend's tab decodes, flags included; bars pick measures by time.
        let json = """
        {"index": 2, "name": "Rhythm", "tuning": [64, 59, 55, 50, 45, 38], "capo": 2, "measures": [
           {"marker": "Intro", "beats": [
             {"duration": [1, 2], "chord": "Em7", "notes": [{"string": 0, "fret": 3}, {"string": 5, "fret": 0, "tie": true}]},
             {"duration": [1, 2], "rest": true, "notes": []}]},
           {"beats": [{"duration": [1, 1], "notes": [{"string": 4, "fret": 7, "dead": true}]}]}],
         "bars": [{"measure": 0, "start": 5, "end": 7}, {"measure": 1, "start": 7, "end": 9},
                  {"measure": 0, "start": 9, "end": 11}]}
        """
        let tab = try! JSONDecoder().decode(SongTab.self, from: Data(json.utf8))
        check(tab.capo == 2 && tab.strings == 6, "part fields")
        let first = tab.measures[0]
        check(first.marker == "Intro" && first.beats[0].chord == "Em7" && first.beats[1].rest == true, "measure fields")
        check(first.beats[0].length == 0.5, "beat length is a fraction of a whole note")
        check(first.beats[0].notes.map(\.label) == ["3", "0"] && first.beats[0].notes[1].tie == true, "tied note keeps its fret")
        check(tab.measures[1].beats[0].notes[0].label == "×", "muted note shows ×")
        check(tab.measures(from: 6, to: 10) == [tab.measures[1], tab.measures[0]], "bars starting in a row, in playing order")
        check(tab.measures(from: -.infinity, to: 5).isEmpty && tab.measures(from: 9, to: .infinity) == [tab.measures[0]], "row edges")

        // Beats take room by length, never less than a fret number needs.
        check(TabLayout.beatWidth(beat(1, 4)) == 30 && TabLayout.beatWidth(beat(1, 16)) == TabLayout.minBeatWidth, "beat widths")

        // Two 4/4 measures of quarters fit a phone row (each 16 + 4×30 = 136); the third wraps.
        let quarters = SongTab.Measure(marker: nil, beats: Array(repeating: beat(1, 4), count: 4))
        let marked = SongTab.Measure(marker: "Chorus", beats: Array(repeating: beat(1, 4), count: 4))
        var rows = TabLayout.rows([quarters, marked, quarters], width: 300)
        check(rows.count == 2, "third measure wraps")
        check(rows[0].bars == [0, 136, 272] && rows[0].width == 272, "bar lines between and around measures")
        check(rows[0].markers == [TabLayout.Marker(x: 136, text: "Chorus")], "marker at its measure start")
        check(rows[0].beats.map(\.x) == [23, 53, 83, 113, 159, 189, 219, 249], "beat centres")
        check(rows[1].bars == [0, 136] && rows[1].beats.allSatisfy { $0.measure == 2 }, "wrapped row starts with a bar")

        // A measure wider than a row continues on the next without a bar between.
        let busy = SongTab.Measure(marker: nil, beats: Array(repeating: beat(1, 32), count: 32))
        rows = TabLayout.rows([busy], width: 300)
        check(rows.count == 3, "busy measure splits across rows")
        check(rows.allSatisfy { $0.width <= 300 }, "split rows fit")
        check(rows[0].bars == [0] && rows[1].bars.isEmpty && rows[2].bars.count == 1, "only the measure's own ends get bars")
        check(rows.flatMap(\.beats).map(\.beat) == Array(0..<32), "every beat placed once, in order")
        check(TabLayout.rows([], width: 300).isEmpty, "no measures, no rows")

        // Justified lines all end at the same edge; beats keep their shares.
        let justified = TabLayout.rows([quarters, marked, quarters], width: 300, justify: true)
        check(justified.allSatisfy { $0.width == 300 && $0.bars.last == 300 }, "every justified line spans the width")
        check(justified[1].bars == [0, 300] && abs(justified[1].beats[0].x - 23 * 300 / 136) < 0.001,
              "a short line is stretched in proportion")
        check(justified[0].markers.map(\.x) == [136 * 300 / 272], "markers move with their bars")

        print("Song tab tests passed (\(checks) checks)")
    }
}
