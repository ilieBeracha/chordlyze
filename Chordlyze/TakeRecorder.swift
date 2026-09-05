import AVFoundation
import Foundation

/// Records a practice take from the microphone to an .m4a file.
@MainActor
final class TakeRecorder {
    private var recorder: AVAudioRecorder?
    private(set) var fileURL: URL?

    /// False once the recorder hit `maxDuration` on its own.
    var isRecording: Bool { recorder?.isRecording ?? false }

    func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start(maxDuration: TimeInterval, at url: URL) throws {
        let session = AVAudioSession.sharedInstance()
        // playAndRecord (not record) so a running metronome keeps clicking;
        // mixWithOthers so activating the session doesn't pause Spotify.
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
        try session.setActive(true)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        guard recorder.record(forDuration: maxDuration) else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw CocoaError(.fileWriteUnknown)
        }
        self.recorder = recorder
        fileURL = url
    }

    /// Stops recording and returns the captured file; nil if nothing was
    /// started. The file is the caller's to delete.
    func stop() -> URL? {
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        defer { fileURL = nil }
        return fileURL
    }
}
