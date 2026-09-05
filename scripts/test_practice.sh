#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
practice_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/chordlyze-practice-tests.XXXXXX")
trap 'rm -rf "$practice_test_dir"' EXIT
swiftc -module-cache-path "$practice_test_dir/module-cache" \
  Chordlyze/Chord.swift Chordlyze/BackendClient.swift Chordlyze/PracticeTakeStore.swift \
  tests/PracticeTakeTests.swift -o "$practice_test_dir/takes"
"$practice_test_dir/takes"
swiftc -module-cache-path "$practice_test_dir/module-cache" \
  Chordlyze/Chord.swift Chordlyze/BackendClient.swift \
  tests/PracticeReportContract.swift -o "$practice_test_dir/report"
"$practice_test_dir/report"
