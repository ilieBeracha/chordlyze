# Instrument isolation

Implemented locally on September 7, 2026. This feature and the preceding practice-screen redesign have **not been released to TestFlight**. The last previously released phone build was 0.5.0 (89).

Open an analyzed song → **Instrument isolation** → choose **Guitar, Bass, Drums, Vocals, or Piano** → **Prepare**. Preparation continues on the server if the screen closes; reopening and preparing the same instrument finds the existing job or cached pair.

The player offers **Full mix**, **Solo**, and **Without**, a seek bar, 0.5× / 0.75× / 1× speed, and **Follow chords**. Mix switches only change volumes. Chord mode supports the existing A–B and row loops, with a separate loop selection so it cannot seek Spotify. The chord and loop clocks use the analyzed recording directly; Spotify calibration is intentionally not applied. Audio stays in its original key. Backgrounding, audio interruptions, and unplugging the output pause playback. Closing the screen releases its audio session.

## Architecture

- `backend/chordlyze_backend/stems.py`: authenticated API, JSON job queue, leases, bounded artifact cache, upload validation.
- `backend/stem_worker.py`: dedicated queue process, source retrieval, exact recording verification, heartbeat, inference subprocess, uploads.
- `backend/chordlyze_backend/analysis/stem_worker.py`: isolated Demucs runtime and encoding.
- `Chordlyze/StemPlayer.swift`: synchronized local players and verified download cache.
- `Chordlyze/Views/InstrumentIsolationView.swift`: preparation, recovery, player and chart UI.

The API and chord-analysis worker never load Demucs. `fly.toml` adds a dedicated `stems` process with one performance CPU / 4 GB memory; deploying this configuration creates an additional billable worker. Docker installs and prefetches the model in `/opt/chordlyze/stems` during image construction. No model download is needed for the first phone request.

### Audio identity and processing

The source is fetched through the existing audio-provider pipeline. When available, the previously analyzed video's identity is reused as the candidate. The worker decodes the source to mono 44.1 kHz PCM16, exactly as chord analysis does, and hashes the raw frames. A different SHA-256 fails with a reanalysis message before model execution. A version with a matching title/duration is not sufficient.

Runtime: Demucs 4.0.1, Torch/Torchaudio 2.5.1, NumPy 1.26.4, `htdemucs_6s`, official checkpoint `5c90dfd2-34c22ccb.th`. The installation verifies the six-source set. The official checkpoint filename carries the SHA-256 prefix verified by Torch on download.

Processing streams 20-second central windows with four seconds of surrounding context, using seven-second internal model segments. Adjacent predictions crossfade across four seconds. Only one window's predictions are resident; memory does not grow with song duration. The model predicts the selected part; backing audio is the original stereo mix minus that part. Both use one common gain, then identical 44.1 kHz stereo AAC / 256 kbps encoding with fast-start MP4 containers. Summing the two approximately reconstructs the source after lossy encoding.

This is approximate separation. The upstream model describes guitar and piano as experimental, with especially noticeable piano bleeding/artifacts. It cannot distinguish every guitar from another guitar. The original repository is archived, so the runtime is isolated and pinned. See the [official Demucs documentation](https://github.com/facebookresearch/demucs#demucs-music-source-separation). Synchronized player starts use Apple's [device-time playback API](https://developer.apple.com/documentation/avfaudio/avaudioplayer/play(attime:)).

### Queue and storage bounds

- Maximum song duration: 20 minutes.
- Maximum active jobs: 12 globally; three per requesting account.
- Deduplication: track + recording fingerprint + instrument + model revision.
- Lease: 180 seconds, heartbeat every 15 seconds; abandon processing after prolonged heartbeat failure; maximum three worker attempts.
- Inference timeout: one hour. Source retrieval and encoding have separate timeouts.
- Publication requires both validated AAC files, matching durations (within 25 ms), and the current recording fingerprint.
- Each file is capped at 48 MiB. Server audio cache: 384 MiB, least-recently-used eviction, seven-day expiry. Missing files become recoverable expired jobs.
- Phone cache: current pair plus two recent pairs, each at most 96 MiB. File size and SHA-256 are checked before playback. Failed/cancelled downloads are removed.
- Downloads require the same Spotify account authorization as other app APIs. Worker routes require `CHORDLYZE_WORKER_TOKEN` and mutations require a current lease. Public statuses omit source URLs, account hashes, and leases.
- Library reset invalidates jobs immediately; the next queue maintenance pass removes orphaned audio directories.

Prepared audio is managed independently of Spotify playback. The app does not obtain PCM from the Spotify SDK. This implementation uses the project's existing recording source pipeline; it does not establish catalog licensing or change that pipeline's provenance.

## Local operation

From the repository root:

```bash
bash backend/scripts/setup_stems.sh
```

Run the API normally. In a second terminal, from `backend`, run:

```bash
.venv/bin/python stem_worker.py
```

The worker reads the existing `.env` through python-dotenv. It needs `CHORDLYZE_API_URL`, `CHORDLYZE_WORKER_TOKEN`, and the normal recording-provider configuration. `CHORDLYZE_STEMS_DIR` optionally overrides the default `backend/.stems` runtime. Do not install the stems requirements into the main analysis virtual environment.

Health: `/health` includes `stem_worker_online`. A false value means queued requests are waiting for a worker. For shutdown/recovery, stop the worker; after lease expiry the next worker claims interrupted work. Retrying a failed/expired preparation creates a new job while pending and ready requests deduplicate.

## Verification

Executed successfully:

- 13 isolation API/worker regression tests plus 17 existing song-job tests: **30 passed**. Covers auth, deduplication, quota, stale lease, reset, changed recording, partial publication, malformed/oversized uploads, duration, eviction, and missing source identity.
- Native audio-player tests: reject mismatched durations, paused/live mix switching, rate changes, seek clamping, scheduled start, actual playback, pause, interruption handling, cleanup.
- Existing song-sheet/playback regression suite: **1,201 checks passed**.
- Real Demucs execution on a 24-second authored synthetic mixture crossing a processing boundary: equal output durations; recombined audio correlation **0.999593**, SNR **30.89 dB**. This checks execution and alignment, not perceptual quality on real songs. See `model-smoke-test.json`.
- Debug iPhone simulator and unsigned Release iPhone builds.
- Simulator UI: preparation, playback continuing into Follow chords, seek controls and large accessibility text. Screenshots use an explicit Debug-only authored audio fixture and perform no network requests.

Reproduce:

```bash
cd backend
.venv/bin/python -m pytest tests/test_stems.py tests/test_song_jobs.py -q
.stems/venv/bin/python scripts/test_stem_model.py ../docs/instrument-isolation/model-smoke-test.json
cd ..
bash scripts/test_stems.sh
bash scripts/test_song_sheet.sh
```

The native playback test needs access to a functioning Mac audio output and plays a quiet tone for less than a second. Simulator preview launch arguments: `--song-sheet-preview --isolation-preview`, optionally `--song-map-large-type`.

Cloud image deployment, live provider-to-phone verification, and TestFlight distribution remain release steps. The added worker has not been provisioned, and no new infrastructure charges were incurred by this local implementation.
