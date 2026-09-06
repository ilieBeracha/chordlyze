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

## Playing from Spotify

**Play from Spotify and record** lists the account's Spotify devices and
starts the song on the phone (`PUT /me/player/play` with the smartphone's
`device_id`, Premium required) up to three seconds before the chosen range so
the player hears the lead-in, then waits until Spotify itself reports the
track playing near that position. It never plays on Spotify's "active"
device: a laptop across the room can be active while the phone, and the
headphones, hear nothing. No phone in the list means the Spotify app is not
open on it, and the message says so; a list with only other devices names
them. 403 explains that Premium is needed. The app never assumes playback it
did not confirm. The count-in and the recording bar name the device. The take begins at
the position Spotify reports, and while recording, the sheet follows Spotify's
reported position (polled every two seconds, extrapolated between polls) so the
chart and the audio share one clock. During a connection loss the sheet falls
back to the take's own clock. Pausing, seeking or changing songs saves the
partial recording without silently submitting it. Spotify playback needs 100%
pace and the original key; the metronome path is the only way to slow down.

Measured against the Spotify desktop client's own clock, the app's playhead
agrees within about 0.1 s, so a chord that highlights late is a chart matter,
not a polling one: recognized boundaries land slightly after the change and
players read ahead of the beat. **Key & capo** therefore has a global
"Show chords ahead" lead (`chordLead` in UserDefaults, default 0.3 s) applied
to the Live and Practice display only; the take stays anchored to Spotify's
reported position so scoring remains in real song time.

Charts are analyzed from a matched YouTube recording, not the Spotify master.
When the recording's length differs from the Spotify track by more than a
second, the sheet, Live and Practice show an edition warning, and **Key &
capo** offers a timing offset (±5 s in 0.25 s steps) that Live and Practice add
to Spotify's position before reading the chart. Like transpose and capo, the
offset lives on the in-memory song document.

**Record with metronome** requires pausing Spotify. Changing pace never
modifies Spotify playback speed. Each take is limited to 600 real seconds.
Charts without beat data use a visual count-in.

## Headphones and live feedback

Spotify practice requires headphones: on the speaker the microphone records
the song, and both live feedback and scoring would grade Spotify's playing.
`TakeRecorder.recordingRoute()` first configures and activates the audio
session exactly as the take will use it (play-and-record, Bluetooth A2DP
allowed), then reads the route: an inactive session, or one left in the
drill's record-only category, reports outputs that have nothing to do with
where a take would play, which is how connected AirPods once read as
"speaker". Any output other than the built-in speaker or earpiece passes; the
failure message names the current output. A route change that removes the
headphones mid-take saves the partial recording without scoring. The
simulator has no real routes and passes the check.

The microphone is opened (`TakeRecorder.prime()`) before Spotify is asked to
play: starting input later, with Bluetooth headphones, makes iOS interrupt
other audio for about a second exactly as the take begins, and Spotify
resumes on its own. A pause Spotify reports is tolerated for three seconds
before it ends the take; a track change ends it at once.

The take is captured through one `AVAudioEngine` tap. Each buffer is written to
the .m4a and handed to `ChordDrillDetector` in its general form (any chord in
the vocabulary, same 70 ms dwell), so the detector's sample time is the frame's
position in the file: feedback and the backend score the same timeline.

`PracticeFeedback` judges each chart chord in the take from detector strums
(the moment the detector starts reporting a chord it was not reporting). A
strum's chart time is its take time through the plan, minus 0.35 s of detector
latency (window plus dwell; at slower paces this is slightly overcorrected).
Matching is by pitch-class set after transposition, so voicing, bass note and
spelling do not matter. Verdicts: **hit** with an offset (within 0.25 s is "on
time"; a strum up to 0.5 s before a change belongs to the coming chord),
**wrong** naming what was heard, upgraded to a late hit if the right chord
follows, and **held** for a repeated chord after a hit. A chord the detector
never accepted stays unjudged: the detector is conservative and its silence is
not evidence. During the take, chips show a corner dot (green on time, amber
early/late, red wrong) and the bottom bar names the latest verdict with a
running hit count. The saved-take screen repeats the totals; backend scoring
remains the full result.

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
bash scripts/test_practice.sh   # takes, report contract, live feedback
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
`--song-sheet-preview` Practice mode uses a fake Spotify device that starts
wherever it is told, so the play-confirm-record flow can be checked offline.
Sync feel against real Spotify audio, Premium and no-device errors need a
physical device with the Spotify app.
