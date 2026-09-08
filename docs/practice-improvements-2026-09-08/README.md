# Practice: clearer entry points and trustworthy live feedback

## What changed

The main Practice tab now uses the app's shared music typography and a restrained green background that fades into black. Song practice has the primary action. Chord recognition and one-minute changes have distinct entries, larger chord selectors, and a same-chord guard. The selected pair persists between visits. Saved takes show their recording time, review state, and a purposeful empty state. Accessibility text sizes stack the chord controls and recording feedback instead of compressing them.

The review started with a fresh simulator capture, [before.png](before.png). It showed a flat hierarchy, a low-contrast white-on-green action, small chord selectors, and weak separation between tools and recordings. [after.png](after.png) records the new hierarchy; the preview uses an isolated sample recording and does not overwrite account takes.

## Detection fixes

- **Soft playing:** practice and paired drills still had a 0.0006 RMS entry floor and higher initial noise estimate. They now share the adaptive gate used by standalone recognition: minimum entry 0.00012, continuation 0.00006, noise-relative thresholds, and an abrupt-mute reset. Tonal decay cannot teach the gate to reject the next soft strum.
- **Transition artifacts:** unrestricted song practice now requires 250 ms of consecutive chord evidence, like standalone recognition. Paired drills retain their 70 ms confirmation. All chord qualities remain in the vocabulary; the algorithm is not restricted to the expected progression.
- **Timing:** snapshots include an estimated analysis-window/confirmation delay (`0.75 × frameSize / sampleRate + confirmationDuration`). Practice removes this in real seconds before chart-rate conversion. At 44.1 kHz the song-practice estimate is about 0.53 seconds. This remains an estimate, not headphone or instrument calibration.
- **Missing feedback marks:** practice targets now use `SheetModel.events(analysis)`, exactly like the chart. Previously, beat-snapped chord chips requested verdicts at timestamps that did not exist in the raw-segment feedback table.
- **Premature credit:** repeated same-chord intervals are no longer credited in advance. Held feedback requires a confirmed chord actually observed inside that interval. Silence does not earn a match.
- **Visible evidence:** during a recorded take, the panel shows the chart target, confirmed heard chord, microphone level, provisional/quiet state, and last judgment. With a capo, the target is labeled Sounding. Green identifies a pitch-set match; a different recognized chord is still shown without implying success. The input meter now includes quiet audio below its former −60 dBFS display floor.
- **Failures:** detector creation and input-format failures display an explicit unavailable message while the take continues recording, rather than silently remaining at Listening.

The final backend scoring model is separate and unchanged. These updates improve on-device feedback; they do not claim to upgrade the later uploaded-take analysis.

## Validation

- `bash scripts/test_drill.sh`: 362 detector checks, 43 audio-worker checks, 6 input-format checks, 2,292 stable-recognition checks across both standalone and practice modes, and 3 benchmark-semantics tests.
- `bash scripts/test_practice.sh`: 34 feedback checks, 40 audio-to-feedback integration checks, plus take persistence, upload retry, report contracts and metronome lifecycle checks.
- The integration tests feed actual synthetic Am → C → G strums through the production practice detector and feedback model at 44.1/48 kHz, normal/soft gain and normal/half chart rate. They require all three targets to match and estimated offsets to remain bounded. Noise, genuine extensions, restarts, release overlap and transient mixtures are exercised by the shared recognition tests.
- Debug iOS simulator build passed. Main navigation to song selection, chord recognition and the selected Em/G drill was checked without starting the microphone. Selecting the same chord twice disables Start changes.
- Captured and inspected the main page, accessibility-size header, empty state, and isolated live-feedback display states. See the PNGs in this directory.

The simulator build is installed locally. No backend release, GitHub publication, or TestFlight upload is part of this change. Real instrument recordings through the user's microphone remain necessary to assess acoustic accuracy; the historical GuitarSet benchmark was not rerun for these thresholds.

## Reproduce display states

Launch the Debug app with `--music-preview --music-practice`. Add `--music-large-type` for accessibility text size, `--practice-empty` for no recordings, or `--practice-feedback` for the listening/recognition/failure panels. A visible preview label identifies the fixture. These flags never activate a microphone or control Spotify automatically.
