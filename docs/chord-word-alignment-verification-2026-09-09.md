# Chord/word alignment correction — verification, 2026-09-09

Status: **the two reported cases are verified, but all-song acceptance is not
met.** The confirmed shared display and estimated-rest bugs are corrected on
`codex/chord-word-alignment`. Both approved production payloads have now been
inspected, including the missing transcription-only case in The Push. A backend
deployment and a new TestFlight release remain pending. This is not a claim
that every recording's acoustic chord or lyric timing is correct.

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

Malformed transcription prefixes now receive a bounded acoustic retry through
the bundled local speech model, for either primary transcription provider.
Exact phrase matching and agreement with healthy following anchors gate the
repair. Healthy suffix stamps and every other phrase retain their prior values.
The maintenance command verifies the decoded recording identity, defaults to
dry run, backs up applied changes, and refuses concurrent chart replacement.

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
| No-catalog recordings receive the repair | Both provider paths exercise acoustic recovery; approved The Push data and verified audio reproduce and correct the missing case. |
| Healthy timing is not reinterpreted | No crop for healthy data; exact healthy suffix preservation; conflicting text/anchors, invalid candidates and exhausted retries leave original data intact. |
| Saved timing cannot be applied to the wrong recording | Decoded PCM identity check, dry-run/apply/backup tests, concurrent chart rejection and differing alias preservation. |

`bash scripts/test_chord_layout.sh` passes **285 checks** and writes **29 PNGs**.
The standard `test_song_sheet.sh` command now includes this rendered regression
gate, so its usual invocation covers the views as well as the timing model.
The same harness, compiled with the previous `ChordRowView` and
`ChordLyricLine`, fails with the chord detached horizontally from its word.
This negative control establishes that the test detects the former bug.
Disabling acoustic recovery also makes both provider regression cases fail
on their opening timestamp, establishing that those tests detect the missing
no-catalog repair.

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

Its final result is **443 passed, 17 expected failures**, recorded in
`/tmp/chordlyze-alignment-audit-backend.log`.
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
- The user approved the production read. The Push's saved data confirms a
  transcription-only source, no matching cached catalog, and a 16.78-second
  word span. The production response reproduces all eight changes on a lyric
  row beginning at 0:00. Using the saved provider recording, decoded on the
  deployed runtime, produced the exact PCM hash stored with the chart.
- The new recovery places The Push's opening at 18.600 seconds. Only its first
  two word stamps change. The other 36 lines, the healthy suffix, every lyric
  word and all 65 chord events are unchanged. The real row builder places six
  intro events before the vocal and associates the two vocal changes with word
  indices 2 and 5. No event is omitted or duplicated in either reported song.
- Actual SwiftUI rows were rendered from both repaired production payloads at
  320 and 390 points and inspected. Saved lyrics and recordings remain outside
  source control; checked-in fixtures use authored words.
- A dry run using the deployed decoder and bundled speech model also recovered
  The Push at 18.600 seconds, changed only the two damaged word stamps, and
  preserved all healthy words and chord data. Its proposal was written under
  `/tmp`; the shared production chart was not changed.
- Local release configuration has two backend processes (`app` and `worker`);
  both need the new worker/API provenance code. The documented iOS release path
  is the Xcode Cloud workflow after merging into main. Live distribution state
  has not been verified.
- No backend deployment, merge, TestFlight upload, or on-device comparison to
  the source recordings has been performed for this correction.
- Release acceptance still requires deployment, applying the verified saved
  transcription correction, and a processed TestFlight build. Passing the
  covered checks does not prove zero possible regressions or perfect musical
  alignment across every song.

Temporary visual evidence: `/tmp/chordlyze-alignment-review-renders`,
`/tmp/chordlyze-alignment-simulator.png`. Saved song lyric payloads are kept
outside source control.

## All-song acceptance remains open

A read-only aggregate audit of the entire shared song cache found additional
malformed and out-of-line word timestamps after the proposed on-read repair.
The numeric production report is retained locally. These flags identify
structural timing problems, not proof that every flagged song has the exact
visible failure in the screenshots. They rule out treating the two reported
examples as evidence that every saved song has been repaired.

The acoustic retry is bounded and requires supporting anchors. The worker
change does not retroactively transcribe every cached chart. Untimed lines
remain explicitly separate from lines with verified word timestamps.

The reproducible command is included in the backend image:

```sh
python scripts/audit_lyrics_timing.py --cache /data/analysis_cache --fail-on-invalid
```

This check returned a nonzero status on the audited cache, as intended. It
fails for unresolved invalid timing, incomplete or out-of-range word arrays,
an empty/unreadable cache, non-lyric mutations, or charts changed during the
audit. Seven audit tests cover those contracts; the combined lyric suite
passes 67 tests. This is a manual release check, not an installed CI requirement.
Passing it establishes structural validity, not acoustic truth.

The remaining cases require classification, recording-backed repair where
possible, a repeat audit, and rendered/recording checks for each distinct
failure pattern. Add those cases to the regression suite before claiming
broader coverage. Do not merge this PR under an all-song completion claim.
