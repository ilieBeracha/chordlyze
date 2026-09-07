# Practice timing fixes — 7 September 2026

The reported symptom was playing in time with the song while both live feedback and the final result suggested lateness or a lower score. No recording from the user's device was measured during this change, so it does not establish the source or size of their actual acoustic offset.

## Corrections

- Carry the saved song calibration's scale through the complete take, display clock, duration, upload and backend scoring. Legacy takes default to scale 1; incompatible server responses fail safely rather than silently discarding calibration.
- Keep each chord's first recognition timestamp in captured audio through UI coalescing. Delayed display delivery cannot move that timestamp later.
- Apply the estimated 0.35-second detector correction and live timing windows in real seconds at every practice pace. The estimate is explicitly labeled; it is not a headphone calibration.
- Treat a matching chord that began before the take as held, instead of judging an impossible earlier transition as late.
- Use symmetric three-second early/late matching windows in the final scorer, with existing neighboring-interval bounds and one-to-one onset matching. The previous 0.5-second early / 3-second late windows could bias the signed timing average.
- Reset the visual chord lead to its documented default of zero.

## Results

Scoring version 3 separates the count of matched chord changes from the duration that matches the reference chart. A matched change can still be early or late. Original time-overlap accuracy, per-chord scores, section scores and timing errors remain available without automatically shifting or inflating them. A consistent offset is described only with sufficient stable transition evidence; the report does not decide whether it came from synchronization or consistent playing timing. Existing saved reports decode and retain their original score with an accurate label.

See [practice workflow](../practice-workflow.md) for the exact timing equations, matching gates and API fields. The [report screenshot](report.png) is an offline fixture, not the user's performance.

## Verification

- Backend scoring, API and actual audio upload regressions: **67 passed**.
- Swift practice feedback: **27 checks passed**, including delayed UI, half-speed correction and starting inside a held chord.
- Swift report/request contracts and saved-take recovery tests passed, including calibration round-trip and legacy decoding.
- Detector: **336 checks**; worker: **43 checks**; input formats: **6 checks**; benchmark tooling: **3 tests**.
- Shared song sheet/playback: **1,095 checks passed**.
- Debug Simulator and signed Release iOS builds succeeded. Report inspected in the dedicated iPhone simulator.

New report diagnostics require submitting/re-scoring the saved audio. Old recordings preserve the metadata captured by their original build; missing historical calibration scale cannot be reconstructed reliably. Exact headphone latency and actual playing timing still require an acoustic calibration check on the user's setup.

## Delivered

Backend release `2026-09-07-practice-timing-v3` is live; image digest `sha256:f9c7601600b1c3db5fdfe8836326f537087717af8bc5da66e03938c2f6d7826d`. Both Fly machines passed deployment checks and the library generation is unchanged. A synthetic constant-shift probe against the deployed scoring module returned scoring version 3, 3/3 matched changes, 90% original overlap, and +0.4 seconds consistent offset.

The signed Release build was installed successfully on the paired iPhone (`com.ilieberacha.chordlyze`). This includes the preceding lyric-spacing fix. No user takes were deleted or re-scored automatically.
