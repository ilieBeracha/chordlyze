# Chordlyze

SwiftUI iOS app for song chord charts, playback and instrument practice.

## Recognition and scoring

- **Full-song charts and recorded practice:** one shared ISMIR2019 five-model ensemble and HMM decoder, supporting sevenths, suspended, diminished and augmented chords, selected extensions, and triad inversions.
- **iTunes previews:** madmom's major/minor recognizer. Previews have an unknown position in the song and cannot be used as a practice reference. The ingest worker upgrades them to full-song charts.
- **Live drills:** on-device harmonic note analysis, competing chord hypotheses, explicit uncertainty and sample-timed change counting. Audio work runs in a bounded background queue.
- **Practice scoring:** exact root/quality against rich charts, flexible bass voicing, measured recording duration, explicit silence, and signed chord-change timing. Legacy charts are scored at their major/minor resolution, disclosed in the report.

Model output is an estimate. The [audit](docs/audits/2026-09-04-chord-detection.md) documents measured limitations. The [recognition guide](docs/chord-recognition.md) covers architecture, scoring, cache upgrades and validation.

The [live drill guide](docs/live-drill-detection.md) includes a reproducible 112-take GuitarSet benchmark. On the held-out sustained-chord intervals, accepted-match precision rose from 40.0% to 96.8%, while target-section recall fell from 69.3% to 59.4%. The detector rejects more uncertain audio; it still misses short and incomplete strums.

## Backend setup

Requires Python 3.11, `ffmpeg`, Git and a C/C++ compiler on macOS or Linux. The model has a separate Python environment because the research code and API have different dependencies.

```bash
cd backend
python3.11 -m venv .venv
.venv/bin/python -m pip install cython numpy
.venv/bin/python -m pip install -r requirements.txt
bash scripts/setup_ismir.sh
PYTHONPATH=. .venv/bin/uvicorn chordlyze_backend.main:app --port 8787
```

`setup_ismir.sh` pins the upstream revision and dependencies, checks all five checkpoint hashes and the dictionary, and loads the model. Set `CHORDLYZE_ISMIR_DIR` to use another installation directory; export the same setting when starting the API or ingest worker.

```bash
# Release checks: missing model weights are a failure, never a silent skip.
CHORDLYZE_REQUIRE_MODELS=1 PYTHONPATH=. .venv/bin/python -m pytest tests/ -q

# Upgrade previews and stale analyses against a local API.
CHORDLYZE_API_URL=http://127.0.0.1:8787 PYTHONPATH=. .venv/bin/python ingest_worker.py --jobs 3
```

The ingest worker downloads matching full-track audio with yt-dlp and submits analyzed chords. Its default API is the deployed Fly service; set `CHORDLYZE_API_URL` explicitly for local work. Spotify's API supplies metadata and playback control, not downloadable audio or chord labels.

Downloads overlap in at most three jobs by default, while the resident model serializes inference. A shared throttle limits iTunes lookups, and each job owns its temporary audio. Restarting a pass skips entries that are already current; the final summary distinguishes updates, skips and failures.

## iOS app

The app sources are in `Chordlyze/` and the Xcode project is at the repository root.

1. Configure Spotify's client ID and the backend URL in `Chordlyze/ChordlyzeApp.swift`. Register the redirect URI `chordlyze://callback` for the Spotify application.
2. Open `Chordlyze.xcodeproj`. Run `xcodegen generate` after changing `project.yml` or adding app source files.
3. For a physical device, use the Mac's LAN IP as the local backend URL and start Uvicorn with `--host 0.0.0.0`.

```bash
xcodebuild -project Chordlyze.xcodeproj -scheme Chordlyze \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/chordlyze-build CODE_SIGNING_ALLOWED=NO build

swiftc Chordlyze/Chord.swift Chordlyze/BackendClient.swift \
  tests/PracticeReportContract.swift -o /tmp/chordlyze-report-test
/tmp/chordlyze-report-test

bash scripts/test_drill.sh
```

The repository is connected to Xcode Cloud's `Default` workflow. After merging into `main`, verify its iOS build and archive checks, then check the processed build in App Store Connect → TestFlight. Availability depends on the workflow's distribution settings and Apple's processing. Local distribution is also possible by archiving and distributing from Xcode with the configured Apple Developer team. The backend must remain reachable.

## Local container

```bash
docker build -t chordlyze-backend backend
docker run --rm -p 8787:8080 -v chordlyze-cache:/data chordlyze-backend
```

The image includes both recognizers. Recognition loads lazily and the rich worker stays resident across requests. Cache files are saved by track ID and ISRC, with normalized PCM hashes, model revisions and analysis versions for traceability. Old entries remain readable and are queued for upgrade.
