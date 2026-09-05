# Unified song sheets and live follow

Search, saved songs, the home song sheet, Live and recorded Practice use one `SongSheetStore` and one `ChordSheetView`. Chords appear above lyric tokens. A chord that continues into the next lyric line is repeated there. Timestamped blank lines retain instrumental chord rows. A long lyric line remains intact instead of turning into empty eight-second continuation rows. Hebrew and Arabic use the same token layout in right-to-left order.

Live follows Spotify playback automatically. Search and Library show the static sheet; Practice uses the same rows with the take's clock. This does not turn Spotify Live into microphone-based song identification. On-device chord drills remain a separate instrument exercise.

## Loading and timing

Opening a song posts its recording metadata to `/song/request`, then follows `/song/{track_id}`. Lyrics load independently while a complete chart is prepared. Reopening a ready song reuses the chart. Concurrent views share a document and subscriber count; the last departure cancels work. Reentry starts fresh requests. Old, canceled responses cannot replace the current song.

Full song duration and album information travel from Spotify/iTunes through Search, Library and lyrics lookup. Both exact and search lyric matches are checked against title, artist and duration. A 30-second iTunes preview starts at an unknown offset and is never positioned against the whole song. The old `/analyze_track` route now queues a whole-song chart and returns HTTP 202 while pending.

Known lyrics and known chords can load at different times. Missing data is shown explicitly. Instrumentals keep their chords. Unavailable lyrics are not invented. Enhanced LRC supplies word timestamps; ordinary synchronized LRC supplies line timestamps, so placement within a line is approximate and labeled. Unsynchronized lyrics use estimated line timing and are labeled accordingly. Matching source title, artist and duration reduces edition errors but does not prove sample-accurate alignment between services.

Spotify polling starts immediately, runs separately from analysis, and honors rate-limit delays. A monotonic clock advances between polls, freezes on pause and resynchronizes on seeks or song changes. Connection failures retry automatically, and background/foreground transitions restart polling. Extrapolation stops after 15 seconds without a successful playback sample. A view-owned `TimelineView` redraws and scrolls Live; screens do not share a disconnectable timer.

## Full-song worker

The Fly API stores a durable request queue on its existing volume. A separate Fly `worker` process searches and downloads a matching full recording through Apify, then runs the pinned five-model recognizer. The worker has no HTTP service and does not participate in Fly proxy autostop. It restarts after exits and operates independently of the development Mac and Codex. The volume is mounted only by the API process; the worker claims jobs over the authenticated API.

The worker first searches YouTube metadata directly with yt-dlp, which is free and takes a few seconds; Apify's maintained `streamers/youtube-scraper` is the fallback when that search is refused or finds no match. Existing title, artist, edition and duration checks select a matching recording. Actor runs get 4096 MB so they receive a full CPU core; pay-per-event Actors do not bill platform usage. The worker loads the recognizer at start-up so the first song does not wait for it. `streamers/youtube-video-downloader` produces an MP3 in Apify storage; the worker downloads the completed file, never the temporary YouTube stream URLs. Both reported duration and decoded audio duration must match the requested recording. Lyrics still come from the backend's timed lyric lookup, using the same recording metadata.

Provider run IDs are saved with the job lease before polling. After a worker restart, another worker can reuse the search/download run instead of paying to start it again. GET failures retry with bounded backoff; an ambiguous POST response is not automatically repeated. Each search is capped at $0.05, each download defaults to a $1 charge cap, each Actor is limited to five minutes, and downloaded audio is capped at 100 MiB. A cost cap limits billed events; it is not a promise that every source is available. Limits are configurable with validated environment settings. Provider failures, usage limits and missing recordings are reported as retryable song states; existing charts continue to load.

Run output audio in this downloader's Apify-owned storage expires after approximately three days. Local worker audio is deleted after inference or failure. Only chart data and source/run provenance are submitted to the API. The provider token is sent in Authorization headers to the fixed Apify API origin and is never forwarded to audio URLs, stored in song documents or included in logs.

The worker only processes requested jobs. It does not sweep or repopulate the old library. It sends heartbeats, renews a three-minute lease while working, cleans downloaded audio, and publishes with a worker token, lease and library generation. Expired jobs can be reclaimed up to three times. Failed/unavailable jobs expose Retry. Requests are limited to 20-minute recordings; source availability and processing time mean a first analysis is not instant. Already analyzed songs load directly.

Production uses Fly secrets `CHORDLYZE_WORKER_TOKEN` and `APIFY_TOKEN`. Configure a dedicated scoped token with Read, Run, List runs and Manage runs on the two named Actors, restricted Actor access, and default-run-storage access. The search Actor also requires the account-level storage **Create** permission to create and manage its own request queue; default-run-storage access alone does not cover that creation. It does not need account-level storage Read or Write permissions. `backend/fly.toml` configures the provider, limits and process groups. The Docker image contains both the API and worker and installs the pinned model. Secrets are excluded from Git and Docker.

For optional local development, use `backend/.env.worker` with mode 600: `CHORDLYZE_API_URL`, `CHORDLYZE_WORKER_TOKEN`, `CHORDLYZE_ISMIR_DIR`, `CHORDLYZE_TORCH_THREADS=2`, and an optional writable `NUMBA_CACHE_DIR`. Set `CHORDLYZE_AUDIO_PROVIDER=apify` and `APIFY_TOKEN` to test the cloud path. The default `yt_dlp` provider is retained for explicit local development. Do not run a local production worker after cloud cutover.

```bash
cd backend
.venv/bin/python scripts/install_song_worker.py         # show installation paths
.venv/bin/python scripts/install_song_worker.py --apply # install/restart this one LaunchAgent
launchctl print gui/$(id -u)/com.chordlyze.song-worker
```

The optional LaunchAgent is `~/Library/LaunchAgents/com.chordlyze.song-worker.plist`; it should be unloaded and disabled after cloud verification. Logs are under ignored `backend/worker-logs/`. `GET /health` reports `api_version`, `release`, `analysis_version`, `library_generation`, and `song_worker_online`; no credentials are returned. The legacy batch ingestion utility is for development only: production requires a current on-demand lease.

## Explicit fresh start

Resetting removes active track analyses, ISRC aliases, lyric caches, request jobs and heartbeat state; it rotates the library generation under the same interprocess lock used for publication. Old job results then return HTTP 409. Old unauthenticated workers return HTTP 401. In-flight lyric lookups cannot restore the old cache. Credentials, recognition weights, benchmark fixtures and source code are untouched.

```bash
cd backend
PYTHONPATH=. .venv/bin/python scripts/reset_song_library.py         # dry run
PYTHONPATH=. .venv/bin/python scripts/reset_song_library.py --apply # explicit local reset
# On Fly, run /app/scripts/reset_song_library.py with PYTHONPATH=/app
# and CHORDLYZE_CACHE=/data/analysis_cache using the installed container Python.
```

Verify `/library` is empty after reset. A currently visible sheet notices the changed generation and drops its old analysis; Retry or opening a song starts a new analysis. The managed worker does not enqueue anything itself. Historical Fly snapshots follow their existing retention policy and are not used to repopulate the active library.

## Validation and release

```bash
bash scripts/test_song_sheet.sh
bash scripts/test_drill.sh
cd backend
CHORDLYZE_REQUIRE_MODELS=1 PYTHONPATH=. .venv/bin/python -m pytest tests/ -q
```

Song-sheet tests cover held chords, lyric preservation, instrumental markers, word groups, unknown-offset preview rejection, interval boundaries, cancellation, shared subscriptions, generation reset, automatic chart arrival, playback progression/pause/track change and rate-limit recovery. Backend tests include real HTTP request → claim → heartbeat → publish → ready → reset, stale publication rejection, and installed-model inference.

Build Debug for Simulator and launch with `--song-sheet-preview` for an offline visual fixture. It uses authored sample text and real production views. Check English and Hebrew ordering, chord diagrams, transposition, Live progression/pause/reentry and the Practice entry. The fixture is compiled out of Release builds and never requests a production song.

Deploy the backend explicitly; merging GitHub does not deploy Fly. Include `--build-arg APP_REVISION=<git-commit>` and check `/health`. Push and merge the iOS change into `main`, check Xcode Cloud build and archive results, then confirm the processed build in App Store Connect → TestFlight. An archive succeeding is not itself proof that testers can install it. Version 0.5.0 contains the unified sheets and requires the matching song-request backend.
