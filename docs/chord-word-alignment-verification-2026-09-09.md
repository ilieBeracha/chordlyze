# Chord and word timing verification — 2026-09-09

The shared display and timing guards are implemented and tested. They preserve
usable word anchors when other words in the phrase have bad timestamps, and
keep unsupported positions approximate. This does not establish that every
saved lyric timestamp is acoustically correct.

## Shared behavior

- A chord with a supported word association stays with that word when the row
  wraps. Changes between words remain separate, chronological cells. Word
  highlighting retains the original word index.
- Server and iOS use the same word timing contract: finite timestamps inside
  the lyric interval, positive supplied durations no longer than eight seconds,
  and no backward word sequence. Both sides of an inversion are uncertain;
  sorting lyric tokens cannot resolve the ambiguity.
- A stretched transcript prefix is uncertain through its last stretched word.
  Usable suffix stamps survive unchanged. The iOS presentation estimates only
  uncertain positions and never writes those estimates back as measured data.
- Estimated positions cannot anchor chords or establish instrumental rests.
  A partially uncertain phrase receives an approximate-timing explanation even
  when an older server supplied no note. The final phrase is checked against
  the recording duration.
- Catalog onset recovery cannot invalidate a usable word in either neighboring
  phrase or move past a usable word in the phrase being recovered. Failed word
  arrays remain available as source evidence; their usable subset is retained.
- Both worker lyric sources apply the same validation before publication.
  Existing cached charts receive the same provenance and uncertainty flags on
  read, without a new chord analysis or a changed chart revision.

These rules do not select songs by title, artist, or recording identifier.

## Recording-backed recovery

`lyrics_timing.py` retries stretched prefixes and malformed phrase boundaries
against the analyzed recording. A candidate must have valid spans and sufficient
recognition confidence, and agree with at least two measured surrounding
anchors. A complete phrase must be unique in the crop. If recognition omitted
an otherwise usable word, damaged words may still be recovered only when each
is uniquely bracketed by agreeing anchors. Existing usable stamps stay exact.
A correction is rejected if the merged phrase still has invalid timing or would
invalidate a preceding anchor.

A small inversion across two adjacent phrases is checked jointly under the
same rules. Both sides of that boundary must be corroborated before either
changes. A distant stray word cannot make a healthy neighboring phrase
eligible for retiming.

Crops are at most 30 seconds. The primary transcription path permits at most
three prefix retries; publication permits at most three boundary retries. The
single-chart maintenance function shares a three-crop budget across both forms.
Healthy data does not trigger an extra recognition call. Failed or ambiguous
recognition leaves evidence intact and explicitly uncertain.

The recording maintenance command verifies the decoded PCM hash before using
any recognition. Different recordings or encodings cannot silently retime an
existing chart. The batch application command does not itself establish audio
accuracy: its input must already have been reviewed against verified audio.

## Regression evidence

| Check | Verified result |
| --- | --- |
| Shared server/iOS contract | All 124 reported failure geometries, plus healthy controls, use one checked-in numeric fixture with authored words. |
| Retained anchors | 97 of those 124 faulty arrays retain usable anchors; 27 have none and remain coarse until verified from audio. These are presentation outcomes, not counts of acoustically repaired lines. |
| Sheet and playback | 2,528 checks pass, including provenance-only refreshes, transposition, event preservation, and normal Spotify playback flows. |
| Actual SwiftUI rendering | 310 checks and 33 PNGs cover 280–464 point widths, both row styles, playback positions, transposition, RTL, oversized content, repaired intros, and partially damaged phrases. |
| Full backend suite | 613 passed and 17 existing expected failures, including the adjacent-phrase recovery and all nine batch-application tests. |
| Entire saved library | The actual Swift row builder preserves all 11,252 events and 22,078 lyric words across 129 charts; every emitted word association refers to a supported word. |
| iOS compilation | Debug Simulator build passes. |
| Batch safety | Dry run, complete preflight, stale-data refusal, text/event preservation, alias protection, backups, idempotence, and restoration after a write failure are tested. |

The original full-suite attempt hit sandbox restrictions on localhost sockets;
those tests pass with normal localhost access. Likewise, Xcode needs access to
its existing Swift package and compiler caches. These environment failures are
not counted as passing runs.

Earlier negative controls established that the old row views fail the rendered
anchor check and that removing prefix recovery fails both transcription-provider
regressions. The new neighboring-line regressions also failed before their fix.

## Honest audit counts

The original cache contained 93 charts with source timing flags. The former
on-read catalog fallback reported 57 remaining after removing malformed word
arrays. The difference of 36 represented coarse fallback, not verified recovery
of their word positions. The new code retains that evidence, so those original
source flags remain visible until recording-backed correction succeeds.

Do not compare the new evidence-preserving count directly with the old
array-removing count as if both measured acoustic repairs. Report these
separately:

1. Charts and words preserved by the display guards.
2. Words actually changed by accepted recording evidence.
3. Remaining source timing flags and recognition/recording failures.
4. Deployed backend revision and processed TestFlight build.

A timestamp can pass the numeric contract and still be wrong musically. A
sustained vocal can also exceed a conservative duration threshold. Missing or
conflicting recognized text is not permission to invent a timestamp, remove the
lyric, or mark the whole song acoustically verified.

## Reproducing the checks

```sh
bash scripts/test_song_sheet.sh
bash scripts/verify_library_timing.sh /path/to/private/library-model-fixtures.json
cd backend
PYTHONPATH=. python -m pytest tests/test_lyrics_validation.py tests/test_lyrics_boundary_recovery.py tests/test_lyrics_proposals.py
python scripts/audit_lyrics_timing.py --cache /path/to/cache --fail-on-invalid
python scripts/apply_lyrics_proposals.py --cache /path/to/cache --proposals /path/to/reviewed-proposals.json
```

The last command is a dry run unless `--apply` is supplied. It checks the entire
batch before writing, keeps original backups, changes only lyric timing and
metadata, and refuses lyric-text changes or removed word evidence. Matching ISRC
aliases are updated only if their original recording and lyrics still agree.

The timing audit deliberately exits nonzero while source flags remain. Passing
rendering or unit tests does not override that result or prove acoustic accuracy.

Private snapshots, exact recordings, recognition evidence, proposal manifests,
and the recording-level report are retained under
`backend/backups/lyrics-timing-repair-2026-09-09/`, excluded from source control.
No saved lyric payloads, audio, credentials, or provider journals belong in this
public repository. Release state must be checked independently after merge and
deployment; an implemented fix is not automatically in TestFlight.
