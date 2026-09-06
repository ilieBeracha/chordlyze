import CoreGraphics
import Foundation

/// Where the lyric runner sits on a row, from the words alone. Chords light
/// on their own time above their words and never move the runner: several
/// chords can change above one held word, and the voice is still on that
/// word. With word times the runner waits at the leading edge until a
/// second before the first word, reaches each word as it is sung, finishes
/// the line about a second after the last word and rests at the far edge.
/// With line times only, chord starts are the only fixed points and the
/// runner moves steadily between them. Pure geometry, testable without UI.
enum LyricPlayhead {
    struct Point: Equatable {
        let x: CGFloat
        let y: CGFloat
        let height: CGFloat
    }
    struct Waypoint: Equatable {
        let time: Double
        let x: CGFloat
        let line: CGRect  // the visual line's vertical extent
    }
    /// Seconds a line keeps moving after its last word, then rests.
    static let tail = 1.0
    /// Seconds before the first word the runner leaves the edge.
    static let lead = 1.0

    /// `words` are the word Text bounds by token index; `wordTimes` their
    /// onsets in the same order, or nil for line-timed rows; `chordStarts`
    /// map each chord's start to the word it sits over.
    static func waypoints(rowStart: Double, rowEnd: Double, words: [Int: CGRect], wordTimes: [Double]?,
                          chordStarts: [(time: Double, wordIndex: Int)], rtl: Bool) -> [Waypoint] {
        let lines = Dictionary(grouping: words.values, by: { $0.minY.rounded() }).values
            .map { rects in rects.reduce(rects[0]) { $0.union($1) } }
            .sorted { $0.minY < $1.minY }
        guard let first = lines.first, let last = lines.last else { return [] }
        let leading: (CGRect) -> CGFloat = { rtl ? $0.maxX : $0.minX }
        let trailing: (CGRect) -> CGFloat = { rtl ? $0.minX : $0.maxX }
        func line(containing rect: CGRect) -> CGRect { lines.first { $0.intersects(rect) } ?? first }

        var points = [Waypoint(time: rowStart, x: leading(first), line: first)]
        let timed = (wordTimes ?? []).enumerated().filter { $0.element > rowStart && $0.element < rowEnd }
        if !timed.isEmpty {
            if let firstOnset = timed.first?.element, firstOnset - lead > rowStart {
                points.append(Waypoint(time: firstOnset - lead, x: leading(first), line: first))
            }
            for (index, onset) in timed where onset > points.last!.time {
                guard let rect = words[index] else { continue }
                points.append(Waypoint(time: onset, x: leading(rect), line: line(containing: rect)))
            }
            let finish = min(rowEnd, points.last!.time + tail)
            if finish > points.last!.time { points.append(Waypoint(time: finish, x: trailing(last), line: last)) }
            if rowEnd > finish { points.append(Waypoint(time: rowEnd, x: trailing(last), line: last)) }
        } else {
            for chord in chordStarts.sorted(by: { $0.time < $1.time })
            where chord.time > points.last!.time && chord.time < rowEnd {
                guard let rect = words[chord.wordIndex] else { continue }
                points.append(Waypoint(time: chord.time, x: leading(rect), line: line(containing: rect)))
            }
            points.append(Waypoint(time: rowEnd, x: trailing(last), line: last))
        }
        return points
    }

    /// The runner at `time`, moving steadily between waypoints and wrapping
    /// from the end of one visual line to the start of the next.
    static func position(at time: Double, along points: [Waypoint], rtl: Bool) -> Point? {
        guard let firstPoint = points.first else { return nil }
        let index = points.lastIndex { $0.time <= time } ?? 0
        let from = points[index]
        guard index + 1 < points.count else { return Point(x: from.x, y: from.line.midY, height: from.line.height) }
        let to = points[index + 1]
        let share = max(0, min(1, (time - from.time) / max(to.time - from.time, 0.001)))
        if from.line.minY == to.line.minY {
            return Point(x: from.x + (to.x - from.x) * share, y: from.line.midY, height: from.line.height)
        }
        let leading: (CGRect) -> CGFloat = { rtl ? $0.maxX : $0.minX }
        let trailing: (CGRect) -> CGFloat = { rtl ? $0.minX : $0.maxX }
        let firstLeg = abs(trailing(from.line) - from.x)
        let secondLeg = abs(to.x - leading(to.line))
        let total = max(firstLeg + secondLeg, 1)
        let travelled = share * total
        if travelled <= firstLeg {
            let x = from.x + (trailing(from.line) - from.x) * (firstLeg > 0 ? travelled / firstLeg : 1)
            return Point(x: x, y: from.line.midY, height: from.line.height)
        }
        let rest = travelled - firstLeg
        let x = leading(to.line) + (to.x - leading(to.line)) * (secondLeg > 0 ? rest / secondLeg : 1)
        _ = firstPoint
        return Point(x: x, y: to.line.midY, height: to.line.height)
    }

    /// The word being sung at `time`: the last onset at or before it, or nil
    /// before the first word.
    static func currentWord(at time: Double, wordTimes: [Double]) -> Int? {
        var current: Int?
        for (index, onset) in wordTimes.enumerated() where onset <= time { current = index }
        return current
    }
}
