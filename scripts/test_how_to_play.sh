#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
how_to_play_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/chordlyze-how-to-play-tests.XXXXXX")
trap 'rm -rf "$how_to_play_test_dir"' EXIT
swiftc -module-cache-path "$how_to_play_test_dir/module-cache" \
  Chordlyze/Chord.swift Chordlyze/ChordShapes.swift Chordlyze/SheetModel.swift Chordlyze/BackendClient.swift \
  Chordlyze/SongTab.swift Chordlyze/ChordMath.swift Chordlyze/HowToPlay.swift tests/HowToPlayTests.swift -o "$how_to_play_test_dir/how-to-play-tests"
"$how_to_play_test_dir/how-to-play-tests"
