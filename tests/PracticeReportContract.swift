import Foundation

// Compile the production BackendClient and Chord without launching the iOS app.
// Only its unrelated configuration/Spotify inputs are replaced by test stubs.
enum Config { static let backendBaseURL = URL(string: "http://127.0.0.1")! }
struct Track {
    let id: String
    let isrc: String?
    let name: String
    let artistNames: String
    let durationMs: Int?
}

@main
struct PracticeReportContract {
    static func main() throws {
        let legacy = Data("""
        {"take_id":"old","accuracy":1,"avg_lag":0.8,"per_chord":[],
         "transitions":[{"from":"C","to":"G","avg_lag":0.8,"misses":0,"count":1}],
         "sections":[]}
        """.utf8)
        let report = try JSONDecoder().decode(BackendClient.PracticeReport.self, from: legacy)
        precondition(report.comparison == nil && report.avgTimingError == nil)
        precondition(report.transitions[0].timingLabel == "0.8s late")

        for (offset, error, expected) in [(-0.3, 0.3, "0.3s early"),
                                          (0.7, 0.7, "0.7s late"),
                                          (0.0, 0.6, "0.6s off"),
                                          (0.01, 0.02, "on time")] {
            let data = Data("""
            {"take_id":"new","accuracy":0.9,"avg_lag":0,"avg_timing_error":\(error),
             "comparison":"root_quality","per_chord":[],"sections":[],
             "transitions":[{"from":"Cmaj7","to":"G7","avg_lag":0,
               "avg_offset":\(offset),"avg_timing_error":\(error),"misses":0,"count":2}]}
            """.utf8)
            let rich = try JSONDecoder().decode(BackendClient.PracticeReport.self, from: data)
            precondition(rich.comparison == "root_quality" && rich.avgTimingError == error)
            precondition(rich.transitions[0].timingLabel == expected)
            precondition(rich.transitions[0].timingError == error)
        }
        print("Practice report contract: legacy decoding and 4 timing cases passed")
    }
}
