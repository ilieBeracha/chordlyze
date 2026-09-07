# Live preview interrupts Spotify

Reported September 7, 2026: Spotify stops immediately when entering Live.

## Finding

`SpotifyLiveView` opens `AnalysisTabsView`, which contains a navigation destination for `PracticeView`. Practice stores a `Metronome` in SwiftUI state. The previous metronome initializer created an `AVAudioEngine`, attached a player, and connected it to `mainMixerNode` immediately, before the explicit start action configured a mixing audio session.

This puts audio-output initialization on a navigation/view-construction path. Apple's [mainMixerNode documentation](https://developer.apple.com/documentation/avfaudio/avaudioengine/mainmixernode) confirms that first access constructs the mixer and connects it to the output node. AVFoundation can activate audio sessions automatically; see [Activating an Audio Session](https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/ConfiguringanAudioSession/ConfiguringanAudioSession.html). This is a plausible cause of the reported immediate interruption. A physical Spotify/iPhone reproduction has not yet confirmed causality.

## Change

`Metronome` construction now stores only its engine factory and click buffers. It creates and connects its engine/player exclusively in `start`, after the mixing category is configured and activated. Idle `stop` neither constructs an engine nor deactivates another component's session. Startup failure releases an owned playback session; recording-mode cleanup leaves session ownership with the recorder. Stopping releases the graph so later starts rebuild it for the current audio route.

No Spotify pause/resume command was added. Live browsing should not take over audio or restart the user's song.

## Verification

`bash scripts/test_practice.sh` passes, including the new `MetronomeLifecycleTests.swift`: 100 simulated destination constructions/idle cleanups make zero engine or session calls; graph creation follows activation; activation failure never constructs the graph; graph failure releases the owned playback session; recording-mode failure does not deactivate the recorder's session. The test uses the production metronome with an injected failing engine factory and a macOS test substitute for iOS session calls, avoiding microphone or output-device access.

Existing practice persistence, report-contract, and 27 feedback checks pass. Release iPhone compilation is recorded in `/tmp/chordlyze-live-audio-build.log`.

Release status: local fix, not yet uploaded to TestFlight. Phone acceptance check: start Spotify through the phone or connected headphones, open Follow live repeatedly, switch songs, and open/back out of Practice without starting it; playback should continue throughout. Explicitly starting the metronome should still produce its count-in, and stopping practice should release its audio resources.
