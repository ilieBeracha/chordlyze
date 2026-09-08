# Spotify playback reliability

## Changes

Spotify commands now run one at a time through `SpotifyNowPlaying`. Each command invalidates older polling requests before sending a write. Startup and seeking read fresh playback state until Spotify confirms the requested track, device and position. An accepted HTTP request alone never moves the app's playhead.

- Startup accounts for elapsed playback while the command was in flight. Previously, a song already more than three seconds past the requested start could be reported as a failed start.
- Rapid seeks retain the active HTTP write and the newest pending destination. Intermediate destinations are skipped; writes do not overlap. A superseded seek returns `true` to mean its intent was replaced, not that its individual destination was reached.
- Navigating between screens, reloading Home, or refreshing an access token does not restart an already running poller or interrupt a control operation.
- Backgrounding, signing out, and caller cancellation invalidate command completion. A canceled discovery cannot later send play; a command already sent may still execute in Spotify, but its result cannot restore old app state.
- Full playback state (`GET /v1/me/player`) supplies the device ID. Seeks target that device, and practice starts require confirmation from the selected phone. Restricted devices are excluded. Multiple inactive phones require selecting the intended phone in Spotify rather than guessing.
- Position inputs reject non-finite/overflowing values. Seeking to the song's end clamps one millisecond before it, because seeking past the duration can advance playback to the next song.
- If a play/seek response times out or the connection drops, the app checks playback before reporting failure. It never repeats an uncertain write automatically.
- Rate limits preserve `Retry-After` for discovery, controls, and polling. Further taps are blocked during the controller's cooldown. Cooldown covers this shared playback controller, not all independent catalog API instances.
- Only an explicit `PREMIUM_REQUIRED` reason is described as a Premium failure. Other 403 errors retain a device/access explanation and do not permanently disable live polling.
- The sheet shows a pending indicator and the actual control error. Practice's pre-recording wait has a deadline and checks connection/cancellation, so a frozen playhead cannot leave the count-in running indefinitely.

## Authentication and transport

All Spotify requests use a 12-second timeout and bypass local cache. A 401 triggers one token refresh and one retry; 403, 429 and uncertain writes are not automatically replayed.

The OAuth layer shares rotating-token refreshes across concurrent requests. A late 401 for an old token cannot discard a newer token. A failed refresh never returns an expired access token. Only a refresh response identifying `invalid_grant` removes the saved login; transient failures preserve it. A refresh finishing after logout cannot restore credentials.

## Confirmation and limits

Confirmation permits a one-second lower tolerance and a two-second upper tolerance plus elapsed playing time. It reads at most 16 snapshots within a 12-second window, with an in-flight HTTP read allowed to finish under its own timeout. These are engineering tolerances, not sample-accurate audio measurements. An operation taking too long or reporting another device/song fails explicitly and normal polling reconciles the screen.

The Web API does not identify which account device is the physical handset running Chordlyze. The controller prefers the active controllable smartphone, otherwise the only controllable smartphone. If the intended phone is unavailable, open Spotify on it and select it there.

Spotify still owns actual audio playback, device availability and command timing. This work does not replace audio-based synchronization or remove Bluetooth latency. Physical-phone Spotify playback, audio routing and microphone/practice startup have not been validated by these offline checks.

## Verification

```bash
bash scripts/test_song_sheet.sh
bash scripts/test_spotify.sh
bash scripts/test_practice.sh
xcodebuild -project Chordlyze.xcodeproj -scheme Chordlyze \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/chordlyze-personal-build CODE_SIGNING_ALLOWED=NO build
```

- Song sheet/playback suite: 1,201 checks, including stale pre-seek responses, delayed confirmation, rapid seek coalescing, idempotent resume, cancellation before discovery/after write, 403 recovery, device mismatch, restricted/ambiguous phones, uncertain writes, control cooldown, paused seeks and end-of-track bounds.
- Spotify HTTP/authentication suite: 18 checks against the real API/auth code using URLProtocol, an injected clock and an in-memory keychain. No account credentials or live Spotify calls are used.
- Practice persistence/request contracts and 27 feedback checks pass.
- iOS simulator build passes. Existing unrelated Swift 6 isolation warnings in `PracticeHubView` remain.

Physical-device check: open Spotify on the intended phone, start a selected practice passage, cancel during startup, rapidly tap several chord lines, switch Spotify devices, leave/return to Chordlyze, and briefly disconnect networking. Check the audible position and selected device against the chart and error messages. This is a remaining device validation step, not a completed test.

## API references

Spotify documents that [player command ordering is not guaranteed](https://developer.spotify.com/documentation/web-api/reference/start-a-users-playback) when endpoints are used together, and that [restricted devices cannot accept Web API commands](https://developer.spotify.com/documentation/web-api/reference/get-a-users-available-devices). The controller serializes its writes and uses the available device state accordingly.

## Missing phone recovery (2026-09-07)

The reported MacBook-only error was also visible in the running iOS Simulator. A simulator cannot host Spotify's native iOS app; it cannot advertise itself as a phone playback device. Spotify documents the [physical-device requirement](https://developer.spotify.com/documentation/ios). Web API control of another available device is separate from playing on the simulated handset.

Practice and automatic sync now show a device recovery card for missing, ambiguous or restricted phones. On an iPhone, **Open Spotify** opens the selected track. The card tells the user to select the phone in Spotify's device picker, play the song, and return using the same account. Returning triggers a read-only availability check; it never starts the microphone or a recording. Once a phone is available, an explicit retry restarts the original practice/sync flow with its existing settings. An unavailable Spotify app, a still-missing phone and canceled/backgrounded checks have distinct recovery states.

Device discovery retries up to three reads with 0.6/1.2-second delays when only non-phone devices or no devices are advertised. It does not retry permissions/rate limits or silently play on the Mac. Simulator UI explains the physical-iPhone requirement and omits the unusable Open Spotify button.

Ten additional automated checks cover late device advertisement, read-only recovery, return-to-app gating, repeated foreground events, failed URL opening, stale callbacks, cancellation, failed discovery and error classification. Both simulator and unsigned physical-iPhone builds pass. The recovery UI was checked with the offline `--song-sheet-preview --spotify-device-recovery-preview` fixture: its first check reports a mock Mac, its second a mock phone; Retry practice reaches the loaded practice setup. These fixture devices do not represent a real Spotify connection. The actual Spotify app-switch round trip still requires physical-device validation.
