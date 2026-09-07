import AVFoundation
import Foundation

#if os(macOS)
/// Observe iOS session calls while testing the real production engine lifecycle
/// with macOS AVFoundation. No phone, Spotify token, or output audio is needed.
@MainActor final class AVAudioSession {
    enum Category { case playAndRecord, playback }
    enum Mode { case `default` }
    struct CategoryOptions: OptionSet {
        let rawValue: Int
        static let defaultToSpeaker = Self(rawValue: 1)
        static let allowBluetoothA2DP = Self(rawValue: 2)
        static let mixWithOthers = Self(rawValue: 4)
    }
    struct SetActiveOptions: OptionSet {
        let rawValue: Int
        static let notifyOthersOnDeactivation = Self(rawValue: 1)
    }
    static let shared = AVAudioSession()
    static func sharedInstance() -> AVAudioSession { shared }
    var calls: [String] = []
    var failActivation = false
    func setCategory(_ category: Category, mode: Mode, options: CategoryOptions) throws {
        precondition(options.contains(.mixWithOthers), "Metronome must mix with existing audio")
        calls.append(category == .playback ? "playback" : "recording")
    }
    func setActive(_ active: Bool, options: SetActiveOptions = []) throws {
        calls.append(active ? "activate" : "deactivate")
        if active && failActivation { throw TestFailure.expected }
    }
}
#endif

enum TestFailure: Error { case expected }

@main struct MetronomeLifecycleTests {
    @MainActor static func main() throws {
        let session = AVAudioSession.sharedInstance()
        var graphRequests = 0
        let metronome = Metronome(makeEngine: {
            graphRequests += 1
            precondition(session.calls.last == "activate", "Output graph was built before session mixing was configured")
            // Reproduces a hardware-setup failure without opening a real output.
            throw TestFailure.expected
        })
        // SwiftUI constructs and discards navigation destinations while browsing.
        for _ in 0..<100 {
            let destination = Metronome(makeEngine: { fatalError("Browsing opened audio output") })
            destination.stop()
        }
        metronome.stop()
        precondition(graphRequests == 0 && session.calls.isEmpty, "Construction or idle cleanup touched audio")

        do { _ = try metronome.start(countIn: 0, period: 1, beats: [], recording: false); fatalError("Expected failure") }
        catch TestFailure.expected { }
        precondition(graphRequests == 1 && session.calls == ["playback", "activate", "deactivate"])
        metronome.stop()
        precondition(session.calls.count == 3, "Idle stop released an unowned audio session")

        session.calls = []; session.failActivation = true
        do { _ = try metronome.start(countIn: 0, period: 1, beats: [], recording: false); fatalError("Expected failure") }
        catch TestFailure.expected { }
        precondition(graphRequests == 1 && session.calls == ["playback", "activate"], "Failed activation still opened hardware")
        session.calls = []; session.failActivation = false
        do { _ = try metronome.start(countIn: 0, period: 1, beats: [], recording: true); fatalError("Expected failure") }
        catch TestFailure.expected { }
        precondition(session.calls == ["recording", "activate"], "Metronome deactivated the recorder's shared session")
        print("Metronome lifecycle: browsing, idle cleanup, activation order, failure cleanup and recorder ownership passed")
    }
}
