import AVFoundation
import Foundation

/// Click track for local-clock practice: a count-in, then the song's beat
/// grid. Every click is scheduled up front on one player node at host time,
/// so the grid stays sample-accurate instead of drifting with a timer.
@MainActor
final class Metronome {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private let makeEngine: () throws -> AVAudioEngine
    private var ownsPlaybackSession = false
    private static let sampleRate: Double = 44100
    private let click = Metronome.clickBuffer(freq: 1000)
    private let accent = Metronome.clickBuffer(freq: 1500)

    /// Navigation can construct a PracticeView while displaying Live. Merely
    /// creating this object must not connect an audio graph to the output.
    init(makeEngine: @escaping () throws -> AVAudioEngine = { AVAudioEngine() }) {
        self.makeEngine = makeEngine
    }

    /// Starts clicking immediately: `countIn` beats `period` apart, then one
    /// click per entry of `beats` (seconds after the count-in ends), accented
    /// where `downbeats` says so. The count-in is the bar before the take,
    /// so its last click leads straight into beat 1. Returns the instant the
    /// count-in ends; the recorder should start then.
    func start(countIn: Int, period: Double, beats: [Double], downbeats: Set<Int> = [], recording: Bool = true) throws -> ContinuousClock.Instant {
        stop()
        let session = AVAudioSession.sharedInstance()
        if recording {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
        } else {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
        try session.setActive(true)
        ownsPlaybackSession = !recording
        do {
            // Configure mixing before touching mainMixerNode: its first access
            // connects to the hardware output and can activate the audio session.
            let engine = try makeEngine()
            let player = AVAudioPlayerNode()
            self.engine = engine
            self.player = player
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: click.format)
            try engine.start()
            player.play()

            let lead = 0.15  // scheduling headroom before the first click
            let origin = mach_absolute_time()
            let started = ContinuousClock.now
            func at(_ seconds: Double) -> AVAudioTime {
                AVAudioTime(hostTime: origin + AVAudioTime.hostTime(forSeconds: lead + seconds))
            }
            for i in 0..<countIn {
                player.scheduleBuffer(i == 0 ? accent : click, at: at(Double(i) * period))
            }
            let countInLength = Double(countIn) * period
            for (index, beat) in beats.enumerated() {
                player.scheduleBuffer(downbeats.contains(index) ? accent : click, at: at(countInLength + beat))
            }
            return started + .seconds(lead + countInLength)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        if ownsPlaybackSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsPlaybackSession = false
        }
    }

    /// 30 ms decaying sine burst.
    private static func clickBuffer(freq: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frames = AVAudioFrameCount(sampleRate * 0.03)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            data[i] = Float(sin(2 * .pi * freq * t) * exp(-t * 120) * 0.8)
        }
        return buffer
    }
}
