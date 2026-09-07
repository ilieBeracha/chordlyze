#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
spotify_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/chordlyze-spotify-tests.XXXXXX")
trap 'rm -rf "$spotify_test_dir"' EXIT
swiftc -module-cache-path "$spotify_test_dir/module-cache" \
  Chordlyze/Keychain.swift Chordlyze/SpotifyAuth.swift Chordlyze/SpotifyAPI.swift \
  tests/SpotifyTransportTests.swift -o "$spotify_test_dir/spotify-tests"
"$spotify_test_dir/spotify-tests"
