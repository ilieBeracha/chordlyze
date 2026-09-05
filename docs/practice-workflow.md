# Practice workflow

## Navigation

Home, Search, Practice and Library are persistent tabs. Search, saved song sheets,
recorded practice and drills are accessible without Spotify login. Connecting
Spotify adds playlists and live following. Home offers a link back to the most
recently practiced song. The Practice tab offers chord-change drills and saved
recordings/results; Library labels analyzed charts as Saved songs.

## Practicing a passage

Open a prepared song sheet and choose **Choose section**, or long-press a lyric
or instrumental row and choose **Practice this passage**. Adjust the start and
end in the setup screen. The starting chord is shown even when it began before
the selected row. Select 50%, 75% or 100% pace and start the count-in. The
metronome's beat grid and displayed timeline follow that pace; recording stops
at the end of the range. After the result, return and choose **Practice this
section again** to keep the range and pace for another attempt.

Solo practice requires pausing Spotify. Changing pace never modifies Spotify
playback speed. Full-song practice at the original sounding key and 100% pace
can instead follow Spotify's current position. Pausing, seeking or changing
songs saves the partial recording without silently submitting it. Each take is
limited to 600 real seconds. Charts without beat data use a visual count-in.

## Key and capo

The song sheet's **Key & capo** settings distinguish sounding key from fingering.
Manual transposition shifts both the displayed chords and scoring reference.
Capo mode subtracts the suggested fret from the displayed shapes; the physical
capo restores the sounding pitch and does not add another scoring shift.
Settings are captured at record start, so retrying later uses the original take's
key, capo, start position and pace. Reports and drills name sounding chords.

`POST /practice_take` accepts two optional multipart fields:

- `transpose`: integer semitones, -12 through 12; default 0. The UI uses -6…6.
- `playback_rate`: finite song-seconds per performed second, 0.5 through 1;
  default 1.

For a take starting at song second `offset`, performed time `t` corresponds to
`offset + t * playback_rate`. Scoring transforms the reference into performed
seconds so timing errors and matching windows remain real seconds. Report
section boundaries and `covered_start`/`covered_end` remain original song times;
`scored_duration` measures performed seconds. Rich chord qualities are preserved;
legacy charts continue to disclose major/minor comparison.

Reports echo `transpose` and `playback_rate`. The client rejects mismatched values;
missing values are only compatible with original-key, original-pace takes.
Deploy the updated backend before distributing the updated iOS app. An older
backend cannot silently grade a transposed or slowed take as original practice:
the client keeps that recording for a later retry.

## Recording recovery

`Application Support/PracticeTakes/<UUID>/` contains `take.json` and `audio.m4a`.
Metadata is written atomically before recording starts; audio is recorded directly
into the persistent directory rather than a temporary URL. Completed takes survive
failed uploads and app restarts. Interrupted files with audio are surfaced for
listening or submission; abrupt process termination may leave an unplayable audio
container, which is reported when playback/scoring is attempted.

Successful scoring saves the report next to the audio and retains both until the
user deletes them. Each take can be listened to, submitted/retried, or deleted with
confirmation. Concurrent submission and deletion during submission are blocked.
Leaving the recording view stops and saves the partial take. Leaving during a
count-in cancels it. Uploads continue while the app remains active; if the process
ends, the recording remains available for manual retry. There is no automatic
background upload or cross-device synchronization.

## Verification

```sh
bash scripts/test_practice.sh
bash scripts/test_song_sheet.sh
bash scripts/test_drill.sh
cd backend
CHORDLYZE_REQUIRE_MODELS=1 PYTHONPATH=. .venv/bin/python -m pytest \
  tests/test_practice.py tests/test_practice_api.py tests/test_practice_http.py -q
```

The Swift tests exercise range/pace mapping, interrupted metadata recovery, failed
upload retention, retry after restart, report persistence, duplicate submissions,
deletion during submission, malformed metadata isolation, request serialization,
and rejection of incompatible server responses. Python tests cover shifted rich
chords, slow practice with real timing errors, silence, partial coverage, API
validation, and real multipart uploads through the installed recognition model.

Before release, visually check guest and connected navigation, passage selection,
capo/transposition, microphone permission refusal, count-in cancellation, a physical
instrument recording, interrupted playback, offline retry and report navigation.
Simulator capture was unavailable during this implementation due to a macOS
ScreenCaptureKit capture error; compile and automated checks do not replace these
visual and microphone checks.
