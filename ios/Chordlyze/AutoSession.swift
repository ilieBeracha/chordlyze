import AVFoundation
import Foundation
import ShazamKit

/// Continuous listening session: identifies each song as it plays, captures a
/// window of audio for it, analyzes chords in the background, moves on when the
/// next song starts. Play a playlist out loud and the chord library fills itself.
@MainActor
final class AutoSession: ObservableObject {
    /// One session for the whole app — survives navigation; only the Stop button ends it.
    static let shared = AutoSession()

    struct Entry: Identifiable, Equatable {
        enum Status: Equatable {
            case capturing
            case analyzing
            case done
            case failed(String)
        }
        let id: String           // trackKey (shazam-<isrc>)
        let title: String
        let artist: String
        let artworkURL: URL?
        var status: Status
        var analysis: ChordAnalysis?

        static func == (l: Entry, r: Entry) -> Bool { l.id == r.id && l.status == r.status }
    }

    @Published var isRunning = false
    @Published var entries: [Entry] = []
    @Published var statusLine = ""
    /// Song currently identified as playing, with its live position anchor.
    @Published private(set) var nowPlayingKey: String?
    private var liveAnchor: (key: String, offset: TimeInterval, at: Date)?

    /// Entry for the song currently identified as playing.
    var nowEntry: Entry? {
        nowPlayingKey.flatMap { key in entries.first(where: { $0.id == key }) }
    }

    /// Current playback position inside the identified song, if known.
    func livePosition(for key: String) -> TimeInterval? {
        guard let anchor = liveAnchor, anchor.key == key else { return nil }
        return anchor.offset + Date().timeIntervalSince(anchor.at)
    }

    /// Safety cap so one capture can't grow unbounded (radio stream, no song change).
    private static let maxCaptureSeconds: Double = 600

    private let engine = AVAudioEngine()
    private var session: SHSession?
    private var delegateBox: SessionDelegateBox?
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var currentKey: String?
    private var captureStart: Date?
    /// Rolling pre-buffer: audio heard before the song was identified, so the
    /// capture includes the intro from the song's actual start.
    private let preRoll = PreRollBuffer(maxSeconds: 20)

    func start() async {
        guard !isRunning else { return }
        guard await AVAudioApplication.requestRecordPermission() else {
            statusLine = "Microphone access denied — enable it in Settings."
            return
        }
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .default)
            try audioSession.setActive(true)
        } catch {
            statusLine = "Audio session error: \(error.localizedDescription)"
            return
        }

        let shazam = SHSession()
        let box = SessionDelegateBox { [weak self] item in
            Task { @MainActor in self?.handleMatch(item) }
        }
        shazam.delegate = box
        session = shazam
        delegateBox = box

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        preRoll.clear()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            guard let self else { return }
            self.session?.matchStreamingBuffer(buffer, at: time)
            self.preRoll.append(buffer)
            try? self.file?.write(from: buffer)
            Task { @MainActor in self.enforceCaptureCap() }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            statusLine = "Could not start capture: \(error.localizedDescription)"
            return
        }
        isRunning = true
        statusLine = "Listening — play your playlist out loud."
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        finalizeCurrentCapture()
        session = nil
        delegateBox = nil
        isRunning = false
        statusLine = "Session stopped."
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Song transitions

    private func handleMatch(_ item: SHMatchedMediaItem) {
        let key = (item.isrc).map { "shazam-\($0)" } ?? item.shazamID.map { "shazam-\($0)" }
        guard let key else { return }
        // Every match (repeats included) refreshes the live position anchor.
        liveAnchor = (key, item.predictedCurrentMatchOffset, Date())
        nowPlayingKey = key
        guard key != currentKey else { return }

        finalizeCurrentCapture()
        currentKey = key
        statusLine = "Now: \(item.title ?? "Unknown") — \(item.artist ?? "")"

        if let idx = entries.firstIndex(where: { $0.id == key }) {
            // Same song heard again this session; nothing to do if already handled.
            if entries[idx].status != .capturing { return }
        } else {
            entries.insert(Entry(id: key,
                                 title: item.title ?? "Unknown",
                                 artist: item.artist ?? "",
                                 artworkURL: item.artworkURL,
                                 status: .capturing,
                                 analysis: nil), at: 0)
        }

        // Capture from the start (pre-roll included) in case nothing faster works…
        beginCapture(for: key)
        // …meanwhile try the instant paths: cache, then server-side iTunes preview.
        let isrc = item.isrc
        let title = item.title
        let artist = item.artist
        Task { @MainActor in
            var ready = await BackendClient.cachedAnalysis(trackID: key)
            if ready == nil {
                ready = await BackendClient.analyzeTrack(trackID: key, isrc: isrc,
                                                         title: title, artist: artist)
            }
            guard let ready else { return }  // no preview — mic capture carries on
            self.update(key) { $0.status = .done; $0.analysis = ready }
            if self.currentKey == key { self.stopCaptureFileOnly() }
        }
    }

    private func beginCapture(for key: String) {
        guard currentKey == key, isRunning else { return }
        let format = engine.inputNode.outputFormat(forBus: 0)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-\(UUID().uuidString).caf")
        do {
            let newFile = try AVAudioFile(forWriting: url, settings: format.settings)
            // Prepend what was heard before identification — the song's intro.
            for buffered in preRoll.drain() {
                try? newFile.write(from: buffered)
            }
            file = newFile
            fileURL = url
            captureStart = Date()
        } catch {
            update(key) { $0.status = .failed("capture: \(error.localizedDescription)") }
        }
    }

    private func enforceCaptureCap() {
        guard let start = captureStart, isRunning,
              Date().timeIntervalSince(start) >= Self.maxCaptureSeconds else { return }
        finalizeCurrentCapture()
    }

    private func stopCaptureFileOnly() {
        file = nil
        fileURL = nil
        captureStart = nil
    }

    /// Close the current capture file and send it for analysis.
    private func finalizeCurrentCapture() {
        guard let key = currentKey, let url = fileURL, file != nil else {
            stopCaptureFileOnly()
            return
        }
        stopCaptureFileOnly()
        update(key) { $0.status = .analyzing }
        let entry = entries.first(where: { $0.id == key })
        Task { @MainActor in
            do {
                let result = try await BackendClient.analyze(fileURL: url, trackID: key,
                                                             title: entry?.title, artist: entry?.artist)
                self.update(key) { $0.status = .done; $0.analysis = result }
            } catch {
                self.update(key) { $0.status = .failed(error.localizedDescription) }
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func update(_ key: String, _ mutate: (inout Entry) -> Void) {
        guard let idx = entries.firstIndex(where: { $0.id == key }) else { return }
        var entry = entries[idx]
        mutate(&entry)
        entries[idx] = entry
    }
}

/// Thread-safe rolling audio buffer fed from the realtime tap. Keeps the last
/// `maxSeconds` of audio so a capture can include sound heard before the match.
final class PreRollBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var seconds: Double = 0
    private let maxSeconds: Double

    init(maxSeconds: Double) { self.maxSeconds = maxSeconds }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let copy = Self.copy(buffer) else { return }
        let dur = Double(buffer.frameLength) / buffer.format.sampleRate
        lock.lock()
        buffers.append(copy)
        seconds += dur
        while seconds > maxSeconds, !buffers.isEmpty {
            let removed = buffers.removeFirst()
            seconds -= Double(removed.frameLength) / removed.format.sampleRate
        }
        lock.unlock()
    }

    func drain() -> [AVAudioPCMBuffer] {
        lock.lock()
        defer { buffers.removeAll(); seconds = 0; lock.unlock() }
        return buffers
    }

    func clear() { _ = drain() }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                          frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let src = buffer.audioBufferList.pointee
        let dst = copy.mutableAudioBufferList.pointee
        for i in 0..<Int(src.mNumberBuffers) {
            let s = withUnsafePointer(to: src.mBuffers) { UnsafeBufferPointer(start: $0, count: Int(src.mNumberBuffers))[i] }
            let d = withUnsafePointer(to: dst.mBuffers) { UnsafeBufferPointer(start: $0, count: Int(dst.mNumberBuffers))[i] }
            if let sData = s.mData, let dData = d.mData {
                memcpy(dData, sData, Int(s.mDataByteSize))
            }
        }
        return copy
    }
}

private final class SessionDelegateBox: NSObject, SHSessionDelegate {
    let onMatch: (SHMatchedMediaItem) -> Void
    init(onMatch: @escaping (SHMatchedMediaItem) -> Void) { self.onMatch = onMatch }
    func session(_ session: SHSession, didFind match: SHMatch) {
        if let item = match.mediaItems.first { onMatch(item) }
    }
    func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {}
}
