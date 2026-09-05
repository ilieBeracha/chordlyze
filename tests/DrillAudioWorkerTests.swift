import Foundation

private var checks = 0
private var failures = 0
private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { failures += 1; print("FAIL: \(message)") }
}

@main @MainActor
struct DrillAudioWorkerTests {
    private static func holdMainQueueBriefly() {
        _ = DispatchSemaphore(value: 0).wait(timeout: .now() + 0.05)
    }

    static func main() async throws {
        let inbox = DrillAudioInbox(sampleRate: 48000)
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: DrillAudioInbox.maximumBufferSize)
        scratch.initialize(repeating: 0, count: DrillAudioInbox.maximumBufferSize)
        defer { scratch.deinitialize(count: DrillAudioInbox.maximumBufferSize); scratch.deallocate() }
        for index in 0..<20 {
            var input = [Float](repeating: Float(index), count: 1024)
            check(input.withUnsafeBufferPointer { inbox.offer($0, sampleTime: Int64(index * 1024)) }, "inbox accepts bounded input")
            input[0] = -1 // Audio-engine buffers can be reused as soon as offer returns.
        }
        var chunks: [Int64] = []
        while let chunk = inbox.take(into: scratch) {
            chunks.append(chunk.sampleTime)
            check(scratch[0] == Float(chunk.sampleTime / 1024), "inbox owns a copy of the audio")
        }
        check(chunks == (12..<20).map { Int64($0 * 1024) }, "overload keeps eight newest buffers and their original timestamps")
        inbox.cancel()
        let input = [Float](repeating: 0.1, count: 1024)
        check(!input.withUnsafeBufferPointer { inbox.offer($0, sampleTime: 0) }, "canceled inbox rejects new input")
        check(inbox.take(into: scratch) == nil, "cancel discards queued audio")

        let largeInbox = DrillAudioInbox(sampleRate: 44100)
        let large = [Float](repeating: 0.1, count: 4096)
        for index in 0..<6 { _ = large.withUnsafeBufferPointer { largeInbox.offer($0, sampleTime: Int64(index * 4096)) } }
        var total = 0, first: Int64?
        while let chunk = largeInbox.take(into: scratch) { total += chunk.count; if first == nil { first = chunk.sampleTime } }
        check(total <= 11025 && first == 16384, "queue latency is bounded by 250 ms, including large tap buffers")
        let oversized = [Float](repeating: 0, count: 9000)
        check(!oversized.withUnsafeBufferPointer { largeInbox.offer($0, sampleTime: 0) }, "oversized input cannot overflow storage")

        var delivered = 0
        let worker = try DrillAudioWorker(sampleRate: 44100, chordA: "C", chordB: "Am", onSnapshot: { _ in delivered += 1 })
        let audio: [Float] = (0..<Int(44100 * 1.1)).map { i in
            let time = Double(i) / 44100
            return [48,52,55].reduce(Float(0)) { sum, note in
                let f = 440 * pow(2, Double(note - 69) / 12)
                return sum + (1...6).reduce(Float(0)) { $0 + Float(sin(2 * .pi * f * Double($1) * time) / Double($1) * 0.05) }
            }
        }
        for offset in stride(from: 0, to: audio.count, by: 1024) {
            audio.withUnsafeBufferPointer {
                worker.offer(UnsafeBufferPointer(start: $0.baseAddress! + offset, count: min(1024, $0.count - offset)), sampleTime: Int64(offset))
            }
            try await Task.sleep(for: .milliseconds(4))
        }
        let final = await worker.finish()
        check(final?.current == "C", "real worker delivers recognized audio from the production core")
        check(final?.changes == 0, "first chord does not count a change")
        check(final!.time > 1, "finish flushes the final audio before returning the score")
        let before = delivered
        input.withUnsafeBufferPointer { worker.offer($0, sampleTime: 100000) }
        try await Task.sleep(for: .milliseconds(30))
        check(delivered == before, "finished worker cannot publish another UI snapshot")

        var canceledDeliveries = 0
        let canceled = try DrillAudioWorker(sampleRate: 44100, chordA: "C", chordB: "Am", onSnapshot: { _ in canceledDeliveries += 1 })
        large.withUnsafeBufferPointer { canceled.offer($0, sampleTime: 0) }
        // Keep the main queue busy while the background queue schedules its UI
        // callback, then cancel before that callback gets a chance to run.
        holdMainQueueBriefly()
        canceled.cancel()
        try await Task.sleep(for: .milliseconds(30))
        check(canceledDeliveries == 0, "cancel suppresses an already pending UI delivery")
        let canceledFinal = await canceled.finish()
        check(canceledFinal == nil, "a canceled worker cannot return an earlier score")

        var beforeFailure: DrillSnapshot?
        let failingAtFinish = try DrillAudioWorker(sampleRate: 44100, chordA: "C", chordB: "Am", onSnapshot: { beforeFailure = $0 })
        let quiet = [Float](repeating: 0, count: 4096)
        quiet.withUnsafeBufferPointer { failingAtFinish.offer($0, sampleTime: 0) }
        for _ in 0..<100 where beforeFailure == nil { try await Task.sleep(for: .milliseconds(5)) }
        check(beforeFailure != nil, "the stream has delivered a valid snapshot before failing")
        failingAtFinish.invalidateFormat()
        let immediateFailure = await failingAtFinish.finish()
        check(immediateFailure == nil, "finishing immediately after invalid input cannot recover the last valid snapshot")

        var formatFailures = 0
        let invalid = try DrillAudioWorker(sampleRate: 44100, chordA: "C", chordB: "Am", onSnapshot: { _ in }, onFailure: { formatFailures += 1 })
        for _ in 0..<10 { invalid.invalidateFormat() }
        try await Task.sleep(for: .milliseconds(50))
        check(formatFailures == 1, "an invalid microphone stream reports one failure, not a callback storm")
        let invalidFinal = await invalid.finish()
        check(invalidFinal == nil, "a failed microphone stream cannot return a completed score")

        print("Drill audio worker: \(checks - failures)/\(checks) checks passed")
        if failures > 0 { exit(1) }
    }
}
