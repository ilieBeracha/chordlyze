# Automatic synchronization and chord boundaries

## Automatic sync

Open **Key & capo → Automatic sync**. Use the phone speaker, keep the room quiet
and leave the screen open. The app requests microphone permission, opens input
before starting Spotify, then listens to three 12–22 second passages spread
through the song. It returns playback to the original position after capture.
The screen stays awake during the operation. Leaving, backgrounding, a route
change, interruption, pause, seek, song change or chart change cancels/rejects
capture. Temporary recordings are removed after success, failure or cancellation.

This uses the existing Spotify device/play controls; starting those passages has
the same account/device requirements as starting a practice take. The microphone
must hear the recording. It does not capture a headphone stream internally.
Songs shorter than 45 seconds use the existing calibration-by-ear flow.

The backend recognizes the three samples with the installed rich chord model and
searches one map: `spotifyTime = scale × chartTime + offset`. The search covers
±30 seconds and 0.9–1.1× scale. With less than 60 seconds between the first and
last sample starts, it estimates offset only because drift is poorly constrained.
It compares root and triad family rather than demanding reliable extension
recognition from room audio. No model or external dependency was added.

Acceptance requires at least three chord identities and six heard changes, music
in at least 60% of each sample, aggregate agreement ≥0.78, agreement ≥0.65 in every
sample, and ≥0.06 separation from another map displaced by at least 1.5 seconds
at a sampled endpoint. A fit at the search boundary is rejected. These are
engineering acceptance thresholds, not calibrated probabilities or an accuracy
guarantee. Silence, an ambiguous repeated progression, a different arrangement or
unclear recording leaves existing timing untouched. This affine model does not
claim to handle arbitrary tempo changes or inserted/removed song sections.

`POST /library/{track_id}/synchronize` receives three multipart `files`, JSON
`positions`, `chart_revision` and `timing_revision`. The endpoint authenticates the
user, limits each sample to 8 MB and recognizes at most 30 seconds per sample.
It checks both revisions before recognition and again before the atomic save;
newer edits or calibration are never overwritten. It checks disconnection before
committing. A cancellation racing an already completed commit may still have
saved; the next status read reconciles the authoritative state.

Accepted maps are account-specific and identify the chart revision, audio hash
and Spotify track. The shared song document applies them to Sheet, Live, seeking,
loops and new practice recordings. A changed chart disables incompatible timing
instead of continuing to use a stale map. Undoing the edit can restore its match.
Maps survive reconnects through the existing playback clock/status polling.
They do not continuously reopen the microphone or silently adjust during practice.

## Boundary editing

Open **Key & capo → Correct chords**, select an occurrence, then **Edit chord
timing**. You can:

- Move its start or end with a slider, 0.1-second stepper, or exact seconds field.
  The neighboring interval moves with it, keeping both sides joined.
- Split an interval and name the second chord.
- Merge it with the next interval, choosing the chord to keep.
- Undo the last edit or restore the entire analyzed chart from the correction list.

Intervals must remain at least 0.1 seconds long. Edits cannot cross unanalyzed
gaps, move the first/last outer endpoint, overlap intervals or create missing
coverage. Split and merge retain total coverage. Original audio, lyrics, beats
and section times are preserved. Derived key, Roman numerals, difficulty, sheet
rows and practice targets are recomputed from the personal chart.

`PATCH /library/{track_id}/chords/boundary` accepts a revision and operation
`move`, `split`, `merge`, `undo` or `restore`. Other fields are `start`, `end`,
`at`, `edge` (`start`/`end`), and optional display `name`. Every operation runs
under the existing library lock. Stale editors get 409. Personal overlays now
store the complete edited segment list plus the last ten pre-edit snapshots.
The old label-only overlay format remains readable and migrates on the next edit.
Name editing continues to work on newly split and moved intervals. The original
name can be restored individually where one original interval fully contains the
edited interval; use Undo or Restore analyzed chart for structural changes.
Removing a song from the library also removes its personal corrections/history.

Practice takes already retain their chart revision. Both names and boundary
changes invalidate older unscored takes rather than silently grading them against
a different chart. Audio stays available on the phone.

## Verification

```sh
NUMBA_CACHE_DIR=/tmp/chordlyze-numba-cache PYTHONPATH=backend backend/.venv/bin/python -m pytest \
  backend/tests/test_synchronization.py backend/tests/test_boundaries.py \
  backend/tests/test_corrections.py backend/tests/test_users.py backend/tests/test_practice_api.py -q
bash scripts/test_song_sheet.sh
bash scripts/test_practice.sh
```

The synchronization tests include synthetic offset/drift recovery, ambiguous
repetition, silence, wrong arrangements, failed revision checks and real model
recognition of generated audio. Boundary tests cover invariants, undo, restoration,
legacy overlay migration, account separation and the corrected scoring interval.
Swift checks cover listening-window planning, playback discontinuities, multipart
serialization, store updates, failed edit recovery and stale-map invalidation.

A simulator cannot establish speaker/microphone timing in a real room. A physical
phone test against Spotify is still required to measure capture latency, route
behavior and tolerance to different mixes/background noise. No app or backend
was deployed by this implementation.

Local verification on 2026-09-07: 131 backend tests passed (sync, boundaries,
corrections, users, practice, analysis versions and job regressions); 1,171 Swift
song/playback checks passed; practice persistence/request-contract suites and
27 feedback checks passed. The iOS simulator build succeeded. The installed
recognizer recovered the known map from generated audio. In the offline simulator
fixture, changing C's end from 6 to 8 seconds visibly changed the following G7's
start to 8 seconds; Undo restored both to 6 seconds. Physical room/Spotify capture
is the remaining validation limit described above.
