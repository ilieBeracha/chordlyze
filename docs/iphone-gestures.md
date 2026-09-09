# iPhone navigation gestures

Custom song, library, search, profile, and practice headers support the native
edge swipe to go back. Start at the leading edge of the screen (the left edge
in English), drag to preview the previous page, and release to complete or
cancel the transition. The existing Back buttons remain available.

Song settings, the song map, and chord diagrams use native swipe-down sheet
dismissal and show a drag handle. Correction editors continue to prevent
dismissal while a save is in progress.

Swipe-back is disabled during practice startup/count-in/recording and active
chord drills. Explicit cancel, stop, and back controls keep their existing
behavior, including saving an interrupted practice take.

## Implementation

`NativeBackSwipe` attaches to custom back controls and uses their containing
navigation controller's existing edge recognizer. UIKit still handles the
interactive animation, direction, completion, and cancellation. There is no
full-screen drag handler competing with lyrics, chord rails, or sliders.

One scoped owner per navigation controller tracks weak registrations, checks
the current navigation entry, and forwards unaffected delegate methods. It
restores the original delegate when the current page has no custom back
control or uses a visible system navigation bar. Root, presentation, and
transition checks prevent invalid pops. The helper is a no-op in the macOS
standalone layout test build.

## Verification

Run `bash scripts/test_navigation_gestures.sh /tmp/chordlyze-gesture-results`.
By default the runner creates its own iPhone simulator and deletes it after
the run. Set `CHORDLYZE_TEST_DESTINATION` to use a particular simulator, which
the runner leaves intact. It creates a temporary Xcode project from the real app sources and runs
the DEBUG-only offline preview; it does not use an account or contact Spotify.
Test results and failure screenshots remain in the chosen output directory.

The UI suite covers completed and cancelled edge swipes, cleanup only after
departure, repeated nested navigation, swipes at the root, vertical scrolling,
sheet dismissal, visible system navigation bars, and the active-operation
gesture lock with button escape and restoration after unlocking.
XCTest cancellation uses a slow, short drag with a hold before release. Also
check a finger reversal by hand when reviewing the interaction on a device.

Apple API references:
- [Native back gesture](https://developer.apple.com/documentation/uikit/uinavigationcontroller/interactivepopgesturerecognizer)
- [Sheet dismissal](https://developer.apple.com/documentation/swiftui/view/interactivedismissdisabled(_:))
