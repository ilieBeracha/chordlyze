#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Usage: scripts/test_navigation_gestures.sh [artifact-directory]
# Choose a device with CHORDLYZE_TEST_DESTINATION='platform=iOS Simulator,id=…'.
# Limit a run with CHORDLYZE_ONLY_TESTING='NavigationGestureUITests/NavigationGestureUITests/testEdgeSwipePopsAndRunsCleanupOnce'.
# Run Spotify recovery only with CHORDLYZE_ONLY_TESTING='NavigationGestureUITests/SpotifyRecoveryUITests'.
# By default, create a disposable iPhone using an available device's type/runtime.
# Only that newly created simulator is cleaned up; an explicit destination is
# never shut down or deleted. This avoids replacing an app in the user's device.
# Only the DEBUG offline preview launches; no Spotify/backend session is needed.
command -v xcodegen >/dev/null || { echo 'Install XcodeGen before running the iPhone gesture tests.' >&2; exit 1; }
gesture_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/chordlyze-gesture-project.XXXXXX")
gesture_created_device=''
cleanup_gesture_test() {
    local gesture_exit_code=$?
    trap - EXIT
    if [[ -n "$gesture_created_device" ]]; then
        xcrun simctl shutdown "$gesture_created_device" >/dev/null 2>&1 || true
        if ! xcrun simctl delete "$gesture_created_device" >/dev/null 2>&1; then
            echo "Could not delete this run's temporary simulator: $gesture_created_device" >&2
        fi
    fi
    rm -rf "$gesture_test_dir"
    exit "$gesture_exit_code"
}
trap cleanup_gesture_test EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
gesture_artifacts=${1:-$(mktemp -d "${TMPDIR:-/tmp}/chordlyze-gesture-results.XXXXXX")}
mkdir -p "$gesture_artifacts"
gesture_artifacts=$(cd "$gesture_artifacts" && pwd)
if [[ -e "$gesture_artifacts/NavigationGestures.xcresult" ]]; then
    echo 'Choose a new artifact directory; an existing test result will not be overwritten.' >&2
    exit 1
fi

gesture_destination=${CHORDLYZE_TEST_DESTINATION:-}
if [[ -z "$gesture_destination" ]]; then
    gesture_template=$(xcrun simctl list devices available --json | python3 -c '
import json, re, sys
candidates = []
for runtime, devices in json.load(sys.stdin)["devices"].items():
    match = re.search(r"\.iOS-([0-9-]+)$", runtime)
    if not match:
        continue
    version = tuple(int(part) for part in match[1].split("-"))
    if version < (17,):
        continue
    for device in devices:
        device_type = device.get("deviceTypeIdentifier", "")
        if device.get("isAvailable") and ".iPhone-" in device_type:
            candidates.append((version, device_type, runtime))
if not candidates:
    sys.exit("Install an available iPhone simulator with iOS 17 or later in Xcode.")
_, device_type, runtime = max(candidates)
print(device_type + "\t" + runtime)
')
    IFS=$'\t' read -r gesture_device_type gesture_runtime <<< "$gesture_template"
    gesture_created_device=$(xcrun simctl create "Chordlyze gesture tests ${gesture_test_dir##*.}" "$gesture_device_type" "$gesture_runtime")
    gesture_destination="platform=iOS Simulator,id=$gesture_created_device"
fi
printf '%s\n' "$gesture_destination" > "$gesture_artifacts/destination.txt"

# Copy the app and its real dependency/settings spec: XcodeGen may rewrite the
# Info.plist, and must never change the production tree or tracked Xcode project.
cp project.yml "$gesture_test_dir/project.yml"
ditto Chordlyze "$gesture_test_dir/Chordlyze"
mkdir "$gesture_test_dir/tests"
cp tests/NavigationGestureUITests.swift tests/SpotifyRecoveryUITests.swift "$gesture_test_dir/tests/"
cat >> "$gesture_test_dir/project.yml" <<'YAML'
  NavigationGestureUITests:
    type: bundle.ui-testing
    platform: iOS
    sources: [tests/NavigationGestureUITests.swift, tests/SpotifyRecoveryUITests.swift]
    dependencies:
      - target: Chordlyze
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.ilieberacha.chordlyze.navigationgestures
        TEST_TARGET_NAME: Chordlyze
        GENERATE_INFOPLIST_FILE: YES
        SWIFT_VERSION: 5.9
        TARGETED_DEVICE_FAMILY: 1
schemes:
  Chordlyze:
    build:
      targets:
        Chordlyze: all
        NavigationGestureUITests: [test]
    test:
      targets: [NavigationGestureUITests]
      gatherCoverageData: false
YAML

xcodegen generate --spec "$gesture_test_dir/project.yml" --project "$gesture_test_dir"
gesture_test_options=(-test-timeouts-enabled YES -maximum-test-execution-time-allowance 60)
if [[ -n "${CHORDLYZE_ONLY_TESTING:-}" ]]; then
    gesture_test_options+=("-only-testing:$CHORDLYZE_ONLY_TESTING")
fi
xcodebuild test \
    -project "$gesture_test_dir/Chordlyze.xcodeproj" \
    -scheme Chordlyze -configuration Debug \
    -destination "$gesture_destination" \
    -derivedDataPath "$gesture_artifacts/DerivedData" \
    -resultBundlePath "$gesture_artifacts/NavigationGestures.xcresult" \
    -parallel-testing-enabled NO \
    "${gesture_test_options[@]}" \
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | tee "$gesture_artifacts/xcodebuild.log"
echo "iPhone gesture results: $gesture_artifacts/NavigationGestures.xcresult"
