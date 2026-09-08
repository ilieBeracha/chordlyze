# Complete lyrics and phrase-leading chords

## Behavior

Recording alignment must preserve all catalog lines, including repeated occurrences. Matched lines keep their recording times. Unmatched lines receive line-level estimates interpolated between matching anchors, or the nearest anchor offset at an edge. Conflicting/unrelated alignment falls back to complete catalog text. Estimated lines carry no invented word stamps and the response explains that some timing is approximate.

Both the worker and lyric publication endpoint enforce completeness. The endpoint also protects against older workers publishing partial results. Catalog lookup failure still leaves its existing recovery behavior; no new audio downloads or transcription calls are required for cache repair.

The shared Swift row builder uses word timing only when it covers the entire line in order and within its interval. Otherwise it renders all line text with approximate placement. Different lines sharing a timestamp are combined instead of dropping one. Very short wordless gaps cannot swallow a chord event.

A chord starting up to 350 ms before the next phrase can lead that phrase visually once the preceding word has ended. Explicit word ends take precedence; where the final word has no measured end, a conservative 500 ms duration is used. The chord must still sound at the next line's onset. Its event start/end remain unchanged: recognition, playback and scoring are not shifted. This is a bounded display heuristic, not a guarantee of perfect alignment when source times are wrong.

## Horse to Water and existing charts

The actual cached song originally had 23 of 24 nonempty catalog lines. Repair restores the opening line at an estimated 18.37 seconds while preserving the next recording-aligned onset at 26.80. D at 31.82 now leads the phrase at 31.88 rather than sitting over the previous last word. E at 36.74 similarly leads the phrase at 36.90. The actual-song Swift probe confirms every chord event survives unchanged.

On September 8, 2026, 44 shared charts were repaired: 30 needed missing line occurrences restored, and 14 needed incomplete word arrays removed while retaining their full line text. The earlier audit's 21 count measured distinct missing text, so it undercounted missing repeated occurrences. A second dry run found zero pending repairs.

Backup directory on the existing API machine:
`/data/analysis_cache/lyrics-repair-backup-20260908T115330327949Z`

Only lyrics changed. Matching ISRC aliases receive the same repair; aliases for different audio hashes are left alone. Chart data, recording hashes, chart revisions, account corrections and synchronization settings remain unchanged. `backend/scripts/repair_lyrics.py` defaults to a dry run; `--apply` writes backups under the existing library lock and replaces each cache file atomically. A rollback should run under that same lock and restore a backup only after checking that no newer lyric update should be preserved.

## Deployment and validation

The existing Fly API and worker were updated to `8aa7720-lyrics-complete-v2`, built from the previously deployed `8aa7720` with only the backend lyric changes. Health reports `ok` and an online song worker. The deployed publication and worker functions were compared against the tested branch and match. Unrelated local passage-review features were not included in this backend release.

- 1,222 Swift song/playback checks pass, including missing/invalid word stamps, same-time lines, phrase anticipation, sustained prior words, and exact event preservation.
- 38 focused backend checks pass, covering completeness, repeated occurrences, cache backups/idempotence, different-recording aliases, worker publication and the HTTP guard against partial results from older workers.
- Final Debug simulator build succeeded and was installed. An authored `--song-sheet-preview --phrase-boundary-preview` fixture verified visible opening text, complete wrapped phrases and separate D/E phrase rows. A screenshot was inspected; a later scroll inspection was unavailable after the simulator window became inaccessible.
- No physical-phone build or TestFlight upload was performed. Existing phone installs receive restored backend lyrics when refreshed; the phrase-placement and word-rendering changes require the updated iOS app.

Catalog text and actual song payloads used during diagnosis remain outside source control. Regression tests and the simulator fixture use authored lyric text.
