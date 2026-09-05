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
        _ = try BackendClient.practiceReport(legacy, transpose: 0, playbackRate: 1)
        for (shift, rate) in [(2, 1.0), (0, 0.5)] {
            do {
                _ = try BackendClient.practiceReport(legacy, transpose: shift, playbackRate: rate)
                fatalError("An old server must not silently score modified practice settings")
            } catch {}
        }
        let accepted = Data("""
        {"take_id":"new","accuracy":1,"per_chord":[],"transitions":[],"sections":[],
         "transpose":2,"playback_rate":0.5}
        """.utf8)
        _ = try BackendClient.practiceReport(accepted, transpose: 2, playbackRate: 0.5)
        do {
            _ = try BackendClient.practiceReport(accepted, transpose: 0, playbackRate: 1)
            fatalError("Mismatched server settings must fail")
        } catch {}
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("test audio".utf8).write(to: file)
        let request = try BackendClient.practiceTakeRequest(fileURL: file, trackID: "song", offset: 12,
            transpose: -2, playbackRate: 0.75)
        let body = String(data: request.httpBody!, encoding: .utf8)!
        precondition(body.contains("name=\"transpose\"\r\n\r\n-2\r\n"))
        precondition(body.contains("name=\"playback_rate\"\r\n\r\n0.75\r\n"))
        precondition(body.contains("name=\"offset\"\r\n\r\n12.0\r\n"))
        precondition(body.contains("test audio") && !body.contains("capo"))
        print("Practice report contract: legacy decoding, timing, request fields and server compatibility passed")
    }
}
