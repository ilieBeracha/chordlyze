#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tab_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/chordlyze-song-tab-tests.XXXXXX")
trap 'rm -rf "$tab_test_dir"' EXIT
swiftc -module-cache-path "$tab_test_dir/module-cache" \
  Chordlyze/Chord.swift Chordlyze/SongTab.swift tests/SongTabTests.swift -o "$tab_test_dir/song-tab-tests"
"$tab_test_dir/song-tab-tests"
