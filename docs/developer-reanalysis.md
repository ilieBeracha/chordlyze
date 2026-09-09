# Reanalyze a song from Developer tools

Open **Song settings → Developer tools**. This section shows when
the song's full analysis last completed, its analysis-engine version, whether it
matches the current engine, how many engine generations it is behind, and the
recording source when known. Analysis-engine versions are separate from app
versions and App Store releases. “Current” describes recorded engine metadata;
it does not certify that every recognized chord, lyric, or recording match is
musically correct. A model-revision mismatch also makes an analysis non-current,
even when the numbered engine version matches.

Older saved songs can have an unknown analysis date. The app does not substitute
the file's modification time, a catalog refresh, a song's release year, or the date
you opened it. The current engine's release date is likewise shown only when a
trustworthy release value is available; it is currently unknown.

**Reanalyze song** explicitly starts a fresh full-song analysis, even when the
existing chart is current. It obtains and verifies a complete recording, measures
chords and rhythm, then times the lyrics. It does not reuse an earlier download
checkpoint or assume that a previous recording fingerprint is still correct.
For verified artist lyrics, the previously reviewed artist page is a preferred
source for a fresh extraction; its title, artist, edition, and duration are
checked again. Other songs use the normal recording search. The job does not
silently switch verified artist text to another recording page.

The existing playable chart stays available while the replacement is queued,
downloaded, analyzed, and aligned. Developer tools reports progress and failures
separately from that playable chart. Repeated taps during an active analysis or
lyric job do not create another job. If any required phase fails or the chart is
changed in the meantime, the previous chart stays available and its last-analysis
date does not advance. A successful complete replacement records the server's
completion time. Verified instrumental results can finish without sung words;
they cannot erase previously saved lyric text.

Charts are shared, so a completed replacement updates the shared chart and its
compatible recording alias. Personal chord corrections, calibration values, song
lists, and accounts are retained. Corrections and already bound calibrations
remain associated with their original chart or recording and can become stale.
Legacy calibrations without an identity gain the old recording hash before a
replacement; their offsets, scales, and anchors are unchanged. A legacy chart
without a recording hash uses its old chart revision instead. Other songs and
incompatible aliases are not replaced. Compatible version 2 and 3 charts remain
playable and can still request lyric timing without first reanalyzing the chords.

## API and worker contract

`POST /song/{track_id}/reanalyze` uses the normal authenticated user dependency and
accepts `{"expected_chart_revision": "<64-character hash>"}`. The hash may be the
canonical `analysis_info.chart_revision` or the requesting user's current
presented revision. A stale revision receives HTTP 409. The endpoint returns the
normal song status; reading status never queues work. Unlike the normal cached
song request, this action requests full analysis even for a current chart.

Song status adds `analysis_info`:

| Field | Meaning |
| --- | --- |
| `chart_revision` | Canonical saved revision, including for non-playable old/preview charts; null when absent |
| `analyzed_at` | Server completion epoch seconds; null when unknown |
| `analysis_version` | Saved engine generation; null when unknown |
| `current_analysis_version` | Current server engine generation, now 4 |
| `versions_behind` | Nonnegative difference from the saved generation; null when unknown |
| `is_current` | Full-song current engine version and current model revision |
| `model`, `model_revision` | Saved recognizer identity when known |
| `current_model_revision` | Current revision for the named recognizer, or default recognizer when unknown |
| `source_title`, `source_provider` | Recording metadata when available |
| `current_version_released_at` | Verified release epoch seconds, currently null |

The separate `analysis_job` uses the existing public job schema (`state`, `stage`,
`message`, `worker_online`, and queued `ahead`). It follows an explicit reanalysis
through its lyric phase as well as the chord phase; it is null when there is no
full-analysis job. A standalone lyric retry remains visible through `lyrics_job`.
The top-level `job.state` stays `ready` whenever a compatible chart remains
playable. Source engine generation 4 covers the current recording-selection and
lyric-timing pipeline; recognizer weight revisions remain independently tracked.

Reanalysis jobs capture both the old canonical chart revision and lyric
fingerprint. Full-analysis submission validates that baseline and stages the new
chart inside the same durable leased job, then moves to lyric alignment. The warm
worker reuses its freshly downloaded audio. A reclaimed job downloads the exact
staged recording and checks its decoded PCM identity before resuming only the
lyric phase. The old chart is published over only after guarded lyric attachment
or a verified instrumental completion. Publication holds the existing library
lock, uses durable atomic file writes, and restores exact original bytes on
ordinary I/O failure. Before any replacement, a private backup directory saves
every affected original plus a fingerprinted plan of exact new bytes. A process
killed during publication resumes that bounded plan on the next claim, including
its original alias and personal calibration targets. Every file must still equal
its reviewed before or after bytes; later edits stop recovery without being
overwritten. Completed publication recovery does not consume another recording
or recognition attempt. The job stores only an opaque backup reference, and
public status never exposes the private journal. Personal overlays are not
deleted or rebased onto the new chart.

Successful backups remain available for an administrator to review and restore
using `replace_reviewed_chart.py --restore-backup`, as documented in
[reviewed recording replacement](reviewed-recording-replacement.md). That restore
is separately guarded against later edits. Backups are mode 0700 with mode 0600
files and may contain the affected personal library files; keep them private.

Reviewed artist text is available to both the warm and reclaimed lyric phases.
Its existing assertion is rebound only to a newly verified recording from the
same artist page and complete text. A failed or incompatible source result keeps
the old chart intact. User-facing API bodies cannot forge artist review metadata.

`tests/test_reanalysis.py` covers the endpoint and staged lifecycle with authored
fixtures. Existing lyric/source, version-compatibility, and worker tests cover the
shared pipeline. These checks do not download media or write production data.
