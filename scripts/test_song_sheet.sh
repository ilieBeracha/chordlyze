#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
song_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/chordlyze-song-tests.XXXXXX")
trap 'rm -rf "$song_test_dir"' EXIT
swiftc -O -module-cache-path "$song_test_dir/module-cache" \
  Chordlyze/Chord.swift Chordlyze/ChordShapes.swift Chordlyze/ChordMath.swift Chordlyze/BackendClient.swift Chordlyze/SheetModel.swift Chordlyze/LyricPlayhead.swift \
  Chordlyze/SongSheetStore.swift Chordlyze/SpotifyAPI.swift Chordlyze/SpotifyNowPlaying.swift \
  tests/SongSheetTests.swift -o "$song_test_dir/song-tests"
"$song_test_dir/song-tests"
