import Foundation

enum Config { static let backendBaseURL = URL(string: "http://127.0.0.1:1")! }
struct Track {
    let id: String
    let isrc: String?
    let name: String
    let artistNames: String
    let durationMs: Int?
}

@main struct PracticeTakeTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let song = SongDescriptor(trackID: "test-song", title: "Test song", artist: "Test artist")
        let plan = try PracticePlan(start: 20, end: 40, rate: 0.5, transpose: 2, capo: 3)
        precondition(plan.recordingDuration == 40)
        precondition(plan.position(elapsed: 10) == 25 && plan.position(elapsed: 100) == 40)
        precondition(plan.beats([10, 20, 21, 22, 40, 41]) == [0, 2, 4])
        let capped = try PracticePlan(start: 0, end: 1000, rate: 0.5)
        precondition(capped.recordingDuration == 600)
        for (start, end, rate) in [(0.0, 0.0, 1.0), (-1, 4, 1), (0, 4, 0), (0, 4, 1.5), (.nan, 4, 1), (0, .infinity, 1)] {
            do { _ = try PracticePlan(start: start, end: end, rate: rate); fatalError("Invalid plan accepted") }
            catch {}
        }
        let expectedReport = try JSONDecoder().decode(BackendClient.PracticeReport.self, from: Data("""
        {"take_id":"test","accuracy":1,"avg_lag":0,"comparison":"root_quality",
         "transpose":2,"playback_rate":0.5,"per_chord":[],"transitions":[],"sections":[]}
        """.utf8))
        var attempts = 0
        let store = PracticeTakeStore(directory: root) { url, take in
            let captured = try Data(contentsOf: url)
            precondition(captured == Data("recorded audio".utf8))
            precondition(take.plan == plan && take.song == song)
            attempts += 1
            throw URLError(.notConnectedToInternet)
        }
        let take = try store.prepare(song: song, plan: plan)
        let audio = store.audioURL(take)
        try Data("recorded audio".utf8).write(to: audio)
        // Simulate process death before finish: the prewritten metadata and
        // audio must be sufficient to recover and accurately resubmit the take.
        let recovered = PracticeTakeStore(directory: root) { _, take in
            precondition(take.plan == plan)
            return expectedReport
        }
        precondition(recovered.takes.count == 1 && recovered.takes[0].note?.contains("interrupted") == true)
        try store.finish(take, note: "Spotify paused; partial take saved.")
        do { _ = try await store.score(store.takes[0]); fatalError("Upload should fail") }
        catch { precondition(error is URLError) }
        precondition(attempts == 1 && store.uploading.isEmpty)
        precondition(FileManager.default.fileExists(atPath: audio.path))
        precondition(store.takes.count == 1 && store.takes[0].report == nil)
        recovered.reload()
        let report = try await recovered.score(recovered.takes[0])
        precondition(report.accuracy == 1 && recovered.uploading.isEmpty)
        let reopened = PracticeTakeStore(directory: root)
        precondition(reopened.takes[0].report?.playbackRate == 0.5)
        precondition(reopened.takes[0].report?.transpose == 2)
        precondition(reopened.takes[0].note == "Spotify paused; partial take saved.")
        precondition(FileManager.default.fileExists(atPath: audio.path), "Successful scoring preserves playback")

        // A second submit and delete cannot race an in-flight upload.
        var release: CheckedContinuation<Void, Never>?
        let delayed = PracticeTakeStore(directory: root) { _, _ in
            await withCheckedContinuation { release = $0 }
            return expectedReport
        }
        let scoring = Task { try await delayed.score(take) }
        for _ in 0..<100 where release == nil { await Task.yield() }
        precondition(release != nil && delayed.uploading.contains(take.id))
        do { try delayed.delete(take); fatalError("Deleted an uploading take") } catch {}
        do { _ = try await delayed.score(take); fatalError("Duplicate upload accepted") } catch {}
        release?.resume()
        _ = try await scoring.value
        try reopened.delete(take)
        precondition(!FileManager.default.fileExists(atPath: audio.path) && reopened.takes.isEmpty)

        // One corrupt metadata file must not hide healthy recordings.
        let valid = try store.prepare(song: song, plan: plan)
        try Data("recorded audio".utf8).write(to: store.audioURL(valid))
        let corrupt = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: corrupt.appendingPathComponent("take.json"))
        store.reload()
        precondition(store.takes.count == 1 && store.error != nil)
        print("Practice take tests passed: range/pace mapping, interrupted recovery, offline retry, report persistence, upload races, deletion and corrupt metadata isolation")
    }
}
