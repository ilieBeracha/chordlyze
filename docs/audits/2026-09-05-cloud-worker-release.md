# Cloud song-worker release verification

Recorded 5 September 2026. Backend implementation: `564becb0703780bf45b6b609b2ef741bf0ea4904`, API **0.5.1**. This moves full-song processing off the development Mac. The existing iOS 0.5.0 song-sheet API contract is unchanged.

## Automated checks

- macOS, installed pinned recognizer: **208 passed, 17 expected failures**.
- Linux AMD64 production image with 4 GiB memory: **208 passed, 17 expected failures**.
- The expected failures document existing chord-model limitations. The suite includes actual model inference and HTTP request, lease, checkpoint, publish and reset checks.
- New coverage includes cloud search, recording validation, bounded spending and timeouts, cancellation, partial-file cleanup, safe media origins, provider failures, and reuse of paid runs after worker replacement. Malformed resume responses cannot silently launch another paid run.
- `flyctl config validate --strict` and `git diff --check` passed.

## Deployment and credentials

Fly application `chordlyze-api` has two machines in Frankfurt:

| Process | Machine | Resources | Persistent storage |
| --- | --- | --- | --- |
| API | `287e645f44dd78` | 2 shared CPUs, 4 GiB | Existing `vol_4qlm6md0ok55j5wr` at `/data` |
| Worker | `1854d39a572608` | 2 shared CPUs, 4 GiB | None; jobs and checkpoints remain on the API volume |

The worker has no HTTP service and has an `always` restart policy. The deployed image digest is `sha256:e6ba2a66212c1644f6ea2ae61aad4fb6bca4c67a3953bab79663c815a268fbe8`. Deployment smoke checks passed. The CLI's separate DNS check timed out against its configured resolver; direct HTTPS requests to the production API succeeded.

`APIFY_TOKEN` is a dedicated token stored as a Fly secret. It has Actor-specific Read, Run, List runs and Manage runs for `streamers/youtube-scraper` and `streamers/youtube-video-downloader`, restricted Actor access, and access to default run storages. The first cloud smoke request exposed an additional request-queue creation requirement. After explicit user approval, the storage **Create** permission was added; account-level storage Read and Write were not added. The temporary local credential file and clipboard copy were removed.

The Mac LaunchAgent `com.chordlyze.song-worker` was stopped and disabled for future logins. Verification found no running Mac song-worker process before the production requests.

## Production verification

The two selected recordings have synchronized lyric data: Coldplay's “Yellow” (Parachutes, 269.208 seconds) and Rita's “מחכה” (רמזים, 247.773 seconds). Only synthetic migration track IDs are used, without ISRC aliases, so test cleanup can preserve user songs.

The English request completed with the Mac worker disabled:

- Queued at 0.5 seconds, downloading at 3.9 seconds, analyzing at 122.0 seconds, ready at 253.4 seconds.
- Decoded audio: **268.5156 seconds**, within the requested recording's duration gate.
- **60 chord segments and 37 nonempty synchronized lyric lines**.
- Cloud search run `rRDOX3qd55C78vtBM`; download run `75Vb7lbm9Al8FKOj0` completed in 103.224 seconds.
- The submitted chart identifies the Apify source and pinned five-model ISMIR2019 ensemble.

The Hebrew request also completed with the Mac worker disabled:

- Queued at 0.6 seconds, downloading at 3.8 seconds, analyzing at 105.5 seconds, ready at 125.3 seconds.
- Decoded audio: **247.8266 seconds**, within the requested recording's duration gate.
- **106 chord segments and 54 nonempty synchronized lyric lines**.
- Cloud download run `hGAgynq7bpXbU1f9g`; chart provenance again identifies Apify and the pinned model.

Reopening the English song returned its existing chart in **0.276 seconds**, with the same provider run ID and no new analysis job. Both production charts had ordered, nonempty chord intervals and passed the recording-duration checks. No downloaded audio files remained on the Fly worker after processing.

These checks verify complete cloud data flow and recovery safeguards, not perfect chord accuracy or sample-accurate alignment between external recordings and lyrics. Fresh requests took approximately two to four minutes in this run; the worker retains its loaded recognizer for later requests, and existing charts load from cache. Recording availability, lyric catalog coverage and provider account limits remain dependencies.

## Final state

Both migration charts and their job records were removed after verification. All **four user-created songs** present before testing remain, and the library generation is unchanged: `d547948414b641659cf90a0e9e2f001e`. The test IDs return `missing`. The API reports version 0.5.1, the implementation revision above, and a healthy cloud worker heartbeat while the Mac service is absent and disabled.

The release is tracked in [pull request #3](https://github.com/ilieBeracha/chordlyze/pull/3). The backend deployment is already live; this migration does not require a new iOS binary. It does not independently confirm App Store Connect's processing or distribution status for any prior iOS upload.
