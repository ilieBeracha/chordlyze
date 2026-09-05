import Foundation

/// Preallocated, bounded handoff from the microphone callback. The producer
/// never waits for the consumer: contention drops a buffer, and timestamps let
/// the detector discard discontinuous pitch history on its next delivery.
final class DrillAudioInbox: @unchecked Sendable {
    static let maximumBufferSize = 8192
    private let lock = NSLock()
    private let storage: UnsafeMutablePointer<Float>
    private let capacity = 8
    private let frameLimit: Int
    private var times = [Int64](repeating: 0, count: 8)
    private var lengths = [Int](repeating: 0, count: 8)
    private var head = 0
    private var count = 0
    private var queuedFrames = 0
    private var active = true

    init(sampleRate: Double) {
        frameLimit = Int(sampleRate * 0.25)
        storage = .allocate(capacity: capacity * Self.maximumBufferSize)
        storage.initialize(repeating: 0, count: capacity * Self.maximumBufferSize)
    }

    deinit {
        storage.deinitialize(count: capacity * Self.maximumBufferSize)
        storage.deallocate()
    }

    @discardableResult
    func offer(_ samples: UnsafeBufferPointer<Float>, sampleTime: Int64) -> Bool {
        guard !samples.isEmpty, samples.count <= min(Self.maximumBufferSize, frameLimit),
              lock.try() else { return false }
        defer { lock.unlock() }
        guard active else { return false }
        while count > 0 && (count == capacity || queuedFrames + samples.count > frameLimit) {
            queuedFrames -= lengths[head]
            head = (head + 1) % capacity
            count -= 1
        }
        let tail = (head + count) % capacity
        (storage + tail * Self.maximumBufferSize).update(from: samples.baseAddress!, count: samples.count)
        times[tail] = sampleTime
        lengths[tail] = samples.count
        queuedFrames += samples.count
        count += 1
        return true
    }

    func take(into destination: UnsafeMutablePointer<Float>) -> (count: Int, sampleTime: Int64)? {
        lock.lock()
        defer { lock.unlock() }
        guard active, count > 0 else { return nil }
        let length = lengths[head], time = times[head]
        destination.update(from: storage + head * Self.maximumBufferSize, count: length)
        queuedFrames -= length
        head = (head + 1) % capacity
        count -= 1
        return (length, time)
    }

    func cancel() {
        lock.lock()
        active = false
        count = 0
        queuedFrames = 0
        lock.unlock()
    }
}

/// Owns all mutable DSP state on one serial queue. UI deliveries are coalesced
/// to one pending main-queue job, even when the main thread falls behind.
final class DrillAudioWorker: @unchecked Sendable {
    private let inbox: DrillAudioInbox
    private let detector: ChordDrillDetector
    private let source: DispatchSourceUserDataOr
    private let queue = DispatchQueue(label: "chordlyze.drill-analysis", qos: .userInitiated)
    private let scratch: UnsafeMutablePointer<Float>
    private let maximumOfferedFrames: Int
    private let deliveryLock = NSLock()
    private var latest: DrillSnapshot?
    private var deliveryScheduled = false
    private var active = true
    private var lastSnapshot: DrillSnapshot?
    private var inputFailed = false // Protected by deliveryLock.
    private let onSnapshot: @MainActor @Sendable (DrillSnapshot) -> Void
    private let onFailure: @MainActor @Sendable () -> Void

    init(sampleRate: Double, chordA: String, chordB: String,
         onSnapshot: @escaping @MainActor @Sendable (DrillSnapshot) -> Void,
         onFailure: @escaping @MainActor @Sendable () -> Void = {}) throws {
        detector = try ChordDrillDetector(sampleRate: sampleRate, chordA: chordA, chordB: chordB)
        inbox = DrillAudioInbox(sampleRate: sampleRate)
        maximumOfferedFrames = min(DrillAudioInbox.maximumBufferSize, Int(sampleRate * 0.25))
        scratch = .allocate(capacity: DrillAudioInbox.maximumBufferSize)
        scratch.initialize(repeating: 0, count: DrillAudioInbox.maximumBufferSize)
        self.onSnapshot = onSnapshot
        self.onFailure = onFailure
        source = DispatchSource.makeUserDataOrSource(queue: queue)
        source.setEventHandler { [weak self] in self?.handleInput() }
        source.activate()
    }

    deinit {
        source.cancel()
        scratch.deinitialize(count: DrillAudioInbox.maximumBufferSize)
        scratch.deallocate()
    }

    /// Called from the audio tap. No FFT setup, recognition, task creation or
    /// UI work is performed here; the input buffer is copied before it expires.
    func offer(_ samples: UnsafeBufferPointer<Float>, sampleTime: Int64) {
        guard samples.count <= maximumOfferedFrames else { invalidateFormat(); return }
        if inbox.offer(samples, sampleTime: sampleTime) { source.or(data: 1) }
    }

    func invalidateFormat() {
        // Record failure before scheduling its callback: finish may already be
        // queued, and must not return the last good score from a broken stream.
        deliveryLock.lock()
        let notify = active && !inputFailed
        inputFailed = true
        latest = nil
        deliveryLock.unlock()
        if notify { source.or(data: 2) }
    }

    /// The caller removes the audio tap first, then flushes the final queued
    /// buffers so a change near the end of the drill is not lost at shutdown.
    func finish() async -> DrillSnapshot? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                drain()
                deliveryLock.lock()
                let final = active && !inputFailed ? lastSnapshot : nil
                deliveryLock.unlock()
                cancel()
                continuation.resume(returning: final)
            }
        }
    }

    func cancel() {
        inbox.cancel()
        deliveryLock.lock()
        active = false
        latest = nil
        deliveryLock.unlock()
        source.cancel()
    }

    private func drain() {
        while let chunk = inbox.take(into: scratch) {
            let samples = UnsafeBufferPointer(start: scratch, count: chunk.count)
            if let snapshot = detector.append(samples, sampleTime: chunk.sampleTime).last {
                lastSnapshot = snapshot
                publish(snapshot)
            }
        }
    }

    private func handleInput() {
        if source.data & 2 != 0 {
            cancel()
            DispatchQueue.main.async { [weak self] in self?.onFailure() }
        } else {
            drain()
        }
    }

    private func publish(_ snapshot: DrillSnapshot) {
        deliveryLock.lock()
        guard active && !inputFailed else { deliveryLock.unlock(); return }
        latest = snapshot
        let schedule = !deliveryScheduled
        deliveryScheduled = true
        deliveryLock.unlock()
        if schedule {
            DispatchQueue.main.async { [weak self] in self?.deliver() }
        }
    }

    @MainActor private func deliver() {
        deliveryLock.lock()
        let snapshot = active && !inputFailed ? latest : nil
        latest = nil
        deliveryScheduled = false
        deliveryLock.unlock()
        if let snapshot { onSnapshot(snapshot) }
    }
}
