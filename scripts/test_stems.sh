#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
stem_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/chordlyze-stem-tests.XXXXXX")
trap 'rm -rf "$stem_test_dir"' EXIT
swiftc -module-cache-path "$stem_test_dir/module-cache" \
  Chordlyze/Chord.swift Chordlyze/ChordShapes.swift Chordlyze/ChordMath.swift Chordlyze/BackendClient.swift Chordlyze/SheetModel.swift Chordlyze/LyricPlayhead.swift \
  Chordlyze/SongSheetStore.swift Chordlyze/SpotifyAPI.swift Chordlyze/SpotifyNowPlaying.swift Chordlyze/StemPlayer.swift \
  tests/StemPlayerTests.swift -o "$stem_test_dir/stem-tests"
"$stem_test_dir/stem-tests"
