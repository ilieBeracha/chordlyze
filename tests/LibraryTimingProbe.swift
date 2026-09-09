import Combine
import Foundation

enum Config { static let backendBaseURL = URL(string: "http://127.0.0.1:1")! }
@MainActor final class SpotifyAuth {
    func validToken(rejecting: String? = nil) async throws -> String { fatalError("Audit must not authenticate") }
}

/// The input contains private charts; output contains only numeric counts.
@main struct LibraryTimingProbe {
    struct Fixture: Decodable {
        let chart: String
        let analysis: ChordAnalysis
        let lines: [LyricLine]
        let duration: Double
    }
    static func tokens(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }
    static func main() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        var eventsChecked = 0, tokensChecked = 0, rowsChecked = 0, anchorsChecked = 0
        for fixture in fixtures {
            let rows = SheetModel.build(analysis: fixture.analysis, lines: fixture.lines, duration: fixture.duration)
            let events = SheetModel.events(fixture.analysis).filter { $0.start < fixture.duration }
            guard rows.flatMap(\.chords).map(\.event) == events else {
                fatalError("Musical event preservation failed in chart \(fixture.chart)")
            }
            let expected = fixture.lines.filter { $0.time >= 0 && $0.time < fixture.duration }.flatMap { tokens($0.text) }
            guard rows.flatMap({ tokens($0.text) }) == expected else {
                fatalError("Lyric text preservation failed in chart \(fixture.chart)")
            }
            for row in rows {
                guard row.start.isFinite && row.end.isFinite && row.end > row.start else {
                    fatalError("Invalid row interval in chart \(fixture.chart)")
                }
                if let words = row.words {
                    guard words.allSatisfy({ $0.time.isFinite && $0.time >= row.start && $0.time < row.end }),
                          zip(words, words.dropFirst()).allSatisfy({ $0.time <= $1.time }) else {
                        fatalError("Invalid presentation word positions in chart \(fixture.chart)")
                    }
                    for chord in row.chords {
                        if let index = chord.wordIndex {
                            guard words.indices.contains(index), words[index].estimated != true else {
                                fatalError("Uncertain word claimed as an anchor in chart \(fixture.chart)")
                            }
                            anchorsChecked += 1
                        }
                    }
                }
            }
            eventsChecked += events.count
            tokensChecked += expected.count
            rowsChecked += rows.count
        }
        print("Library timing: \(fixtures.count) charts, \(eventsChecked) events, \(tokensChecked) lyric words, \(rowsChecked) rows, \(anchorsChecked) associations verified")
    }
}
