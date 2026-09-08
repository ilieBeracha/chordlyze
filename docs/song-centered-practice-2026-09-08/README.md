# Song-centered practice

The separate Practice landing page repeated song selection and mixed unrelated
instrument tools with saved takes. Practice now belongs to the selected song.

## Destinations

The latest compact sheet replaces the stacked action rows with a header Play
icon and a labeled **Song options (•••)** menu. Practice, key/capo, save,
recordings and the song map are in that menu. Optional chord diagrams now
scroll with the sheet; their existing visibility preference is preserved.
The Debug-only Sheet/Live/Practice selector requires
`--song-sheet-preview-controls` and no longer appears by default.

[Compact sheet](compact-sheet.png) · [Song options](compact-menu.png).
The simulator build passed and both layouts were visually inspected. The menu
rendered its expected actions; automated activation of individual native menu
items was blocked by the computer-use tool returning invalid element IDs.
The destination code was reviewed, but those menu tap-throughs remain unverified.

| Task | Entry |
| --- | --- |
| Find music | Home or Search |
| Play without a take | Green Play along action on its prepared sheet |
| Practice a song | Separate Practice action on its prepared sheet |
| Practice a passage | Existing row and song-map actions |
| Play the last recorded song again | Home → Continue practicing → Practice again |
| Recognize a chord or drill a change | Home → Instrument tools |
| Listen, score, retry or delete a take | Library → Recordings |
| Find a particular song's takes | Song sheet → Recordings |

The bottom tabs are Home, Search and Library. Library retains its song search,
filters, sorting and Spotify collections, and adds a Songs/Recordings selector.
Both recording lists observe the same local store. Track ID filtering keeps
different songs with identical titles separate. No audio files are moved,
duplicated or uploaded by browsing these screens.

Home's Practice again opens the song's setup after its chart loads. It does not
restore the previous recording's range or pace, or start audio automatically.
Unavailable charts retain their existing retry/analysis controls. Local song
recordings remain accessible even when the chart is unavailable.

## Verification

- iOS simulator Debug build succeeded.
- `bash scripts/test_practice.sh` passed: take persistence/recovery/retry/deletion,
  34 feedback checks, 40 audio-to-feedback checks, report contract and metronome
  lifecycle. Added title/artist search, track identity, identical-title isolation
  and deletion/filter consistency coverage.
- `bash scripts/test_song_sheet.sh`: 1,222/1,222 checks passed.
- `bash scripts/test_music_collection.sh`: 28/28 checks passed.
- Simulator navigation checked from Home to Instrument tools, Library to saved
  take, saved take to song sheet, song sheet to song recordings, and prepared
  song to Practice setup. A chart error did not hide its recordings.
- Normal recordings and accessibility-size empty layouts captured and inspected.
- `git diff --check` passed.

Screenshots: [Home](home.png), [Instrument tools](instrument-tools.png),
[Library recordings](recordings.png), [empty/accessibility size](recordings-empty-large.png),
[song entry](song-entry.png). The Sheet/Live/Practice switch in the song-entry
screenshot is a Debug fixture control, not the main navigation.

## Preview

Follow-up: [Play along](play-along.png) starts or resumes Spotify directly on the
sheet without entering Practice, activating the microphone or saving a take.
Song-sheet/playback tests now pass 1,225/1,225 checks, including paused resume,
no restart of the same playing song, and start-at-zero for a different song.
The Debug build and the offline simulator tap-through passed; live-follow
advanced while the existing recording count stayed unchanged. Phone Spotify
playback was not exercised by this simulator check.

Launch Debug with `--music-preview`. Add `--music-recordings` for recordings,
`--practice-empty` for an empty take store, or `--music-large-type` for
accessibility text sizes. `--song-sheet-preview` opens the authored song fixture
for the Practice action. The music preview uses isolated sample takes. No
microphone or Spotify playback starts just by opening these destinations.

Installed locally on the review simulator. No TestFlight upload or backend
deployment was made. Detection DSP and server scoring are unchanged by this
navigation work. See [practice workflow](../practice-workflow.md) for recording,
timing, audio and recovery behavior.
