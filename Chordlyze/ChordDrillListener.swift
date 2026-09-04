import AVFoundation
import Foundation

/// AVAudioEngine adapter for the deterministic streaming detector. Each start
/// owns a new worker; generation checks reject late permission and UI callbacks.
@MainActor
final class ChordDrillListener: ObservableObject {
    @Published private(set) var current: String?
    @Published private(set) var changes = 0
    @Published private(set) var evidence: DrillEvidence = .quiet
    @Published private(set) var failure: String?

    private var engine: AVAudioEngine?
    private var worker: DrillAudioWorker?
    private var generation: UInt64 = 0
    private var tapInstalled = false
    private var sessionActive = false
    private var observers: [NSObjectProtocol] = []

    func start(chordA: String, chordB: String) async throws {
        stop()
        let token = generation
        failure = nil
        changes = 0
        evidence = .uncertain
        // Validate before asking for microphone permission.
        _ = try DrillChordClassifier(chordA: chordA, chordB: chordB)
        let permitted = await AVAudioApplication.requestRecordPermission()
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        guard permitted else {
            throw NSError(domain: "Drill", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Microphone access denied. Enable it in Settings to start a drill."])
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
            sessionActive = true
            let engine = AVAudioEngine()
            self.engine = engine
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.commonFormat == .pcmFormatFloat32,
                  !format.isInterleaved else { throw DrillConfigurationError.unsupportedSampleRate }
            let sampleRate = format.sampleRate
            let worker = try DrillAudioWorker(sampleRate: sampleRate, chordA: chordA, chordB: chordB,
                onSnapshot: { [weak self] snapshot in
                    guard let self, self.generation == token else { return }
                    self.apply(snapshot)
                }, onFailure: { [weak self] in
                    self?.interrupt(token: token, message: "The microphone format changed. Start the drill again.")
                })
            self.worker = worker
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
                guard time.isSampleTimeValid, buffer.format.sampleRate == sampleRate,
                      Int(buffer.frameLength) <= DrillAudioInbox.maximumBufferSize,
                      let samples = buffer.floatChannelData?[0] else {
                    worker.invalidateFormat()
                    return
                }
                worker.offer(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)),
                             sampleTime: time.sampleTime)
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
            observeAudioChanges(engine: engine, token: token)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        generation &+= 1
        worker?.cancel()
        worker = nil
        stopCapture()
        current = nil
        evidence = .quiet
    }

    /// Normal completion keeps the last queued change; cancellation uses stop().
    func finish() async throws {
        let token = generation
        let finishingWorker = worker
        stopCapture()
        let final = await finishingWorker?.finish()
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
        if let final { apply(final) }
        worker = nil
        generation &+= 1
        current = nil
        evidence = .quiet
    }

    private func apply(_ snapshot: DrillSnapshot) {
        if current != snapshot.current { current = snapshot.current }
        if changes != snapshot.changes { changes = snapshot.changes }
        if evidence != snapshot.evidence { evidence = snapshot.evidence }
    }

    private func stopCapture() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine?.stop()
        engine = nil
        if sessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionActive = false
        }
    }

    private func observeAudioChanges(engine: AVAudioEngine, token: UInt64) {
        for (name, object, message) in [
            (AVAudioSession.interruptionNotification, nil as AnyObject?, "The microphone was interrupted. Start the drill again."),
            (AVAudioSession.routeChangeNotification, nil, "The audio input changed. Start the drill again."),
            (Notification.Name.AVAudioEngineConfigurationChange, engine, "The microphone configuration changed. Start the drill again.")
        ] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) {
                [weak self] _ in
                Task { @MainActor [weak self] in self?.interrupt(token: token, message: message) }
            })
        }
    }

    private func interrupt(token: UInt64, message: String) {
        guard generation == token else { return }
        stop()
        failure = message
    }

    deinit {
        worker?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0) }
        engine?.stop()
        if sessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
