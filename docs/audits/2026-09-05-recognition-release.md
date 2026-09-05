# Recognition milestone release record

Recorded 5 September 2026. This records the recognition milestone; the later song-sheet, lyrics, queue and library-reset work is a separate active change.

## Source and verification

The frozen baseline for final verification is merged revision `dde717f118c9b530a4920b534d3dc44f8ec56316`. The backend snapshot includes these subsequent off-server ingestion changes:

| File | SHA-256 |
| --- | --- |
| `backend/ingest_worker.py` | `05d077584953dc1dbb39b55d860a49a18ef1c3fc9667d170f1a5a27018213f5e` |
| `backend/chordlyze_backend/fulltrack.py` | `fba2d8c059177ad3b7fb4fd223067f276d3bde10fc727506f3bb5c532f1d50f0` |
| `backend/tests/test_ingest_batch.py` | `c5b941038a0a8c094bb7d2a558cd1bcaeb73949817171988e686b781907bb653` |

Backend results: 145 passed and 17 expected failures. The first isolated run passed 141 tests; the four real HTTP tests initially could not bind a localhost port inside the sandbox, then all passed with localhost access. The Linux AMD64 recognition image passed the preceding 140-test suite with the same 17 expected failures. The five additional tests cover retries in the off-server ingest worker, which is not included in the API image.

The current shared checkout was also tested during the other task's edits. Its old preview-refresh and blank-lyrics tests disagreed with the new queue and instrumental-break behavior. Those changes were preserved, and the recognition snapshot was tested independently; this report does not claim the evolving shared checkout passes all tests.

The final live drill checks passed: 102 detector cases, 43 audio-worker cases, six input-format cases and three Python benchmark tests. The final audio-worker changes synchronously record invalid input, suppress stale UI delivery, and prevent a canceled or failed stream from returning a completed score. The iOS simulator build passed independently from the newer song-screen edits, with signing disabled; this is not a claim that the final shutdown changes have reached TestFlight. Full benchmark results and remaining recall limitations are in [the live detector guide](../live-drill-detection.md).

## Backend deployment

The recognizer was deployed to `chordlyze-api` on its existing machine and persistent volume with two shared CPUs and 4,096 MB RAM. The initial verified recognition image is:

```text
registry.fly.io/chordlyze-api:deployment-01M1Q7VWS95E3BR07RHEYM16HM
sha256:7a2447941514f4ccc82e28ad724c95d8e1f1bd793fbb6f9f72b894acedf12151
```

Release 22 inadvertently included the other task's unfinished song queue because the shared source changed during deployment. Release 23 restored the verified image above, preserving the machine, 4 GB allocation and existing data. Public `/health` returned HTTP 200 with `{"status":"ok"}` afterward. The working-tree queue and lyrics changes were not reverted.

An actual inference check on the deployed AMD64 machine recognized a four-second synthetic Cmaj7 recording as `N` followed by `C:maj7`, with more than two seconds of Cmaj7 coverage. It used analysis version 2 and model revision `481f4ce-ensemble5-submission-penalty30-v1`. Cold initialization and inference took 61.03 seconds. The check used temporary audio and did not add a library entry.

The pre-upgrade server-side volume snapshot was verified as created: `vs_gkkOQR303AOVt5n2Rl4nML9`, created `2026-09-04T22:13:19Z`, with five-day retention. No private production-library inventory was downloaded to the repository.

## Historical library refresh

The initial library had 196 entries requiring an upgrade. The first serial run updated 13 entries; the subsequent bounded concurrent pass updated 153, skipped 16 and failed on 14. Thus 166 were upgraded and 30 remained pending at the end of that pass. Thirteen failures were temporary name-resolution errors and one source video was unavailable. Skipped entries had no suitable metadata or upload within the existing duration tolerance.

The old batch is stopped. A later explicit user request in “Improve chord detection logic (2)” asked to clear all analyzed songs and start over, so this task did not retry the remaining entries or repopulate the library. Library clearing and the new on-demand workflow belong to that task. These counts describe the completed refresh pass, not the library after any subsequent reset.
