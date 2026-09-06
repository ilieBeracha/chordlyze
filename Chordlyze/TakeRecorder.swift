import AVFoundation
import Foundation

/// Records a practice take from the microphone to an .m4a file through one
/// AVAudioEngine tap, and hands the same samples to a listener so live
/// feedback and the recording share a sample-accurate timeline: the
/// listener's sample time is the frame's position in the file.
@MainActor
final class TakeRecorder {
    typealias Listener = @Sendable (UnsafeBufferPointer<Float>, _ sampleTime: Int64, _ sampleRate: Double) -> Void

    private var engine: AVAudioEngine?
    private let slot = WriterSlot()
    private var writer: Writer? { slot.current }
    private var observers: [NSObjectProtocol] = []
    private(set) var fileURL: URL?
    private(set) var sampleRate: Double = 0

    /// False once the take reached `maxDuration` or the engine stopped.
    var isRecording: Bool { engine?.isRunning == true && writer?.finished == false }

    private static let sessionOptions: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]

    /// The route the take will actually use. Spotify practice needs an
    /// output other than the phone's own speaker or earpiece, or the
    /// microphone records the song itself.
    ///
    /// The session is configured and activated exactly as recording will
    /// use it before the route is read: an inactive session, or one left in
    /// the drill's record-only category, reports a route that has nothing
    /// to do with where a take would play.
    struct Route {
        let outputs: [String]
        let headphones: Bool
    }

    static func recordingRoute() throws -> Route {
        #if targetEnvironment(simulator)
        return Route(outputs: ["Simulator"], headphones: true)  // No real audio routes.
        #else
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: sessionOptions)
        try session.setActive(true)
        let outputs = session.currentRoute.outputs
        let headphones = !outputs.isEmpty && outputs.allSatisfy {
            $0.portType != .builtInSpeaker && $0.portType != .builtInReceiver
        }
        return Route(outputs: outputs.map(\.portName), headphones: headphones)
        #endif
    }

    func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Opens the microphone without writing anything, so the recording route
    /// is already live before Spotify starts. Starting input later, with
    /// Bluetooth headphones, interrupts other audio for a moment; done here,
    /// there is nothing to interrupt when the take begins. Idempotent.
    func prime() throws {
        if engine?.isRunning == true { return }
        let session = AVAudioSession.sharedInstance()
        // playAndRecord (not record) so a running metronome keeps clicking;
        // mixWithOthers so activating the session doesn't pause Spotify.
        try session.setCategory(.playAndRecord, mode: .default, options: Self.sessionOptions)
        try session.setActive(true)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0, format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved else { throw DrillConfigurationError.unsupportedSampleRate }
        let slot = self.slot
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            slot.current?.append(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        self.engine = engine
        sampleRate = format.sampleRate
        for name in [AVAudioSession.interruptionNotification, Notification.Name.AVAudioEngineConfigurationChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.writer?.finish() }
            })
        }
    }

    /// Begins writing the take. Primes the microphone first if needed; when
    /// already primed, the first written frame is the next one captured.
    func start(maxDuration: TimeInterval, at url: URL, listener: Listener? = nil) throws {
        try prime()
        guard slot.current == nil else { throw CocoaError(.fileWriteUnknown) }
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        slot.current = Writer(file: file, format: mono, limit: Int64(maxDuration * sampleRate), listener: listener)
        fileURL = url
    }

    /// Stops recording and returns the captured file; nil if nothing was
    /// started. The file is the caller's to delete.
    func stop() -> URL? {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        let writer = slot.current
        slot.current = nil
        writer?.finish()
        writer?.close()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        defer { fileURL = nil }
        return fileURL
    }

    /// The tap reads the current writer through this lock; nil while primed
    /// but not yet recording.
    private final class WriterSlot: @unchecked Sendable {
        private let lock = NSLock()
        private var writer: Writer?
        var current: Writer? {
            get { lock.lock(); defer { lock.unlock() }; return writer }
            set { lock.lock(); writer = newValue; lock.unlock() }
        }
    }

    /// Copies each tap buffer off the realtime thread, then encodes on a
    /// serial queue. Frames past `limit` are dropped so the file never
    /// exceeds the planned duration.
    private final class Writer: @unchecked Sendable {
        private let file: AVAudioFile
        private let format: AVAudioFormat
        private let limit: Int64
        private let listener: Listener?
        private let queue = DispatchQueue(label: "chordlyze.take-writer", qos: .userInitiated)
        private let lock = NSLock()
        private var written: Int64 = 0
        private var done = false
        private var closed = false

        init(file: AVAudioFile, format: AVAudioFormat, limit: Int64, listener: Listener?) {
            self.file = file
            self.format = format
            self.limit = limit
            self.listener = listener
        }

        var finished: Bool { lock.lock(); defer { lock.unlock() }; return done }

        func append(_ buffer: AVAudioPCMBuffer) {
            lock.lock()
            guard !done, let source = buffer.floatChannelData?[0] else { lock.unlock(); return }
            let frames = min(Int(buffer.frameLength), Int(limit - written))
            guard frames > 0, let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
                done = true; lock.unlock(); return
            }
            copy.frameLength = AVAudioFrameCount(frames)
            copy.floatChannelData![0].update(from: source, count: frames)
            let position = written
            written += Int64(frames)
            if written >= limit { done = true }
            lock.unlock()
            queue.async { [self] in
                lock.lock(); let open = !closed; lock.unlock()
                guard open else { return }
                do { try file.write(from: copy) } catch { finish() }
                listener?(UnsafeBufferPointer(start: copy.floatChannelData![0], count: frames), position, format.sampleRate)
            }
        }

        func finish() { lock.lock(); done = true; lock.unlock() }

        /// Flushes queued writes; the AVAudioFile closes when released.
        func close() {
            queue.sync { lock.lock(); closed = true; lock.unlock() }
        }
    }
}
