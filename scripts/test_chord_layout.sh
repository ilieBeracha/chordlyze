#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
render_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/chordlyze-render-tests.XXXXXX")
trap 'rm -rf "$render_test_dir"' EXIT
# Compile the actual SwiftUI row and layout, not only the timing model.
# Override the two view paths to demonstrate a regression against older code.
row_view_source=${CHORD_ROW_VIEW_SOURCE:-Chordlyze/Views/ChordRowView.swift}
lyric_view_source=${CHORD_LYRIC_VIEW_SOURCE:-Chordlyze/Views/ChordLyricLine.swift}
extra_layout_source=${CHORD_EXTRA_LAYOUT_SOURCE:-}
swiftc -O -module-cache-path "$render_test_dir/module-cache" \
  Chordlyze/Chord.swift Chordlyze/ChordShapes.swift Chordlyze/ChordMath.swift \
  Chordlyze/BackendClient.swift Chordlyze/SheetModel.swift Chordlyze/PassageAnalysisModel.swift \
  Chordlyze/LyricPlayhead.swift Chordlyze/PracticeFeedback.swift Chordlyze/Theme.swift Chordlyze/NativeBackSwipe.swift \
  "$row_view_source" "$lyric_view_source" ${extra_layout_source:+"$extra_layout_source"} \
  tests/ChordRowRenderTests.swift -o "$render_test_dir/render-tests"
"$render_test_dir/render-tests" "${1:-/tmp/chordlyze-alignment-renders}"
