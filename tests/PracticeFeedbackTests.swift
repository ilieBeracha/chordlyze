import Foundation

enum Config { static let backendBaseURL = URL(string: "http://127.0.0.1:1")! }

private var checks = 0
private func check(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !value() { fatalError(message) }
}
private func segments(_ items: [(Double, Double, String)]) -> [ChordSegment] {
    try! JSONDecoder().decode([ChordSegment].self, from: JSONSerialization.data(withJSONObject:
        items.map { ["start": $0.0, "end": $0.1, "label": $0.2] }))
}
private let latency = PracticeFeedback.detectorLatency

@main struct PracticeFeedbackTests {
    static func main() {
        let chart = segments([(0, 4, "N"), (4, 8, "C:maj"), (8, 12, "G:maj"), (12, 16, "G:maj/3"),
                              (16, 20, "A:min"), (20, 24, "F:maj"), (24, 30, "C:maj")])
        var feedback = PracticeFeedback(chords: chart, start: 6, end: 22)
        check(feedback.targets.map(\.name) == ["C", "G", "G/B", "Am", "F"], "Targets are the sounding chords inside the take, N.C. excluded")
        check(feedback.targets.first?.start == 4, "A chord already sounding at the take start is still a target")

        // Detector snapshots: nil → "G" is a strum; the same name repeated is the same strum.
        check(feedback.observe(current: nil, chartTime: 7.0) == nil, "Silence judges nothing")
        check(feedback.observe(current: "G", chartTime: 8.1 + latency) == 1, "A strum of the expected chord is a hit")
        check(feedback.observe(current: "G", chartTime: 8.5 + latency) == nil, "A sustained chord is not a second strum")
        guard case .hit(let offset)? = feedback.verdicts[1] else { fatalError("G should be a hit") }
        check(abs(offset - 0.1) < 1e-9, "Offset is measured from the chart change with detector latency removed")
        check(feedback.verdicts[2] == .held, "The same chord over a bass change is held, not demanded again")
        check(feedback.verdict(startingAt: 12) == .held && feedback.verdict(startingAt: 99) == nil, "Verdicts are looked up by chart start")

        check(feedback.observe(current: nil, chartTime: 15.5) == nil, "Rest between strums")
        check(feedback.observe(current: "Am", chartTime: 15.7 + latency) == 3, "A strum within half a second before the change counts for the coming chord")
        guard case .hit(let early)? = feedback.verdicts[3], early < 0 else { fatalError("Am should be an early hit") }
        check(PracticeFeedback.describe(feedback.targets[3], feedback.verdicts[3]!) == "Am early by 0.3 s", "Early strums are described in tenths")

        check(feedback.observe(current: nil, chartTime: 20.2) == nil, "Rest")
        check(feedback.observe(current: "Dm", chartTime: 20.6 + latency) == 4, "A different chord while F should sound is wrong")
        check(feedback.verdicts[4] == .wrong(heard: "Dm"), "The wrong verdict names what was heard")
        check(feedback.observe(current: nil, chartTime: 21.0) == nil && feedback.observe(current: "F", chartTime: 21.4 + latency) == 4,
              "Correcting to the right chord upgrades wrong to a late hit")
        check(PracticeFeedback.describe(feedback.targets[4], feedback.verdicts[4]!) == "F late by 1.4 s", "Late hits report how late")
        check(feedback.observe(current: nil, chartTime: 21.6) == nil && feedback.observe(current: "Dm", chartTime: 21.8 + latency) == nil,
              "A hit is never downgraded by a later wrong strum")
        check(feedback.hits == 4 && feedback.judged.count == 4, "Hits count on-time, early, late and held; the corrected wrong is now a hit")
        check(feedback.observe(current: "C", chartTime: 30 + latency) == nil, "Strums outside the take are ignored")

        // Enharmonic and voicing-insensitive matching, and the transposed reference.
        var chromatic = PracticeFeedback(chords: segments([(0, 4, "Db:maj"), (4, 8, "A:min7")]), start: 0, end: 8)
        check(chromatic.heard("C#", at: 0.5) == 0, "C# and Db are the same chord")
        check(chromatic.heard("C6", at: 4.5) == 1, "C6 and Am7 share pitch classes, so either spelling matches")
        var shifted = PracticeFeedback(chords: segments([(0, 4, "C:maj")]), start: 0, end: 4, transpose: 2)
        check(shifted.targets.first?.name == "D" && shifted.heard("D", at: 1) == 0 && shifted.verdicts[0] != nil, "A transposed take expects the sounding chord")
        var plain = PracticeFeedback(chords: segments([(0, 4, "C:maj")]), start: 0, end: 4)
        check(plain.heard("N.C.", at: 1) == nil, "Nonsense from the detector is ignored")
        print("Practice feedback: \(checks)/\(checks) checks passed")
    }
}
