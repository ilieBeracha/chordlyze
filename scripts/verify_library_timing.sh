#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
library_probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/chordlyze-library-probe.XXXXXX")
trap 'rm -rf "$library_probe_dir"' EXIT
swiftc -O -module-cache-path "$library_probe_dir/module-cache" \
  Chordlyze/Chord.swift Chordlyze/ChordShapes.swift Chordlyze/ChordMath.swift \
  Chordlyze/BackendClient.swift Chordlyze/SheetModel.swift Chordlyze/PassageAnalysisModel.swift \
  tests/LibraryTimingProbe.swift -o "$library_probe_dir/probe"
"$library_probe_dir/probe" "$1"
