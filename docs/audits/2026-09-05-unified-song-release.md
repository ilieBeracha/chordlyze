# Unified song-sheet release verification

Recorded 5 September 2026 for iOS/API 0.5.0. Implementation commit: `167dcfd79ee89f90f2b7553edbbb2177d78b05fd`. Subsequent release metadata adds the API version to health and updates documentation; recognition and rendering logic are unchanged.

The Mac worker dependency described in this historical verification was subsequently removed by the [API 0.5.1 cloud-worker release](2026-09-05-cloud-worker-release.md).

## Checks

- Backend on macOS with the pinned installed ensemble: **164 passed, 17 expected failures**.
- The Linux AMD64 production image: **164 passed, 17 expected failures**, including actual model inference and real multipart HTTP practice uploads. Expected failures document existing model limitations; they are not skipped release checks.
- Shared song-sheet store, row construction and Spotify clock: **44 checks passed**. These include cancellation/reentry, automatic chart arrival, reset, rate limits, song changes, and pause/resume with missing progress samples.
- On-device drills: **102 detector + 43 worker + 6 input-format checks passed**, plus **3 benchmark contract tests**.
- Swift practice-report contract: legacy decoding and **4 timing cases passed**.
- Debug and Release Simulator builds succeeded. The authored offline fixture visually verified English/Hebrew chord placement, instrumental rows and Live movement. A doubled RTL mirror found during inspection was fixed. The fixture and its launch route are excluded from Release.

## Production round trip

The managed LaunchAgent was installed after explicit approval for worker access. A public reference request for Coldplay's “Yellow,” iTunes recording `1122782283` (Parachutes, 269.208 seconds), passed through the Fly queue and resident Mac worker:

- Queued at 0 seconds; downloading at 4; recognizing at 9; ready at 89.
- Decoded audio: **268.5156 seconds**, within the recording-duration gate.
- Complete chart: **60 chord segments**, current ISMIR2019 ensemble and provenance.
- Lyrics: **37 nonempty synchronized lines**.
- Full round trip, including lyrics lookup: **90 seconds**.

This verifies the data path and coverage, not perfect chord accuracy or sample-accurate cross-service lyric alignment. No audio or lyric text from that request was committed. A first request takes processing time; cached charts are immediate. Source availability and the Mac being online remain operational dependencies.

## Fresh library

The user explicitly requested removal of every analyzed song. After the round trip, the production reset removed **203 active analysis entries and 341 total song-cache JSON files**, including the smoke-test entry, aliases, lyrics and jobs. The local reset removed **25 analysis entries and 53 total cache files**. Models, credentials and benchmark fixtures were preserved.

Production library generation changed to `d547948414b641659cf90a0e9e2f001e`. Verification checks an empty `/library`, a missing status for the smoke-test song, HTTP 401 for an old unauthenticated worker and HTTP 409 for a retired lease. Heartbeats do not repopulate the library. A user opening or playing a song may request a fresh chart afterward.

The release PR is [#2](https://github.com/ilieBeracha/chordlyze/pull/2). Fly deployment is independent of GitHub/Xcode Cloud. The final health endpoint identifies the deployed source revision. App Store Connect requires a signed-in session to confirm processed TestFlight availability; Xcode Cloud build/archive success alone is not that confirmation.
