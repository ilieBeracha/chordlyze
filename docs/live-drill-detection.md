# Live drill recognition

The live detector now compares both targets against a broader chord vocabulary, rejects uncertain input, and counts accepted alternations using microphone sample timestamps. The largest measured improvement is fewer false accepts. It still misses short, muted and incomplete strums; it is not a perfect recognizer.

## Evidence from real recordings

The benchmark uses [GuitarSet's microphone audio and performed-chord annotations](https://guitarset.weebly.com/), downloaded from the [official Zenodo record](https://zenodo.org/records/3371780). Players 00/01 are the development split; players 04/05 are held out. All 120 comp takes from those players were considered. Eight lack two distinct supported pitch sets and are listed as excluded in the report. The resulting evaluation covers 112 takes and about 58 minutes of audio, including 53 held-out takes. No audio files are committed.

The frozen baseline is the previous production implementation from commit `91a0c69d516942728416328b25d9b550a67f0299`. Its two-target threshold, 250 ms dwell and stale highlight behavior are preserved. Offline playback substitutes sample timestamps for `Date`, so running the benchmark faster than real time cannot alter its dwell behavior.

Held-out results, excluding the first 600 ms and last 150 ms of each annotation interval to separate sustained recognition from boundary timing:

| Measure | Previous detector | New detector |
| --- | ---: | ---: |
| Correct fraction of accepted target time (precision) | 40.0% | 96.8% |
| Non-target time incorrectly accepted as a target | 77.3% | 0.50% |
| Target sections recognized at least once | 69.3% | 59.4% |
| Target time covered by a correct acceptance | 68.0% | 20.2% |

These figures must be reported together. Precision is conditional on accepting a chord; **96.8% is not overall accuracy**. The new detector is deliberately conservative and gives up coverage. Over the entire held-out timeline, including boundaries, its precision is 94.7%, target-section recall is 63.4%, and target-time coverage is 16.4%. The corresponding baseline values are 33.7%, 69.3%, and 59.7%.

GuitarSet's performed chord labels use sheet-informed segmentation and note annotations. They can label a whole harmonic interval even when only a bass note, dyad or short strum sounds. The live drill requires enough notes to support a chord and does not infer the missing harmony from the sheet. That mismatch explains some misses; it does not excuse all of them. Transient noise, strongly unequal string levels and brief extended-chord voicings remain difficult. The report preserves unknown labels and omitted/added degrees; it does not convert them all to major/minor or omit unsuccessful tracks.

Full counts, per-track results, exclusions, dataset checksums and source hashes are in [the benchmark report](audits/2026-09-05-live-drill-guitarset.json). This is a public guitar benchmark, not an iPhone microphone test or a piano/full-band validation.

## Signal and decision path

`ChordDrillDetector.swift` contains the deterministic core, independent of AVAudioEngine and SwiftUI:

1. A 16,384-sample Hann window advances by 2,048 samples. FFT setup and working buffers are reused. At 44.1 kHz these are about 372 ms and 46 ms respectively.
2. Spectral peaks provide a tuning estimate. Interpolated peaks are reconstructed with narrow lobes so broad pluck transients are less likely to become adjacent bass notes. A note needs spectral support from at least two of its first three harmonics.
3. An original harmonic dictionary and nonnegative coordinate-descent solver estimate note activity before folding octaves. Local spectral weighting reduces the influence of broad noise. The note range is MIDI 36–95, with analysis up to 5 kHz. This follows the approximate-transcription idea discussed by [Mauch and Dixon (ISMIR 2010)](https://webspace.eecs.qmul.ac.uk/s.e.dixon/pub/2010/Mauch-Dixon-ISMIR-2010.pdf); no NNLS-Chroma/Chordino implementation is copied or bundled.
4. Smoothed pitch-class evidence is compared against 20 qualities across all 12 roots, with duplicate pitch sets collapsed. Acceptance requires three supported pitch classes, required chord notes, adequate explained energy and a margin over the next candidate. Stronger evidence for a third chord cannot be forced into either drill target.
5. A target must remain the winner for at least 70 ms of audio time (three decisions at 44.1/48 kHz). The first accepted chord establishes the starting point; later accepted alternations add one change. Repeating the same chord after a rest does not add a change. The synthetic change regression requires acceptance within 750 ms; actual latency depends on voicing and evidence quality.
6. Silence clears the highlight and pre-rest note history. Uncertain/other-chord evidence clears the highlight. Timestamp gaps reset pitch history. A full restart resets score and prior acceptance.

Thresholds are evidence gates, not calibrated probabilities. The UI therefore displays listening/quiet/recognized states without a confidence percentage. The supported input range is 32–96 kHz; the full regression suite exercises 44.1/48 kHz, with additional target/competitor checks at 32/96 kHz. Bass position is flexible, and a perfect fifth may be omitted from extended chords. Pairs with the same pitch set, such as C versus C/E, Ab/G#, or Am7/C6, are rejected because the drill cannot distinguish them under that policy.

## Audio lifecycle

`DrillAudioWorker.swift` copies the microphone's temporary buffer into a preallocated inbox. The callback performs no recognition, FFT allocation or per-buffer Task creation. A nonblocking producer lock, eight-slot limit and 250 ms audio limit keep queued work bounded. Overload drops older queued audio; timestamps prevent the detector from treating the resulting gap as continuous evidence. DSP runs on one serial queue, and main-thread updates are coalesced to one pending delivery.

`ChordDrillListener.swift` assigns a generation to each session. Canceled permission requests and callbacks from old workers cannot update a replacement session. Audio interruptions, route changes and configuration changes stop the drill with a restart message. Normal completion removes the tap and flushes the last queued audio before reading the score. Cancellation discards pending audio. Each worker owns its FFT and storage until its background work finishes.

`DrillView.swift` guards repeated starts, cancels on navigation/backgrounding, and uses a monotonic countdown. Previous best scores use a separate `drillBest-v2-…` key because the old scoring behavior could award false changes. Existing saved scores are preserved under their old keys.

## Reproduce

On macOS with Xcode command-line tools:

```bash
bash scripts/test_drill.sh

# Python 3.11+. About 700 MB of compressed public data; extraction stays in /tmp.
python3 scripts/benchmark_drill.py --dataset /tmp/chordlyze-guitarset --download \
  --split all --out /tmp/live-drill-guitarset.json
```

The benchmark compiles and invokes the production Swift core, integrates accepted durations exactly so different hop sizes are weighted fairly, and reports both rejections and false accepts. The unit checks verify that evaluation preserves extended qualities and omitted notes. All dataset files must be present: a partial download cannot silently shrink the evaluation.

Validation on 5 September 2026:

- 102 detector checks: wrong chords, single notes, dyads, broadband noise, silence, quiet audio, ±30-cent tuning, unequal string tuning, strumming/decay, extended qualities, transitions, rests, timestamp gaps, restarts, malformed configuration and buffer-size invariance.
- 39 audio-worker checks: independent copies, queue limits, overload timestamps, cancellation, pending UI suppression, final flush and invalid-input reporting.
- Six additional input-format checks at 32 and 96 kHz.
- Three benchmark tests: duration weighting, precision/coverage denominators and chord-label semantics.
- iOS simulator build passed; generated bundle version remains 0.4.0 (build 2).
- The current detector processed 1,663 seconds of held-out audio in 34.72 seconds on the development Mac. This is an offline throughput measurement, not an iPhone latency guarantee.

## Remaining accuracy work

The next evidence needed is labeled iPhone recordings of actual one-minute drills, with complete chord voicings, short strums, varied distances and room noise. Optimize missed-change rate and acceptance latency while retaining the measured reduction in false accepts. Keep a fresh player/device holdout: these GuitarSet holdout results are now published and must not become a tuning set for a claimed new independent evaluation. The present model also needs separate piano and live-device interruption/route validation before claiming those scenarios work equally well.
