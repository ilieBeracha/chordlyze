#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
music_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/chordlyze-music-tests.XXXXXX")
trap 'rm -rf "$music_test_dir"' EXIT
swiftc -module-cache-path "$music_test_dir/module-cache" \
  Chordlyze/Chord.swift Chordlyze/SheetModel.swift Chordlyze/BackendClient.swift \
  Chordlyze/MusicCollection.swift tests/MusicCollectionTests.swift -o "$music_test_dir/music-tests"
"$music_test_dir/music-tests"
