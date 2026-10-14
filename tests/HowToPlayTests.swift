import Foundation

enum Config { static let backendBaseURL = URL(string: "http://127.0.0.1:1")! }

private var checks = 0
private func check(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !value() { fatalError(message) }
}
private func decode<T: Decodable>(_ object: Any, as: T.Type = T.self) -> T {
    try! JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
}

/// A strum of a voicing, written as tab notes (string 0 = high E).
private func strum(_ frets: [Int], chord: String? = nil, sixteenths: Int, tie: Bool = false) -> [String: Any] {
    // frets low E → high E, -1 = not struck
    let notes = frets.enumerated().compactMap { i, f -> [String: Any]? in
        f < 0 ? nil : ["string": 5 - i, "fret": f, "tie": tie]
    }
    var beat: [String: Any] = ["duration": [sixteenths, 16], "notes": notes]
    if let chord { beat["chord"] = chord }
    return beat
}

private let em7 = [0, 2, 2, 0, 3, 3], g = [3, 2, 0, 0, 3, 3], dsus4 = [-1, -1, 0, 2, 3, 3]

/// One 4/4 bar: struck on 1, 2, 2& , 2a, 3&, 4, 4& (sixteenth slots 0 4 6 7 10 12 14).
private func bar(_ chord: String, _ frets: [Int], label: Bool = true) -> [String: Any] {
    ["beats": [strum(frets, chord: label ? chord : nil, sixteenths: 4), strum(frets, sixteenths: 2),
               strum(frets, sixteenths: 1), strum(frets, sixteenths: 3), strum(frets, sixteenths: 2),
               strum(frets, sixteenths: 2), strum(frets, sixteenths: 2)]]
}

@main struct HowToPlayTests {
    static func main() {
        // Em7 and G alternate, Dsus4 twice, one bar (2 s) each; one bar of Asus2
        // (under 3% of the song) is a passing chord.
        var measures = [bar("Em7", em7), bar("G", g), bar("Dsus4", dsus4)]
        measures.append(["beats": [strum([-1, 0, 2, 2, 0, -1], chord: "Asus2", sixteenths: 4),
                                   ["duration": [3, 4], "rest": true, "notes": []]]])
        let order = Array(repeating: [0, 1], count: 18).flatMap { $0 } + [2, 1, 2, 1, 3]
        let tab: SongTab = decode(["name": "Rhythm", "tuning": [64, 59, 55, 50, 45, 40], "capo": 2,
            "measures": measures,
            "bars": order.enumerated().map { ["measure": $1, "start": Double($0) * 2, "end": Double($0) * 2 + 2] }])
        let chart: ChordAnalysis = decode(["key": "E minor", "source": "songsterr", "audio_duration": 22,
            "chords": [["start": 0, "end": 22, "label": "E:min7"]]])

        check(HowToPlay.voicings(tab)["Em7"]?.frets == em7 && HowToPlay.voicings(tab)["G"]?.frets == g,
              "Voicings come from the tab's strums, low E first")
        guard let guide = HowToPlay.make(analysis: chart, tab: tab) else { fatalError("No guide") }
        check(guide.chords.map(\.name) == ["Em7", "G", "Dsus4"], "Passing chords are not chords to learn")
        check(guide.capo == 2, "The capo comes from the tab")
        check(guide.anchors == [4, 5], "Fingers on B and high E never move")
        check(guide.anchorLine == "Keep your high E and B fingers on fret 3 for every chord.", "The anchor line names strings and fret")
        check(guide.firstChords.names == ["G", "Em7", "Dsus4"] && guide.firstChords.percent == 100,
              "Chords to learn, most played first")

        // Em7↔G happens most often with two fingers moving: that's the change to drill.
        guard let change = guide.change else { fatalError("No change") }
        check(Set([change.from, change.to]) == ["Em7", "G"] && change.count >= 4 && change.moving == 2,
              "The hardest change is the frequent Em7↔G")
        check(change.fastest == 2, "Each bar gives two seconds to switch")

        guard let pattern = guide.strum else { fatalError("No strum") }
        let struck = pattern.slots.enumerated().compactMap { $1 == nil ? nil : $0 }
        check(struck == [0, 4, 6, 7, 10, 12, 14], "The common bar's strikes on sixteenths")
        check(pattern.slots[7] == .up && pattern.slots[6] == .down, "Downs on numbers and ands, ups on e's and a's")
        check(pattern.bpm == 120, "Tempo from the bar's length")

        // Without a tab: chart chords, shifted as the sheet shows them, standard shapes, no strum.
        let plain: ChordAnalysis = decode(["key": "C major", "source": "youtube", "audio_duration": 8, "chords": [
            ["start": 0, "end": 2, "label": "C:maj"], ["start": 2, "end": 4, "label": "G:maj"],
            ["start": 4, "end": 6, "label": "C:maj"], ["start": 6, "end": 8, "label": "G:maj"]]])
        let chartOnly = HowToPlay.make(analysis: plain, tab: nil)
        check(chartOnly?.chords.map(\.name) == ["C", "G"] && chartOnly?.strum == nil && chartOnly?.capo == 0,
              "A chart without a tab still names its chords")
        check(HowToPlay.make(analysis: plain, tab: nil, transpose: 2)?.chords.map(\.name) == ["D", "A"],
              "Chart names follow the sheet's transpose")
        check(chartOnly?.anchorLine == nil, "No shared fingers, no anchor line")
        check(HowToPlay.make(analysis: decode(["source": "youtube", "chords": [["start": 0, "end": 4, "label": "N"]]]), tab: nil) == nil,
              "No chords, no guide")
        check(HowToPlay.seconds(0.4) == "under a second" && HowToPlay.seconds(1.25) == "1.2 s", "Switch times read plainly")

        print("How-to-play tests passed (\(checks) checks)")
    }
}
