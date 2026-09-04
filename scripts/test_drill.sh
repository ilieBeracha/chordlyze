#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
drill_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/chordlyze-drill-tests.XXXXXX")
trap 'rm -rf "$drill_test_dir"' EXIT
swiftc -O -module-cache-path "$drill_test_dir/module-cache" \
  Chordlyze/Chord.swift Chordlyze/ChordDrillDetector.swift \
  tests/support/LegacyDrillDetector.swift tests/DrillDetectorTests.swift \
  -o "$drill_test_dir/detector"
"$drill_test_dir/detector"
swiftc -O -module-cache-path "$drill_test_dir/module-cache" \
  Chordlyze/Chord.swift Chordlyze/ChordDrillDetector.swift Chordlyze/DrillAudioWorker.swift \
  tests/DrillAudioWorkerTests.swift -o "$drill_test_dir/worker"
"$drill_test_dir/worker"
swiftc -O -module-cache-path "$drill_test_dir/module-cache" \
  Chordlyze/Chord.swift Chordlyze/ChordDrillDetector.swift tests/DrillInputFormatTests.swift \
  -o "$drill_test_dir/formats"
"$drill_test_dir/formats"
python3 -m unittest discover -s tests -p 'test_drill_benchmark.py' -v
