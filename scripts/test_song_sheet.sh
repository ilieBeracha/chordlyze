#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
song_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/chordlyze-song-tests.XXXXXX")
trap 'rm -rf "$song_test_dir"' EXIT
swiftc -O -module-cache-path "$song_test_dir/module-cache" \
  Chordlyze/Chord.swift Chordlyze/ChordShapes.swift Chordlyze/ChordMath.swift Chordlyze/BackendClient.swift Chordlyze/SheetModel.swift Chordlyze/LyricPlayhead.swift \
  Chordlyze/PassageAnalysisModel.swift Chordlyze/SongSheetStore.swift Chordlyze/SpotifyAPI.swift Chordlyze/SpotifyNowPlaying.swift Chordlyze/SpotifyLaunchCallback.swift Chordlyze/SpotifyNativeSession.swift \
  tests/SongSheetTests.swift -o "$song_test_dir/song-tests"
"$song_test_dir/song-tests"

# Guard the actual views as well as the data model. The standalone render
# command can be used to keep PNGs for visual review.
bash scripts/test_chord_layout.sh "$song_test_dir/rendered-rows"
