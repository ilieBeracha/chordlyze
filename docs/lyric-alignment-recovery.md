# Recording-backed lyric alignment and recovery

A usable chord chart can exist before its sung words have been measured. Plain
catalog lyrics contain estimated line positions and cannot establish when a vocal
starts. Opening a song or refreshing status does not schedule transcription.

## App contract

`POST /song/{track_id}/lyrics/request` accepts `{"retry": false}` and returns the
normal song status. It uses the saved recording metadata and queues only lyric
alignment. A pending request is deduplicated even with `retry: true`. A completed
or unsuccessful prior lyric job is retained until an explicit `retry: true`.
The endpoint requires the same authenticated user dependency as song requests.

The additive `lyrics_job` field has the same public shape as `job`: `state`,
`stage`, `message`, `worker_online`, and `ahead` when queued. States are `missing`,
`queued`, `processing`, `ready`, `unavailable`, and `failed`. The `aligning` stage
means the downloaded recording is being used to time lyrics. The main `job`
remains `ready` whenever a usable chord chart exists, including during lyric
alignment or after a failed attempt. Older clients can ignore `lyrics_job`.

An unavailable result means the worker could not verify sung word intervals or
recover the exact analyzed recording. A failed result means the job did not
finish. Existing chords and lyrics remain available in both cases. A job must
produce at least one supported word with a measured start and end to publish
recording-aligned lyrics. Partial timing still carries its approximate-timing
note; it is not certification of every word in the song. Enhanced catalog word
onsets alone no longer bypass recording alignment.

The API validates the final reconciled payload before writing. Catalog fallback
cannot turn a measured proposal into an all-estimated successful result. Timing
retries must retain every previously saved lyric word occurrence in order,
including repeated verses; a shorter or conflicting transcript leaves the
original text and timing intact. Capitalization, punctuation, line wrapping, and
additional text can change without removing known words.

## Worker lifecycle

New workers send `prepare_lyrics: true` when publishing chord analysis. Under the
library lock, the API publishes the playable chart and changes the existing
leased job to `kind: lyrics`. It returns that job only in the worker submission
response. The worker uses the same downloaded audio and keeps heartbeating while
it aligns; it does not redownload the recording or run chord inference again.
The configured concurrent claim loops continue to process other songs.

If the worker stops after the chart is published, lease expiry makes the lyric
phase reclaimable. Recovery retains the original download checkpoint and runs
only lyric alignment. Existing interrupted-job retry limits remain in force.
The managed worker no longer depends on the volatile background alignment queue.

Every new lyric job records the chart's `expected_audio_sha256` and
`expected_lyrics_sha256`. Recovery decodes the fetched audio with the same decoder
and PCM hashing implementation as chord recognition. A mismatch ends the job
before lyric transcription. Administrative lyric jobs created by older tools
receive these expectations when first claimed.

Guarded publication supplies the job ID, lease, library generation, and both
expected fingerprints. The API rechecks them under the library lock before
writing, so an expired job, replaced recording, or newer lyric correction cannot
be overwritten. Publishing lyrics and completing the job occur in the same
locked API operation; a lost success response cannot queue another alignment.
Matching ISRC aliases receive only lyric fields and retain their own metadata;
aliases with different lyric evidence remain unchanged.

Older analysis submissions without `prepare_lyrics` retain their existing
contract. Deploy the API before the managed worker and app. No bulk migration or
automatic historical reprocessing is part of this change. The app's explicit
lyric recovery action is the recovery path for existing ready charts that have
no recording-aligned lyrics.

## Verification

`backend/tests/test_lyrics_jobs.py` covers immediately usable chords, a single
initial download, interrupted/reclaimed lyric phases, duplicate requests, stale
leases, recording and lyric changes, PCM mismatch, cancellation, unavailable and
failed recognition, required explicit retries, missing measured intervals,
successful publication with a lost response, and preservation of alias metadata.
The PCM identity test compares recovery directly with recognizer metadata.
`test_song_http.py` exercises authentication, request, claim, guarded attachment,
status, and completion through real local HTTP servers.

Tests use authored words, synthetic audio, and existing local model fixtures.
They do not make provider calls or prove acoustic accuracy for a particular song.
Real recording alignment and physical Spotify playback remain separate release
acceptance checks. These source changes do not deploy the API, worker, or app.
