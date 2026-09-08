# Chord/word alignment correction — verification, 2026-09-09

Status: the confirmed shared display and estimated-rest bugs are corrected on
`codex/chord-word-alignment`. Production verification for The Push and a new
TestFlight release remain pending. This is not a claim that every recording's
acoustic chord or lyric timing is correct.

## Change

A word-timed row retains each supported chord/word association. Changes between
words occupy separate cells in chronological order, rather than causing all
chords to detach. Chord and word cells wrap together, oversized content fits
the viewport, and the timed chord cursor continues to follow event onsets.
Word highlighting uses the original word index even after gap cells are added.

The aligner, worker and API preserve estimated-word provenance. Existing mixed
recording alignments receive the same flags on read. The row builder requires
measured evidence at both sides before inserting an instrumental rest, and
requires a measured final word end before splitting a tail. No chord onset,
duration, label, beat map, calibration, or scoring reference is changed.

## Regression evidence

The fix is isolated from the pre-existing uncommitted practice and playback
work. The review worktree is `/tmp/chordlyze-alignment-review`, based on
`eb999d0`. The following checks use only this fix on that base:

| Requirement | Evidence |
| --- | --- |
| Valid anchors survive a mixed row | Actual SwiftUI render checks compare the chord glyph and word glyph positions. |
| Chords and words wrap together | Render checks at 280, 320, 390 and 464 points, in sheet and live styles. |
| Every fixture word and change remains visible | Rendered glyph counts and existing model event-preservation checks. |
| Playback and transposition preserve layout | Render checks at five playback positions and two transpositions; sheet/playback suite. |
| RTL and oversized content remain usable | Hebrew render checks and manual review; long word/multiple-change fixture stays within the viewport. |
| Genuine rests still work; estimates do not create rests | Measured/estimated timing matrix, onset-only compatibility, explicit blank lines, malformed timing and phrase-boundary cases. |
| Old charts and old clients remain compatible | Worker/API field round-trip; both song-read paths; idempotent cache repair with no catalog; unchanged chart revision and cache bytes; client refresh accepts provenance-only updates without reanalysis. |
| Neighboring features remain operational | Practice, Spotify, collection/search, drill and live recognition suites. |

`bash scripts/test_chord_layout.sh` passes **258 checks** and writes **25 PNGs**.
The standard `test_song_sheet.sh` command now includes this rendered regression
gate, so its usual invocation covers the views as well as the timing model.
The same harness, compiled with the previous `ChordRowView` and
`ChordLyricLine`, fails with the chord detached horizontally from its word.
This negative control establishes that the test detects the former bug.

`bash scripts/test_song_sheet.sh` passes **1,494 checks** on the isolated branch.
The Spotify suite passes **18**; collection/search **28**; drill detector **362**;
drill worker **43**; input format **6**; live recognition **2,292**. Practice
persistence, feedback, audio integration, report and metronome suites pass.

The complete isolated backend suite requires the installed model runtimes:

```sh
CHORDLYZE_RHYTHM_DIR=/Users/ilieberacha/Desktop/dev/chordlyze/backend \
CHORDLYZE_REQUIRE_MODELS=1 \
NUMBA_CACHE_DIR=/tmp/chordlyze-alignment-numba-cache \
PYTHONPATH=. \
/Users/ilieberacha/Desktop/dev/chordlyze/backend/.venv/bin/python -m pytest tests/ -q
```

Its final result is **411 passed, 17 expected failures**, recorded in
`/tmp/chordlyze-alignment-isolated-backend.log`.
The initial isolated run lacked the rhythm runtime path; its three failures
were installation lookup errors. The main checkout's complete suite passed
421 tests with 17 expected model/vocabulary failures, but includes unrelated
local work and is not substituted for the isolated result.

Debug iOS Simulator builds pass in both the original and isolated worktrees.
The only build warning is skipped App Intents metadata extraction. The actual
song page was inspected with `--song-sheet-preview --mixed-word-timing-preview`.
This fixture has authored words with the reported Shadows timing geometry.

## Reported-song evidence and remaining acceptance

- The saved Shadows chart, passed through the current backend repair and row
  builder, retains every chord event. Its formerly split four-word phrase
  stays one model row, from 33.510 to 45.540 seconds. It may wrap naturally at
  the viewport width. The recovered opening remains at 28.225 seconds.
- The Push's production timestamps have not been inspected. The requested
  read was blocked by automatic approval review and the user permission
  question remains unanswered. Its exact upstream fault is not yet proven.
- Local release configuration has two backend processes (`app` and `worker`);
  both need the new worker/API provenance code. The documented iOS release path
  is the Xcode Cloud workflow after merging into main. Live distribution state
  has not been verified.
- No backend deployment, merge, TestFlight upload, or on-device comparison to
  the source recordings has been performed for this correction.
- Complete acceptance still requires inspecting the two reported production
  payloads, addressing any additional fault exposed by The Push, and verifying
  the release path. Passing the covered checks does not prove zero possible
  regressions or perfect musical alignment across every song.

Temporary visual evidence: `/tmp/chordlyze-alignment-review-renders`,
`/tmp/chordlyze-alignment-simulator.png`. Saved song lyric payloads are kept
outside source control.
