# Chord recognition and passage review

## Using it

- Practice → **Recognize a chord** → **Listen** recognizes a held instrument chord on the phone. The sign-in screen also offers this tool without an account. Opening it does not activate the microphone. Stop, leaving the screen, backgrounding, interruptions and route changes release the microphone. Audio is neither saved nor uploaded. Recent confirmed changes are capped at 12; tap a chord to see its fingering.
- Song sheet → **Correct chords** → **Show uncertain chords only** filters occurrences with review evidence. Open an occurrence to see acoustic alternatives. Selecting one fills the editor; **Save** remains explicit. Older charts have no such evidence until a new analysis or a passage reanalysis provides it.
- **Correct chords → Reanalyze a passage** accepts 2–30 seconds on the original recording timeline. It retrieves the matching recording, analyzes a crop with four seconds of context on either side, and presents the current/proposed chords. **Apply passage changes** updates only the personal chart; **Undo last edit** restores the prior chart. Opening or reopening only reads status; it never starts preparation.

## Behavior and limits

The live detector reuses the deterministic NNLS pitch/chord classifier and bounded DSP worker used for practice. It rejects silence and ambiguous input instead of keeping the last chord on screen. It works best with one clearly held instrument; its synthetic regression tests are not a claim of accuracy for every instrument, room or playing style. Explicitly starting microphone capture may interrupt other playback.

Review alternatives are ranked by mean acoustic log support from the pinned ISMIR ensemble over the decoded interval. A disagreement with the temporal decoder, a close leading alternative, or a very short change flags review. These are heuristic review cues, not calibrated confidence percentages. Manual label/boundary changes discard cues that no longer match. Undo restores the previous cues.

The passage decoder uses the same verified weights, with a transition penalty of 10 instead of 30 to allow more local changes. The normal penalty is explicitly restored on every ordinary inference request. This can produce a different proposal, not necessarily a better one; nothing applies automatically. The entire recording must still be retrieved and decoded to verify its exact PCM SHA-256 identity. Only the contextual crop enters chord inference. A different recording is rejected without changing the chart.

Passage jobs reuse the durable leased song queue and existing worker. No extra worker, model download, isolation component or audio cache is introduced. Jobs are private to account and track, scoped to the library generation, limited to 3 pending per account and 12 globally. Chart revision and recording identity are checked before applying. All intervals different from the base analysis are preserved, including prior accepted passage edits. A repeat Apply after a lost response is idempotent. Status is rediscovered after relaunch; transient reads retry three times before exposing Check status. Provider delays can still delay preparation. Cancel preparation invalidates the lease and permits a fresh request; an old worker result cannot publish afterward.

## Validation

Backend coverage includes the HTTP lifecycle, per-account isolation, range/identity/revision/lease checks, manual and boundary edit preservation, undo with evidence, worker cleanup, cancellation, crop mapping, and inference with the actual pinned weights. Swift checks cover read-only reopening, no duplicate requests, bounded failure retries, lost-response discovery and rejection of late cancelled results, alongside the existing song/playback and audio suites. Debug-only screenshot fixtures use authored charts and injected services; they cannot publish or fetch real songs.

Debug previews: `--chord-recognition-preview`, or `--song-sheet-preview --passage-preview`, or `--song-sheet-preview --chord-corrections-preview`.

Verified on September 8, 2026: 395 backend tests passed, with 17 existing expected model limitations; 1,212 song/playback checks; 346 detector, 43 audio-worker, 6 input-format and 27 practice-feedback checks. Practice take/report/metronome suites also passed. Simulator Debug and iPhone Release builds succeeded. Simulator screenshots confirm the idle recognition screen and passage selection/comparison layout; physical microphone behavior still needs a check with the user's instrument.
