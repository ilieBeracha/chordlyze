# Chord recognition, version 2

This milestone connects recorded practice to the richer recognizer already used for whole-song charts, fixes scoring errors, and makes model upgrades traceable. Backend audio regressions use synthetic voicings; the separate [live drill milestone](live-drill-detection.md) now includes a real-guitar benchmark. The [initial audit](audits/2026-09-04-chord-detection.md) separates measured results from proposed later work.

## Runtime

`analysis/engine.py` is the common audio boundary for API practice, previews and ingest. ffmpeg decodes to mono 44.1 kHz signed 16-bit PCM. Duration comes from the decoded sample count; SHA-256 covers those PCM bytes. Input filenames and container metadata do not affect the hash. Segments must have finite, ordered, nonoverlapping intervals and valid chord labels. Decoder frame padding is clipped to the actual recording end.

The rich recognizer runs in a resident subprocess in its own virtual environment. It loads the five ISMIR checkpoints once, averages their probability heads and uses the upstream HMM with its submission dictionary and transition penalty of 30. The upstream CQT performs its own 22.05 kHz resampling, tuning estimation and 512-sample hop. Access is serialized so requests cannot corrupt shared inference state. A failed or timed-out process is closed and the next request starts a new one.

The model revision, dependency lock and checkpoint/dictionary hashes are pinned. Missing or mismatched assets prevent startup; the upstream loader's random-weight fallback is never accepted. A missing rich recognizer returns HTTP 503 for practice. There is no automatic switch to major/minor grading for a rich reference.

`CHORDLYZE_ISMIR_DIR` locates the checkout; `CHORDLYZE_TORCH_THREADS` defaults to 2. The private worker accepts only locally supplied decoded audio paths. `scripts/setup_ismir.sh` installs and verifies it on macOS or Linux. The Docker image uses CPU PyTorch wheels.

Practice limits are 64 MiB uploaded audio and 600 seconds decoded duration, matching the app's ten-minute take limit. A 50 ms tolerance accepts AAC final-frame padding without rejecting recordings made exactly at that limit; scoring and hashing still use the actual decoded samples. Decoding has a 120-second deadline. Worker lock acquisition and individual worker responses each have a 600-second deadline; a saturated instance can therefore exceed a client's timeout. Run a single Uvicorn worker per instance to avoid loading several ensembles. Capacity checks should include preview and practice models resident together. The Fly configuration allocates 4 GB: a ten-minute take exhausted a 2 GB container with swap disabled. This configuration change takes effect on deployment and increases the instance's memory allocation.

## Scoring contract

`scoring_version: 2` uses the following rules:

1. Take second zero corresponds to song second `offset`. The decoded duration defines the take span, including leading/trailing silence and gaps in recognition.
2. Accuracy is matching time divided by reference chord time within the take. A take from song seconds 2–6 inside a chord lasting 0–8 is assessed over four seconds. Reference rests are unassessed; silence while a reference chord should sound is a miss.
3. Rich charts use `comparison: "root_quality"`. Enharmonic spellings are canonicalized, and slash bass is ignored as a voicing choice. Major and major seventh remain different chords.
4. Legacy madmom references use `comparison: "major_minor"`, reducing recognized major/minor-family extensions to the reference resolution. The app displays this limit. Unsupported reference qualities produce a 422 error instead of an impossible-to-pass score.
5. Each reference change can match one detected onset, in order. The onset must lie between 0.5 seconds early and 3 seconds late, remain within the adjacent reference intervals, and overlap the target chord. An old held chord or a later repetition cannot rescue a missed change. Rests, gaps and bass-only changes do not create assessed transitions.
6. Timing is separate from chord accuracy. `avg_offset` is signed (negative = early); `avg_timing_error` is mean absolute error. `avg_early` and backward-compatible `avg_lag` contain nonnegative early and late components. Missed transitions are counted separately and excluded from these means. With no matched transitions, timing fields are null.
7. Four section scores divide the covered recording span equally. Sections containing only reference rests have null accuracy. Timing display uses absolute error so opposing early/late changes cannot cancel into an apparently perfect result.

Reports carry `model`, `model_revision`, `analysis_version`, `audio_sha256`, `audio_duration`, `scoring_version`, `comparison`, and reference analysis/model revisions. Older iOS clients can continue reading the existing score fields; the updated client can still decode old reports.

## Cache and ingest upgrades

`analysis/provenance.py` is the shared source of model revisions, vocabulary capabilities and analysis compatibility.

- Bump `ANALYSIS_VERSION` when decoding, segmentation or downstream analysis semantics change. Change `MODEL_REVISIONS` when weights, feature settings, decoder settings or vocabulary change. Scoring-only changes use `SCORING_VERSION`.
- Version 2 submissions must include the matching model revision, normalized PCM hash and measured duration. Legacy submissions remain readable but are returned with `analysis_stale: true`.
- Reads expose staleness without deleting cached charts. `/analyze_track` refreshes stale previews. The ingest worker queues previews, older models and older revisions of the same rich model.
- A full-song chart outranks a preview; a richer vocabulary outranks major/minor. At equal coverage/model rank, a current revision outranks a stale one. Old workers receive 409 when they try to overwrite a better result.
- Writes use atomic file replacement. The local lock protects comparisons and writes within one API process. The cache is not a distributed database; use one API process per shared cache directory.
- ISRC aliases retain provenance. Existing full-song charts can still be used while reanalysis is pending; their original revision is included in each practice report.

Deploy the backend before running the updated ingest worker, then run an ingest pass to upgrade existing entries. Merely replacing the server does not redownload whole songs. Use `CHORDLYZE_API_URL` to choose the target; the worker's default is the deployed service. `--jobs 1..4` bounds concurrent downloads (default 3), with a shared iTunes lookup throttle and serialized model inference. Download files are independent even if two library entries resolve to the same upload. On interruption, queued jobs are canceled, running jobs finish, and restarting skips current entries. Each pass reports updated/skipped/failed totals. Song title and duration matching remains heuristic; this does not establish authoritative recording identity.

## Verification

Run from `backend/`:

```bash
CHORDLYZE_REQUIRE_MODELS=1 PYTHONPATH=. .venv/bin/python -m pytest tests/ -q
PYTHONPATH=. .venv/bin/python scripts/check_recognition_capacity.py --seconds 600
```

The suite covers exact rich labels, model reuse/recovery, silence, asset validation, protocol failures, scoring regressions, schema validation, cache upgrades, ingest metadata and real multipart HTTP uploads. HTTP tests launch a temporary localhost server with a private cache and make no requests to the deployed API. Without `CHORDLYZE_REQUIRE_MODELS=1`, model-dependent tests skip when the checkout is absent; release checks must set it.

Validation on 4–5 September 2026:

| Check | Result |
| --- | --- |
| Complete backend suite, macOS | 140 passed, 17 expected failures |
| Complete suite against the final Linux AMD64 image | 140 passed, 17 expected failures |
| Linux ARM64 and AMD64 images | Built; pinned ensemble loaded during installation |
| iOS simulator build, signing disabled | Passed |
| Production Swift report decoder/timing contract | Legacy response plus four timing cases passed |

The expected failures are 15 existing major/minor-model limitations and the two documented rich-model limitations. The backend was deployed on 5 September 2026 with 4 GB RAM; the public health endpoint and an actual Cmaj7 inference check passed. The synthetic production check took 61.03 seconds including cold model/feature initialization for four seconds of audio. Resident reuse avoids repeating model loading, but this is not a latency guarantee. The production volume was snapshotted before deployment, and a library upgrade pass was started separately.

The capacity script generates a ten-minute chord take, keeps the preview model resident, and runs full rich inference. In a Linux container it prints peak cgroup memory and elapsed recognition time. Repeat this on the target architecture and resource limit after dependency/model changes. It checks capacity and output integrity, not musical accuracy.

On 4 September 2026, a local Linux ARM64 container capped at two CPUs and 4 GiB, with swap disabled, completed 600 seconds of audio in 41.73 seconds with a peak of 2,395.4 MiB. The same check failed at 2 GiB without swap. These are local container measurements, not a production latency promise.

The final Linux AMD64 image also completed this check on 5 September: 49.44 seconds, 2,223.9 MiB peak memory and zero swap, under the same limits. AMD64 ran through Docker Desktop's emulation on the development Mac; production latency should be measured on the deployed hardware.

The Swift report contract test in `tests/PracticeReportContract.swift` compiles the production client and verifies old reports, early/late changes, mixed timing errors and on-time display. Build the iOS app separately as shown in the root README.

## Measured limits and next work

The richer model matches 10 of 12 exact labels in the audited synthetic sequence, versus 0 of 12 for the major/minor recognizer. The two strict expected failures are `G:sus2` and the bass of `G:7/b7`. These figures describe this fixture only. The dictionary lacks sixth chords, minor-major sevenths and seventh-chord inversions; flexible-bass scoring deliberately does not assess inversion accuracy.

The live drill detector has now been replaced and evaluated; see its [results and remaining limitations](live-drill-detection.md). The next accuracy evidence should come from labeled iPhone drill recordings and real recorded-practice takes, including noise, detuning, fast changes, silence and partial takes. Measure root/quality accuracy, boundary error and no-chord precision separately before choosing another full-song model or decoder. Confidence should be shown only after calibration against that corpus.
