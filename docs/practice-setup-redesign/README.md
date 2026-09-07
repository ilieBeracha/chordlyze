# Practice setup redesign

Implemented the first selected concept: plain black, no artwork, no gradient. The native setup now has a compact song header, Spotify/Metronome mode buttons, a passage editor, optional recording, audio route and input rows, a direct timing shortcut, and a persistent Start practice button. Recording limits and scoring uploads are explained in an expandable disclosure and the footer.

## Behavior

- Passage opens a sheet with whole-song/section selection and bounded start/end controls.
- Metronome offers 50%, 75%, and 100% pace. Its playback-only path does not open the microphone.
- Turning off recording follows the chart without preparing a take, requesting microphone permission, or scoring. Unrecorded sessions retain the entire selected passage; recorded takes retain the existing ten-minute cap.
- Output shows the detected system route. The native route picker opens Apple's output selection UI. Input is only confirmed after an explicit microphone check; the meter reads real samples without writing an audio file. Leaving setup, disabling recording, or stopping the check releases the probe.
- Recording starts with the microphone primed, then checks the resulting output before starting Spotify. Real Bluetooth routing must still be verified on physical hardware.
- Check timing opens the existing synchronization screen, including its manual calibration path. Automatic synchronization still requires the speaker; recording along with Spotify requires external output.
- Accessibility text sizes stack practice modes and move row actions below labels. Header and primary action stay visible while content scrolls.

## Validation

- Debug simulator and Release iphoneos builds succeeded.
- Practice persistence, interrupted recording recovery, retry, scoring contracts, and 27 feedback checks passed.
- Added regression checks for long unrecorded passages with slowed/calibrated timeline mapping; the recorded-take duration cap remains covered.
- Spotify HTTP/authentication: 18/18 passed.
- Simulator interactions: passage sheet and range summary; microphone check and stop; recording off followed by play-along; metronome selection and pace controls; direct timing navigation; expanded recording details and accessibility text.
- Offline fixture: `--song-sheet-preview --practice-setup-preview`; add `--song-map-large-type` for accessibility text. Its initial revision now matches its status response, preventing a spurious chart-change error when opening directly into setup.

Screenshots: [setup](setup.jpg), [large text](large-text.jpg), [large text lower controls](large-text-details.jpg).

No TestFlight upload or backend release is part of this change. These screenshots use the offline fixture, not real Spotify playback. The earlier reported 502 has not been diagnosed or fixed by this UI change.

Native route picker reference: https://developer.apple.com/documentation/avkit/avroutepickerview
