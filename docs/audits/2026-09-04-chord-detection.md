Chordlyze chord detection audit — 4 September 2026

The largest immediately demonstrated improvement is to integrate the richer recognizer you already have, fix practice scoring, and replace the live drill detector's assumption that every audible input is one of its two target chords. Improving full-song recognition further requires a measured combination of acoustic evidence, timing, vocabulary, and training data.

Perfect automatic labels for arbitrary music are not a defensible target: different harmonic interpretations can describe the same sounding notes. A useful target is accurate timing and chord identity, measured confidence, honest abstention, and quick correction of uncertain passages.

This is an audit and recommendation, not an implementation change. Repository revision: `91a0c69`. I inspected the local ISMIR checkout at revision `481f4ce703f8822b99f4037e9104ba1760e21ea3`, including its existing compatibility edits. No deployment or production library was evaluated. The [machine-readable results](2026-09-04-chord-detection-results.json) preserve the measurements below.

**What currently runs**

| Path | Actual recognizer | What it can return |
| --- | --- | --- |
| `/analyze_track` preview analysis | madmom CNN features + CRF | 12 major + 12 minor chords + `N` |
| `/practice_take` recording analysis | The same madmom pipeline | The same restricted vocabulary, regardless of the reference model |
| `ingest_worker.py` full-song analysis | ISMIR2019, five-network ensemble + HMM | A configured dictionary of richer qualities and selected inversions |
| iOS chord-change drills | 4096-sample FFT, 12-bin chroma, two cosine scores | One of the two requested chord names, or rejection below a fixed threshold |

The Python and Swift chord representations already support many rich labels. Parsing/display support does not mean every recognizer can detect those labels.

**Measured evidence**

The existing backend suite completed with **76 passed and 15 expected failures**, in 12.50 seconds. Of the expected failures, 12 concern exact rich-chord naming and three concern diminished-chord roots. The synthetic engine tests invoke madmom; submission tests supply labels directly and do not exercise ISMIR inference. There is no iOS test target in `project.yml`.

I ran both installed recognizers on the existing test synthesizer's C–F–G–C progression and its 12-item `RICH` progression. Each chord lasts two seconds with four strikes. The modal-label comparison uses the same 250 ms exclusion at each edge as the existing tests, but compares canonical chord objects so `Ab:dim7` and `G#:dim7` count as equivalent.

| Measurement | madmom | Installed ISMIR2019 |
| --- | ---: | ---: |
| Simple progression, modal labels correct | 4/4 | 4/4 |
| Rich progression, exact canonical modal labels correct | 0/12 | 10/12 |
| Rich progression, duration-weighted root score | 82.92% | 97.02% |
| Rich progression, duration-weighted tetrads-with-bass score | 0% | 80.35% |

These are diagnostic synthetic results, not estimates of accuracy on your music library. The duration-weighted metrics include boundaries and use `mir_eval`; the modal-label counts do not. The remaining rich-model errors were `G:sus2 → G:maj` and `G:7/b7 → G:7`.

Separate four-second silence, white-noise, and unpitched-click probes returned `N` in both offline models. The positive result matters: the demonstrated false accepts below concern the live detector, not those offline probes.

**1. Highest priority: make recognition and scoring capabilities agree**

Locations: `backend/chordlyze_backend/analysis/engine.py:40`, `backend/chordlyze_backend/main.py:482`, `backend/ingest_worker.py:73`, `backend/chordlyze_backend/practice.py:13`.

Practice recordings always go through madmom, while full-song references can contain `maj7`, `min7`, `sus`, diminished chords, and inversions from ISMIR. `_same()` requires exact root and quality, ignoring only bass. A perfectly aligned detected `C:maj` against reference `C:maj7` receives 0%. Playing Cmaj7 cannot make madmom emit a Cmaj7 label: that output class does not exist.

Use one recognizer interface with explicit vocabulary, model revision, input preprocessing, frame rate, and confidence capabilities. Run a suitable rich recognizer for practice as well as song analysis, with separate evaluation for isolated guitar and full mixes. Keep models resident in a worker process; the current ingest wrapper starts Python and loads all five networks for every file.

Report root, triad, extension, bass, and timing performance separately. An optional beginner scoring policy can permit specified simplifications, but must preserve the original detected label and clearly distinguish simplified correctness from exact correctness. Comparing both sides only as triads is not a permanent solution for an app claiming to assess sevenths.

Your existing [ISMIR2019 implementation](https://github.com/music-x-lab/ISMIR2019-Large-Vocabulary-Chord-Recognition) is the first baseline to integrate and benchmark. It already uses a decomposed chord representation and temporal decoding. [lv-chordia](https://github.com/openmirlab/lv-chordia) is an integration candidate that packages the same architecture and weights and offers a reusable session; its packaging alone does not establish an accuracy improvement.

**2. Highest priority for drills: reject chords outside the target pair**

Locations: `Chordlyze/ChordDrillListener.swift:67`, `:91`, `:129`.

I compiled the existing `template`, `chroma`, and `cosine` functions with the app's unchanged `Chord.swift` into a temporary macOS Accelerate/AVFoundation harness. It fed 16 consecutive 4096-sample buffers for each signal at 44.1 and 48 kHz. This exercises the actual DSP functions, not a Python approximation; it is not an iPhone microphone or UI lifecycle test.

With targets C and Am:

| Input | Observed result |
| --- | --- |
| F-major guitar voicing | Am won all 16 frames at both sample rates; mean score approximately 0.765 / 0.745 |
| Single C4 with six harmonics | C won all 16 frames at both rates |
| Am, MIDI notes 45/48/52 | Correct in 16/16 frames at 44.1 kHz; 11 Am / 5 C at 48 kHz |
| C versus C/E templates | Identical arrays; bass register has been discarded |

The 0.6 cutoff is a cosine similarity, not a probability. Even a pure root has theoretical similarity approximately `1 / sqrt(1 + 0.9² + 0.9²) = 0.618` to a triad template. Waiting 250 ms cannot correct a stable wrong classification. A winner/runner-up margin between only the two targets also cannot solve the F-to-Am example: the wrong winner already has a substantial margin.

Recommended detector:

- Evaluate the target chords against plausible alternative chords and an explicit insufficient-evidence state. Validate the target against the strongest alternative, not just the other drill chord.
- Replace nearest-FFT-bin folding with tuning-aware, multi-resolution pitch evidence: a CQT/filterbank or interpolated spectral peaks with harmonic suppression. Preserve bass register separately where inversion assessment is intended.
- Use overlapping windows from a ring buffer with known sample rate. At 48 kHz a 4096-point FFT has 11.72 Hz bin spacing; the E2–F2 separation is only about 4.90 Hz. Zero padding alone cannot recover the missing physical resolution.
- Model realistic voicings, strums and allowed omissions. Do not require every theoretical extension in every valid guitar voicing. A single root should not certify a complete chord.
- Use adaptive noise-floor/SNR gating and an onset-aware state machine. Base dwell time on audio sample timestamps, not when a task happens to execute on the main actor.
- Preallocate FFT setup/window/work buffers. Move heavy processing off the audio tap, bound queued work, and invalidate old callbacks on stop/restart.
- Clear the displayed sounding chord after silence/rejection, while keeping the previous accepted chord separately for change counting. `current` is currently retained through silence and is not reset in `start()`.

Treat 44.1/48 kHz, route changes, quiet rooms, background music, single notes, wrong chords, muting and rapid strums as required test cases. Calibrate false accepts and acceptance delay on recorded guitar; these probes do not establish the final thresholds. The [librosa CQT reference](https://librosa.org/doc/0.11.0/generated/librosa.feature.chroma_cqt.html) provides a useful offline feature baseline, not an iOS implementation.

**3. Fix practice timing and coverage before trusting its accuracy number**

Locations: `backend/chordlyze_backend/practice.py:30`, `:39`, `:51`, `:72`; recording clock at `Chordlyze/Views/PracticeView.swift:244`.

Reproduced directly against `score_take()`:

| Case | Actual output | Required behavior |
| --- | --- | --- |
| Reference C from 0–8 s; correct four-second take at song offset 2 s | 50%, reported coverage 0–8 s | Score the recorded intersection 2–6 s: 100% |
| Twelve-second take silent for first/last four seconds, correct only in the middle | 100%, coverage narrowed to 4–8 s | Keep the actual recorded span; account for missed playing at its edges |
| Correct sequence of 0.5-second reference chords | “take does not overlap the song” | Include every positive overlap; the current strict `> 0.5` filter drops them |
| G stops at 3.7 s; reference requires G from 4 s onward, but player stays on C | Zero transition lag and no miss | Match the actual target occurrence; the old G is not a successful change |

Pass recording duration explicitly and intersect reference intervals with the recording span before calculating denominators. Retain silence within the declared take. Match transitions one-to-one within local time windows, including signed early/late errors. Avoid reusing an old or later repeated occurrence of the same chord.

Calibrate recording/playback latency per audio route. A capture timestamp plus a Spotify position estimate is not a measurement of headphone/Bluetooth output latency. If score following is added for flexible solo practice, keep it separate from timing grading: unconstrained time warping can hide real timing mistakes.

**4. Verify the recording being analyzed and its timeline**

Locations: `backend/chordlyze_backend/fulltrack.py:31`, `backend/ingest_worker.py:44`, `:87`.

Candidate acceptance requires a matching title and duration within `max(3 seconds, 2%)`. Artist identity only contributes a ranking bonus; it is not an acceptance condition. A fabricated same-title, same-duration result from an unrelated artist's Topic channel was accepted. `itunes_duration()` also takes the first search hit without validating edition identity.

Use verified artist/release metadata and preserve source ID, source duration and selection evidence. Where matching audio is available, compare fingerprints or subsequence features against a trusted preview/recording. A matching excerpt can support recording identity; it does not by itself establish the absolute Spotify timeline. A time-anchored reference is needed to establish source offset or drift reliably.

Represent any validated mapping explicitly, for example `song_time = scale * source_time + offset`. Do not assume a music-video intro, trimmed upload, remaster or speed-modified recording starts on the same timeline because the lengths are close. Handle ambiguous matches explicitly.

The app already correctly excludes previews with unknown offsets from the synchronized sheet and practice entry point (`SheetModel.swift:66`, `ChordSheetView.swift:61`). Preserve that behavior.

**5. Improve decoding using confidence and rhythm, while retaining real off-beat changes**

Locations: `backend/ingest_worker.py:89`, `backend/chordlyze_backend/analysis/beats.py:12`; installed model's `chord_recognition.py:27` and `extractors/xhmm_ismir.py:106`.

The richer model already averages five networks and runs an HMM. Beat tracking currently produces metronome data independently; it does not guide chord decoding. The upstream decoder defaults to a fixed change penalty of 30. Its optional beat mode can forbid changes between beats, so simply enabling that switch is too restrictive for anticipations and syncopation.

Preserve frame-level outputs and model disagreement, then decode with acoustic evidence, soft beat/downbeat preferences, and duration priors. Let strong evidence place a change off the beat. Estimate local harmony with a weak contextual prior that can accommodate modulations and borrowed chords. Refine boundaries near acoustically plausible changes; do not snap every boundary to the nearest beat or delete every short segment.

The default ISMIR dictionary also limits which head combinations can become labels: it includes selected triad inversions but lacks `C:7/b7`, `maj6`, `min6` and `minmaj7`, despite the app supporting those representations. Audit the dictionary against the product's supported vocabulary and measure extension/bass errors separately.

I reused identical acoustic probabilities and tried penalties 5/15/30/60, with both the existing dictionary and one adding those four shapes across roots. Every variant still named 10/12 modal chords correctly. Penalty 5 increased segmentation from 13 to 16 intervals. This experiment shows that these particular remaining errors require more than a dictionary or smoothing adjustment.

Keep calibrated segment/root/quality/bass confidence, alternatives, and an explicit uncertain state. `N` means no chord; it should not also mean “the recognizer is unsure.” Confidence should govern grading eligibility and the offer to correct a passage. [Beat This!](https://github.com/CPJKU/beat_this) provides an available learned beat/downbeat baseline to compare against the existing librosa tracker.

**6. Evaluate source separation and newer models as controlled experiments**

For dense full mixes, compare the original mix against a remix that emphasizes accompaniment and preserves useful bass. Evaluate full mix, accompaniment and bass evidence together. Do not discard bass before trying to identify inversions, and do not assume HPSS removes vocals: vocals are often harmonic too.

A [2025 source-separation study](https://www.apsipa.org/proceedings/2025/papers/APSIPA2025_P307.pdf) evaluates this idea with BTC and HTDemucs. It supports testing accompaniment emphasis, not a guaranteed gain for this application's data. Keep the original mix as a baseline because separation can remove chord tones or introduce artifacts. A second pass focused on uncertain passages can control compute cost.

Candidate experiments:

| Candidate | Reason to evaluate | Limit of current evidence |
| --- | --- | --- |
| Existing ISMIR2019 ensemble | Already installed; demonstrated rich-label improvement here | Domain accuracy and calibration remain unmeasured |
| [BTC, large-vocabulary configuration](https://github.com/jayg996/BTC-ISMIR19) | Independent transformer architecture for comparison | Also a 2019 approach; not inherently better because it uses attention |
| [ChordFormer](https://arxiv.org/abs/2502.11840) | Structured triad/bass/extension prediction and class-imbalance treatment | Research candidate; no official ready-to-run checkpoint was verified in this audit |
| [2026 pseudo-labeling and distillation work](https://arxiv.org/abs/2602.19778) | A path to improve rare-chord/domain performance using unlabeled audio plus corrected labels | Requires a training/evaluation effort, not a configuration change |

The longer-term differentiator is a labeled dataset representative of your actual recordings and repertoire. Fine-tune for isolated instruments versus full mixes; include different keys, detuning, timbres, voicings, strum timing, room responses, codecs, and rare qualities. Preserve musician corrections as a separate annotation layer and use reviewed errors for targeted training. Never silently recycle model guesses as ground truth. A [2025 experimental thesis](https://arxiv.org/abs/2512.22621) also identifies rare chords as a persistent weakness and reports benefits from pitch augmentation.

**7. Stop presenting key fit and model rank as certainty**

Locations: `backend/chordlyze_backend/analysis/keyfinder.py:36`, `backend/chordlyze_backend/main.py:74`, `:172`; `backend/ingest_worker.py:108`.

`key_confidence` is diatonic coverage, not a calibrated probability or the margin over a rival key. The equally timed Am–F–C–G loop gets C major with confidence 1.0 although C major and A minor tie under the voting rule. Am–Dm–E7–Am gets A minor with only 0.75 fit because the minor template only includes natural minor. A progression containing only suspended qualities produces no key vote.

Combine independent audio evidence with cadence/tonic information and local key estimates; report competing keys or uncertainty where appropriate. Do not feed this global heuristic back as a hard chord filter. Add harmonic-minor dominants, modulation and ambiguous-relative-key fixtures.

Saved analyses use track/ISRC paths, and existing records return immediately. A static rank assumes ISMIR always supersedes madmom; the worker skips entries already labeled `ismir2019`. There is no weight, decoder, dictionary or preprocessing revision in that upgrade decision. Consequently, a corrected pipeline does not automatically refresh old results.

Persist decoded-audio hash, model/checkpoint hash, vocabulary hash, preprocessing and decoder versions, source identity, time mapping, and evaluation revision. Schedule reanalysis when those inputs change. Retain previous machine results and musician edits so regressions can be compared and corrections survive. Update the README: its claimed content-hash caching and single-detector architecture no longer describe the code inspected here.

**Implementation order and proof of improvement**

1. Establish a baseline for both offline engines and the live DSP, and turn the reproduced scoring/false-accept cases into regression tests. Canonicalize enharmonic labels; score full intervals and boundary precision as well as recall. Existing nearest-boundary tests do not penalize extra boundaries.
2. Fix scoring coverage and event matching. Integrate a rich practice recognizer with explicit capability and provenance fields. Reject unsupported grading claims and uncertain source timelines.
3. Replace the live target-pair classifier with evidence-based rejection, stable streaming features and timestamped state handling. Validate on actual devices and microphones.
4. Add soft rhythmic decoding, calibrated uncertainty, source verification and versioned reanalysis. Compare each addition independently before combining it.
5. Benchmark alternative models and separation; then fine-tune on a reviewed target-domain dataset if the measured errors justify it.

Build separate held-out sets for full songs and instrument-only recordings. Start with 50–100 representative recordings and all target chord families, then expand until per-family results are stable. Include the app's actual language/genre mix, not only Western pop benchmarks. [GuitarSet](https://guitarset.weebly.com/) provides microphone audio and chord/pitch/beat annotations for an instrument baseline; distinguish its instructed chords from its performed annotations, whose boundaries and roots partly derive from the lead sheet. Add genuinely unseen manually reviewed recordings to check deployment behavior.

Report duration-weighted root/triad/seventh/bass metrics, per-quality recall, boundary precision/recall at declared tolerances, false accepted drill changes per minute, time to accept a correct change, confidence calibration, abstention coverage, latency and memory. Use [mir_eval's chord metrics](https://mir-eval.readthedocs.io/latest/api/chord.html) with explicit vocabulary coverage: a high major/minor score can exclude or simplify the very extended chords you care about. Split by song/artist/player as appropriate, and check pretrained-model training overlap before calling a benchmark held out.

Set release thresholds from this baseline and the desired false-feedback rate. Any proposed percentage gain before that evaluation would be speculation. Broad vocabulary, more smoothing, a bigger network or a fluent language-model explanation does not establish better recognition on its own.

**Reproduction notes**

Run the original suite from `backend`:

```sh
PYTHONPATH=. .venv/bin/python -m pytest -q
```

The model comparison used `tests.test_engine_synthetic.synth_progression`, `RICH`, `analysis.engine.recognize_chords`, and `ingest_worker.recognize_ismir`, without changing their implementation. `mir_eval` ran from the already installed ISMIR virtual environment. Estimated intervals were clipped to the known synthetic duration before metric calculation. Modal matches used `analysis.chord.parse_label` equality.

For the live DSP probe, the F voicing was MIDI `[41, 45, 48, 53, 57, 60]`, Am was `[45, 48, 52]`, C was `[48, 52, 55]`, and the single root was MIDI 60. Each note summed six sine partials weighted `1/h`; the combined signal was multiplied by `0.15 / note_count`. Pure-sine tests used one partial. The quiet condition applied a further gain of 0.01. Buffers were contiguous, 4096 samples each, with 16 buffers per condition. Class scores were compared with the production 0.6 threshold; the UI's asynchronous 250 ms state handling was not executed.

Temporary WAVs, the compiled Swift harness and decoder-variant script remain in `/private/tmp/chordlyze-detection-audit` for this session. The saved JSON preserves measured outputs independently of those temporary files. No recognizer was trained, no newer model or separation system was installed, and no real-world accuracy gain is claimed.
