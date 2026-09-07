# Personal chord corrections

Open **Key & capo → Correct chords**, or long-press a sheet/Live passage and choose
**Correct chords in this passage**. Select the timed occurrence, enter its name
and save. Examples: `C`, `Am7`, `F#`, `Bb/D`, `N.C.`. The editor uses the recording's
original key; transpose and capo still apply when the chart is displayed.

A correction changes one existing interval. Repeated occurrences of the same chord
remain independent. The list includes held chords and no-chord intervals that may
not have a visible chip in the sheet. Corrected entries have a pencil mark and a
**Restore original chord** action. Saving also keeps the song in your library.

The shared song document updates the sheet, Live, diagrams, key/capo suggestion,
bar map and practice targets. The backend recomputes key, Roman numerals and
difficulty from the corrected chord sequence while preserving its boundaries,
audio identity, lyrics and beat/section timing. Practice grading reads the same
account's corrected sequence. Recognition still has its documented quality limits;
a manually entered chord does not expand the audio model's vocabulary.

## Persistence and conflicts

Corrections are stored atomically in the account's existing user-library JSON,
under each song's `corrections` field. Global track/ISRC charts and other accounts
are unchanged. Corrections survive app restarts and status polls; removing a song
from the library deletes its personal settings, including corrections.

The overlay records a fingerprint of the original recording, recognizer provenance
and chord boundaries/labels. A replacement analysis with a different fingerprint
suspends the old overlay and displays a notice in the editor. It never transfers
corrections onto potentially different moments. Saving a correction on that new
chart starts a new overlay. Lyrics-only or title changes do not invalidate edits.

`PUT /library/{track_id}/chords` accepts `chart_revision`, `start`, `end`, and `name`
(display spelling, or `null` to restore that occurrence). It authenticates the caller,
validates the chord, and checks the effective revision and exact interval under
the library lock. A stale editor receives 409. The response is the updated song
status. Song status and direct chart reads expose `chart_revision`,
`corrections_stale`, and `original_label` on edited segments. Library metadata
reflects personal corrections; the shared catalog retains the original analysis.

The client invalidates in-flight status reads before a save so stale responses
cannot undo it. It resumes polling after success or failure. Failed edits retain
the previous chart and keep the editor's text available for retry.

New practice takes persist the chart revision at preparation and send it when
submitted or retried. If the reference changed, scoring returns 409 before decoding
the audio, leaving the local recording intact. A new take is needed for the current
chart. Older takes without a revision retain their legacy behavior. The client also
checks the revision echoed by the scoring response; an older service cannot
silently ignore this contract.

## Verification

- `PYTHONPATH=backend backend/.venv/bin/python -m pytest backend/tests/test_corrections.py backend/tests/test_users.py backend/tests/test_practice_api.py -q`
- `bash scripts/test_song_sheet.sh`: edited display, transposition, restoration,
  failed-save recovery and a delayed pre-edit status response.
- `bash scripts/test_practice.sh`: persisted revision, multipart request, legacy
  compatibility and rejection of a response missing the expected revision.
- Debug launch with `--song-sheet-preview --chord-corrections-preview` provides an
  offline editor fixture. It never edits or requests a real song.

This change requires both the updated iOS app and backend. A backend without revision
metadata leaves the editor disabled. This implementation does not publish either.

Verified locally on 2026-09-07: 66 backend correction/user/practice/version/job
checks passed; 1,142 Swift song/playback checks passed; practice persistence and
request-contract suites passed, including 27 feedback checks. The final iOS
simulator build succeeded. The offline list and editor rendered correctly and
accepted `Dm7`; simulator window changes interrupted the final save/restore
click-through, so interactive end-to-end verification is not claimed. Save and
restore were verified through the production store and authenticated HTTP tests.

## Timing and structural edits

The [synchronization and boundary editor](synchronization-and-boundary-editing.md)
extends this feature with moving boundaries, splitting, merging and a ten-edit
undo history. New overlays store full segment snapshots; existing label-only
corrections migrate without losing their edits. The earlier single-interval/API
description above still applies to name changes.
