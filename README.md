# Chordlyze

iOS app: connect Spotify, browse playlists, see the chords + progression analysis of each song.

## How it works

- **iOS app** (`ios/`) — SwiftUI. Spotify OAuth (PKCE), playlist/track browsing via Spotify Web API, chord timeline + Roman-numeral progression view.
- **Backend** (`backend/`) — FastAPI + madmom CNN chord recognition (CRF-decoded, maj/min vocabulary) + key detection + Roman-numeral analysis. Results cached by audio content hash.
- **Audio reality check**: Spotify's API provides *no audio* (DRM) and no chord data. Analysis runs on audio files you supply per track (your own recordings/purchases), uploaded from the app's track screen.

## Backend

```bash
cd backend
uv venv --python 3.11 .venv          # once
uv pip install -p .venv numpy scipy cython soundfile librosa fastapi "uvicorn[standard]" pytest python-multipart "madmom @ git+https://github.com/CPJKU/madmom.git"
PYTHONPATH=. .venv/bin/uvicorn chordlyze_backend.main:app --port 8787
```

Requires `ffmpeg` on PATH (any input format → mono 44.1 kHz internally).

### Verify the engine really works

```bash
cd backend && PYTHONPATH=. .venv/bin/python -m pytest tests/ -q
```

Tests synthesize audio with known progressions (C–F–G–C, Am–F–C–G, Am–G–F–Am), run the full pipeline, and assert exact chord labels, key, and Roman numerals.

## iOS app

1. Register an app at <https://developer.spotify.com/dashboard>:
   - Redirect URI: `chordlyze://callback`
   - Copy the Client ID into `Config.spotifyClientID` in `ios/Chordlyze/ChordlyzeApp.swift`.
2. Generate + open:
   ```bash
   cd ios && xcodegen generate && open Chordlyze.xcodeproj
   ```
3. Running on a physical device: set `Config.backendBaseURL` to your Mac's LAN IP.

## TestFlight

1. Enroll in the Apple Developer Program ($99/yr) — developer.apple.com.
2. In Xcode: Signing & Capabilities → select your team (bundle id `com.ilieberacha.chordlyze`).
3. Create the app record in App Store Connect with that bundle id.
4. Product → Archive → Distribute App → TestFlight & App Store.
5. App Store Connect → TestFlight: internal testers get builds immediately; external testers require a short beta review.
6. Note: the backend must be reachable from testers' devices — deploy `backend/` to a server (Fly.io/Railway/EC2; CPU-only is fine) and update `Config.backendBaseURL` before archiving.

## Analysis JSON shape

```json
{
  "key": "A minor",
  "key_confidence": 0.19,
  "chords": [
    {"start": 13.0, "end": 14.3, "label": "A:min", "roman": "i"}
  ]
}
```

`label` uses madmom notation (`C:maj`, `A:min`, `N` = no chord).
