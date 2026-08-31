import AVFoundation
import Foundation

/// Records microphone audio (Shazam-style "listen" capture) to an .m4a file.
@MainActor
final class ListenRecorder: ObservableObject {
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0

    static let maxDuration: TimeInterval = 40

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private(set) var fileURL: URL?

    func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("listen-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.record(forDuration: Self.maxDuration)
        self.recorder = recorder
        fileURL = url
        elapsed = 0
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let rec = self.recorder else { return }
                self.elapsed = rec.currentTime
                if !rec.isRecording { self.finish() }  // hit maxDuration
            }
        }
    }

    /// Stops recording and returns the captured file (nil if nothing recorded).
    @discardableResult
    func stop() -> URL? {
        recorder?.stop()
        finish()
        return fileURL
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
