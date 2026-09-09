# Practice workflow

## Navigation

Home, Search and Library are the three persistent tabs. Practice starts from the
**Song options (•••) → Practice** action on a prepared song sheet, or from a selected passage.
There is no separate Practice tab or song-selection landing page.

Home's **Instrument tools** opens standalone chord recognition and chord-change
drills. When a saved take exists, **Continue practicing → Practice again** opens
setup for its song. It does not automatically start playback or the microphone,
or restore the previous take's range and pace. An unavailable chart offers its
existing loading, analysis and retry controls.

Library separates **Songs** and **Recordings**. Recordings can be searched by
song title or artist; each song sheet also links to its own recordings, even
when its chart is unavailable. These are views of the same local take store,
filtered by track ID rather than title. Existing files, playback, scoring retry
and deletion are preserved without migration or duplication. The main account
navigation retains its existing sign-in requirements; standalone chord
recognition remains accessible from the login screen.

## Playing along without a take

On a prepared song sheet, the green **Play** icon starts Spotify and follows the chords
in place. It creates no practice session, recording or score, never requests
microphone access and does not require headphones. A different song starts at
0:00; the same paused song resumes at its reported position; an already playing
song is left uninterrupted. Spotify keeps its original tempo and key.

The action uses the existing phone-device discovery and confirmed-start flow.
Pending commands disable repeated taps. Device failures offer the existing
Spotify recovery controls, and other failures offer opening the song in Spotify.
The music-note button beside the running timeline opens Spotify's playback
controls. The header's green waveform also opens Spotify controls while playing.
Leaving the sheet does not stop the music. **Song options (•••) → Practice**
remains a separate action for recording and feedback.

The compact header contains back, song information, Play and Song options.
Practice, Key & capo, Save song, Recordings and Song map are labeled menu items.
The same menu shows or hides chord diagrams; the existing visibility preference
is retained. Visible diagrams scroll with the lyrics rather than occupying a
fixed area above them. Song recordings remain reachable when a chart fails.

## Practicing a passage

Open a prepared song sheet and choose **Choose section**, or long-press a lyric
or instrumental row and choose **Practice this passage**. Adjust the start and
end in the setup screen. The starting chord is shown even when it began before
the selected row. Select 50%, 75% or 100% pace and start the count-in. The
metronome's beat grid and displayed timeline follow that pace; recording stops
at the end of the range. After the result, return and choose **Practice this
section again** to keep the range and pace for another attempt.

Charts with detected bars also have a **Song map** button. Select a recurring
section or a numbered bar range and choose **Record selected bars** to open
setup with those boundaries. See [song structure](song-structure.md).

## Live following and connection recovery

A temporary song-status connection failure keeps an already loaded full chart
usable, including chord diagrams, Live following and passage selection. The sheet
offers **Reconnect** and continues retrying status reads without requesting new
analysis. Transposition remains in place. This preserves the chart in
memory; it does not add offline music playback or persist sheets across app
restarts. Explicit server resets still clear the reference, and unknown-offset
previews cannot become practice charts during an outage.

Lyrics attached to the analyzed recording take priority over catalog lookups,
including words transcribed by the worker. Refreshing or reopening the sheet
does not replace them with estimated timing. A replacement recording (identified
by its audio hash), or a library reset, invalidates the old recording's word times
and allows fresh lyrics to load.

Live follows playback continuously. Tap a line or use the song map to jump to
a passage; select **Record selected bars** to practice it. Automatic repeating
and A–B loop controls were removed on September 8, 2026.

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

Spotify's reported clock is an estimate of playback position, not a measurement of when sound reaches the player's ears. Matching the desktop clock does not establish headphone timing. **Key & capo → Calibrate by ear** fits the chart to the audible Spotify recording. Practice captures that map's starting chart position and scale for the whole take, including saved retries and backend scoring; changing calibration later does not reinterpret an old take.

The sounding chord and scoring target use the same measured event boundaries and song calibration. The former global **Show chords ahead** preference is no longer used, so a saved display offset cannot make green activation early. Lyrics remain steadily readable; they do not pulse or highlight word by word.

Playing along with Spotify is the one primary action. **Practice slower,
without the song** reveals the pace picker (50% or 75%) and the metronome
take; **Play along with the song instead** returns. The metronome take
requires pausing Spotify. New charts use audio-derived beats and downbeats.
Legacy beat-only charts retain the four-beat chord-phase fallback. Chord
boundaries within a third of a local beat are drawn on that beat on every
surface; scoring still uses the recognized boundaries. The take begins on
the downbeat at or before the chosen start. Count-in length, accents and dots
follow the selected bar's detected beat count and local spacing, with a
four-click fallback where meter is unknown. Changing pace scales the clicks and
never modifies Spotify playback speed. Each take is limited to 600 real
seconds. Charts without beat data use a visual count-in and no click.

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
the vocabulary, 250 ms of consecutive evidence), so the detector's sample time is the frame's
position in the file: feedback and the backend score the same timeline.

`PracticeFeedback` judges each chart chord from the first accepted chord timestamp in captured audio. The detector retains this timestamp across coalesced UI updates, so a busy main thread cannot move the reported strum later. Each snapshot carries an estimated delay from the sample rate, analysis window and confirmation duration (about 0.53 seconds at 44.1 kHz). This is not a measured device calibration. It is applied in real seconds before chart-rate conversion. Live timing labels therefore say "estimated ... vs chart" or "near chart change" rather than asserting that the player was late. A chord already sounding when the take begins is held, not a missed earlier transition.

Live targets use `SheetModel.events`, so chips and verdicts share the same measured boundaries without beat snapping. A sustained chord is credited only after it is heard inside the next target, never in advance. The live panel shows the target, confirmed heard chord, microphone level, provisional/quiet status, and the last check. With a capo, the target is labeled Sounding. Detection failures are reported while the recording continues.

Matching uses pitch-class sets after transposition. Silence and uncertain detections remain unjudged in live feedback; confirmed wrong chords name what was heard. Matching chords can upgrade an earlier wrong verdict. Actual detector latency still depends on evidence quality and device input; no software constant establishes the player's acoustic timing.

The server independently recognizes the recorded take. Scoring version 3 reports **chord changes matched** separately from **time matching chart**. A correct change can be early or late; its match does not erase its timing error. Server matching uses symmetric three-second windows, bounded by neighboring reference intervals and take coverage, with one-to-one detected-onset assignment. This avoids the previous asymmetric early/late selection bias. The original duration-overlap `accuracy`, per-chord and section values remain unchanged and explicitly labeled as time matching the chart.

When at least three matched changes span eight seconds, cover at least 75% of expected transitions, and all lie within 0.15 seconds of their median, an offset of 0.1–1.5 seconds is reported as a **consistent offset**. It is descriptive: device/recording sync and consistently early/late playing cannot be distinguished from chord detections alone. No automatic shift is subtracted and no original accuracy is inflated. Old saved reports retain the original overlap metric, with corrected labeling; re-score a saved recording to obtain the new diagnostics.

## Key and capo

The song sheet's **Key & capo** settings distinguish sounding key from fingering.
Manual transposition shifts both the displayed chords and scoring reference.
Capo mode subtracts the suggested fret from the displayed shapes; the physical
capo restores the sounding pitch and does not add another scoring shift.
Settings are captured at record start, so retrying later uses the original take's
key, capo, start position and pace. Reports and drills name sounding chords.

`POST /practice_take` accepts these optional multipart fields:

- `transpose`: integer semitones, -12 through 12; default 0. The UI uses -6…6.
- `playback_rate`: finite song-seconds per performed second, 0.5 through 1;
  default 1.
- `timing_scale`: captured chart-to-playback calibration scale, 0.9 through 1.1; default 1.

For a take starting at song second `offset`, performed time `t` corresponds to
`offset + t * playback_rate / timing_scale`. Scoring transforms the reference into performed
seconds so timing errors and matching windows remain real seconds. Report
section boundaries and `covered_start`/`covered_end` remain original song times;
`scored_duration` measures performed seconds. Rich chord qualities are preserved;
legacy charts continue to disclose major/minor comparison.

Reports echo `transpose`, `playback_rate` and `timing_scale`. The client rejects mismatched values;
missing values are only compatible with original-key, original-pace, identity-scale takes.
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

## Correcting the reference chart

See [Personal chord corrections](chord-corrections.md) for editing individual
occurrences, restoring the original and how corrections reach practice scoring.
New takes retain their chart revision so a later correction cannot silently change
what an existing recording is graded against.
