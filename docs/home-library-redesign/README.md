# Home, Library, and Search

The redesign retains Chordlyze’s black surfaces, white text, and Spotify green actions. Home is organized around opening a song, finding another, and practicing. The shared catalog now belongs to Search; Library remains personal.

## Home

- The featured song is the most recently added personal song. “Open song” opens its existing shared song sheet.
- The upper background takes its color from the currently playing Spotify track’s artwork, using the existing cached `ArtworkColor` extractor. The wash fades into black within 540 points; cards and the rest of the page stay dark.
- When playback is idle, a random artwork from the latest eight recent songs supplies the wash. If recent covers are unavailable, the latest eight personal songs are used. The choice stays stable through refreshes while that cover remains in the candidate set. Missing artwork leaves a plain dark background.
- Reduce Motion disables the wash transition and press scaling. Reduce Transparency and Increase Contrast use a solid background.
- “Find a song,” “Practice,” and “See all” select their actual tabs. The latest local take links to its saved recording; it does not claim to restore a practice setup.
- Recent listening and the live mini-player retain their Spotify integrations. Collection failures preserve previously loaded personal songs and expose retry.

## Library

Library loads only `/library`, never `/catalog`. It includes songs this account requested, saved, or practiced. Text search matches title, artist, album, genre, and key; multiple words may match different fields. Easy and four-chord filters require known metadata. Sorting supports recently added, title, artist, and key; unknown fields sort last and ties keep their original order.

The empty state leads to Search. Liked songs and top tracks remain available under From Spotify. Saving/removing songs still uses the existing song-sheet bookmark; no analysis or save request happens merely by browsing.

## Search

Search loads shared ready charts from `/catalog` and searches the wider iTunes song catalog. The single query filters ready charts immediately and starts a cancellable 280 ms search. Submit and retry run immediately. New queries and clearing the field invalidate older responses. Network errors and empty responses are separate states.

Ready charts and additional songs are separate result sections. Only exact iTunes recording IDs suppress duplicate additional results; matching titles are not treated as proof that recordings share a chart. Album names help distinguish versions. Chart browsing keeps the existing artwork mosaics and genre, key, tempo, difficulty, and chord-count collections. “View all charts” also works for small catalogs with sparse metadata.

## Validation

```sh
bash scripts/test_music_collection.sh
bash scripts/test_song_sheet.sh
bash scripts/test_practice.sh
xcodebuild -project Chordlyze.xcodeproj -scheme Chordlyze \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/chordlyze-home-build CODE_SIGNING_ALLOWED=NO build
```

The collection/search suite covers 28 checks: personal/global isolation, multi-field filtering, missing metadata, stable sorting, refresh failure/recovery, stale responses, clearing queries, errors, and artwork selection. Existing song-sheet/playback tests pass 1,092 checks; practice feedback passes 23 checks, with take storage and report-contract suites also passing.

Debug-only `--music-preview` provides explicitly labeled, offline sample songs. Add `--music-library`, `--music-search`, `--music-empty`, `--music-error`, or `--music-large-type` for the corresponding state. Sample Home uses a labeled fixture wash; production Home always derives its wash from actual artwork. The preview does not require signing in or change real libraries.

Simulator interaction checks verified Home → Library tab selection, Easy filtering, and filtering combined with text search. Captures in this folder show the dark layouts using sample data. Live Spotify account playback and physical-device behavior were not exercised in this offline preview.
