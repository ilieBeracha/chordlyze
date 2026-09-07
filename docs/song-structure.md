# Song map, bars and recurring sections

Analysis version 3 adds audio-derived downbeats and complete bars to the chord
chart. The map button in Sheet and Live opens a native song map. Select a
recurring section or an inclusive range of numbered bars, then jump to its start,
loop it during Spotify playback, or open recording setup for that exact passage.
Source-audio boundaries pass through the saved timing calibration when seeking
Spotify. Static sheets scroll to the selected passage.

## Detection contract

Beat This 1.1.0, `final0`, predicts beats and downbeats using its minimal
postprocessor (`dbn=False`). Consecutive downbeats delimit complete bars with
2–12 detected beats. A cycle with missing beat positions or an interval exceeding
1.8 times its shortest beat is excluded. Pickups and incomplete endings are not
extended into invented bars. Beat count does not establish a time-signature
denominator: six detected pulses need not mean 6/8.

Bar-aligned chroma and MFCC features identify acoustic changes across four-bar
neighborhoods. Ordered section profiles assign recurring letters (A, B, A).
These describe acoustic similarity, not semantic verse/chorus labels. Constant
features do not create arbitrary eight-bar sections. Gaps in detected bars
suppress section segmentation; selecting a range across a gap is disabled.
Short sections, changes without harmonic/timbral contrast, variations and
irregular phrasing can be missed. There is no section-accuracy claim yet.

The `tempo` payload retains `bpm` and `beats` and adds:

| Field | Meaning |
| --- | --- |
| `rhythm_version` | Timing schema version, currently 1 |
| `rhythm_model`, `structure_model` | Reproducible detector identifiers |
| `beat_positions` | Parallel to beats; 1 is a predicted downbeat, 0 means unknown |
| `bars` | Ordered `{start, end, beats}` in source-audio seconds |
| `sections` | `{start, end, start_bar, end_bar, label, occurrence}`; one-based inclusive bar indices |

The server validates timing before publication, including consistency between
beats, bars and sections. Invalid timing returns 422 and cannot replace the
previous chart. The client validates again before exposing the map. Legacy
beat-only charts retain the old four-beat phase fallback. New beat-only
detections never silently become inferred four-beat bars. Silent audio has no
grid. If the model returns fewer than two beats, librosa may supply beats alone;
missing model installation fails explicitly.

Practice count-in, accents and beat dots use the selected bar's detected beat
count and local interval. Slower practice scales that interval. Spotify loops
use remote seeks and can have a gap at each repeat; exact chart boundaries do
not make streaming playback sample-accurate.

## Installation and runtime

```sh
cd backend
bash scripts/setup_rhythm.sh
```

The installer creates `.venv-rhythm`, installs `requirements-rhythm.txt`, downloads
the official checkpoint once, verifies it and loads the model. Use
`CHORDLYZE_RHYTHM_DIR` for a different runtime directory and export it for both
the API and song worker. Docker installs this under `/opt/chordlyze/rhythm`.

Checkpoint SHA-256:
`8c328b45f59d8dd3dff219253ff6a8d6482be57d0133a29140e2febbf8eb8331`.

Inference is CPU-only in an isolated resident process with two Torch threads by
default, one inference at a time, a 180-second request/queue timeout, bounded
responses, finite timestamp checks and process cleanup/restart after failures.
Loading performs no network access and verifies the checkpoint hash. Feature
extraction processes one bar at a time, avoiding whole-recording spectra.
The worker warms the model at startup and closes it on shutdown; API use is lazy.

Install and deploy the matching backend and song worker before distributing iOS.
Analysis version 3 upgrades old charts on request through the existing cache
version mechanism. No library reset or bulk reanalysis is needed.

Version 2 charts use the same chord model and remain playable while their
optional rhythm metadata is stale. `GET /song/{id}` must keep returning their
chords, lyrics and ready state, including during a queued or failed upgrade.
Only an explicit `POST /song/request` queues an upgrade; an old finished job
can be replaced, while queued/running upgrades are deduplicated. Preview charts
and unsupported model revisions still cannot become complete song sheets.

The initial version 3 rollout incorrectly required the latest analysis version
for song visibility, hiding 120 of 121 stored charts. Compatibility regressions
now cover the HTTP song response, lyrics/calibration preservation, ISRC aliases,
upgrade deduplication/failure and unsupported-chart rejection. The fix passed
339 backend tests with 17 expected failures before release.

The compatibility fix is deployed as
`2026-09-07-chart-compatibility-270191c3d736`. Production verification confirmed
all 121 charts visible and ready, with unchanged chord data, an online worker
and the same library generation. See the
[restoration record](audits/2026-09-07-chart-compatibility-deployment.json).

The API and song worker were deployed to Fly on 2026-09-07 as release 53,
`2026-09-07-song-structure-v3-858a81574562`. Production health reports analysis
version 3 and an online worker; the existing library generation was preserved.
A temporary 16-second audio fixture on the deployed worker returned 32 beats,
15 complete bars and one section, passing the publication timing validator.
See the [deployment record](audits/2026-09-07-song-structure-deployment.json).
This backend deployment does not submit the iOS build to TestFlight.

## Measured downbeat improvement

All 60 GuitarSet microphone comp takes for players 04/05 were scored with
one-to-one downbeat matching within 70 ms over their full timelines:

| Detector | Precision | Recall | F1 |
| --- | ---: | ---: | ---: |
| Previous librosa beats + four-beat chord-phase vote | 43.64% | 45.23% | 44.42% |
| Beat This final0 | 92.03% | 98.41% | 95.11% |

The new detector matched 866 of 880 reference downbeats and emitted 941.
The legacy comparison receives annotated chord changes, an optimistic advantage
over recognized chords. The final run analyzed 1,828 seconds of audio in 39.43
seconds on the development Mac. Source and fixture hashes and per-take counts
are in [the report](audits/2026-09-07-song-structure.json). An earlier madmom
candidate scored 35.88% F1 and was rejected; its
[report](audits/2026-09-07-song-structure-madmom.json) is retained for traceability.

This is a narrow guitar benchmark, not accuracy on arbitrary commercial mixes.
Thirty takes informed model selection before the full run; this is not an
untouched held-out evaluation. Pretraining overlap is not established. The
evaluation has no section-boundary ground truth, so downbeat F1 does not validate
the A/B section detector.

```sh
cd backend
PYTHONPATH=. .venv/bin/python scripts/benchmark_song_structure.py \
  --dataset /path/to/guitarset --out ../docs/audits/2026-09-07-song-structure.json
PYTHONPATH=. .venv/bin/python scripts/check_rhythm_capacity.py --seconds 1200
CHORDLYZE_REQUIRE_MODELS=1 PYTHONPATH=. .venv/bin/python -m pytest tests/ -q
cd ..
bash scripts/test_song_sheet.sh
bash scripts/test_practice.sh
```

The 1,200-second synthetic capacity run completed in 20.11 seconds with 639 MB
main-process peak RSS and 1,237 MB rhythm-process peak RSS on macOS. These are
separate maxima, not a combined measurement with concurrent chord/lyrics
inference or a guarantee for the production VM.

The full Linux amd64 Docker image built and loaded both verified models. An
offline container with two CPUs, a 4 GiB memory limit and no swap processed the
same 20-minute input with the chord model resident in 147.39 seconds. Combined
container peak memory was 2.49 GB (2.32 GiB). This verifies model co-residency;
concurrent chord/lyrics inference was not exercised. Raw measurements are in the
[capacity report](audits/2026-09-07-song-structure-capacity.json).

```sh
docker build --platform linux/amd64 -t chordlyze-backend:song-structure backend
docker run --rm --platform linux/amd64 --network none \
  --memory 4g --memory-swap 4g --cpus 2 \
  -e PYTHONPATH=/app -e NUMBA_CACHE_DIR=/tmp/chordlyze-numba \
  -v "$PWD/backend/scripts/check_rhythm_capacity.py:/tmp/check.py:ro" \
  chordlyze-backend:song-structure python /tmp/check.py --seconds 1200 --with-chords
```

Validation: 327 backend tests passed, 17 expected failures; 1,114 Swift song-sheet
checks passed; practice persistence, feedback and report-contract suites passed;
iOS Simulator Debug build passed. Tests cover pickups, partial endings, variable
meter, malformed publications, exact ranges, calibration, recurring sections,
constant/repeated harmony, audio feature extraction, process reuse, crash
recovery and timeout cleanup.

The Simulator fixture verified section selection, correct 12–24 second recording
setup and repeated 0–12 second playback. Launch Debug with
`--song-sheet-preview --song-map-preview`, adding
`--song-sheet-preview-playing` for loops or `--song-map-large-type` for
accessibility text. The final accessibility-size visual check was interrupted
by a locked Mac; real Spotify timing still needs a physical-device check.

Upstream references: [Beat This source and model instructions](https://github.com/CPJKU/beat_this),
[GuitarSet dataset](https://guitarset.weebly.com/).
