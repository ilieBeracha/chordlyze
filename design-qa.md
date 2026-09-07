# Practice setup design QA

final result: passed

## Source and evidence

Selected source: `/Users/ilieberacha/.codex/generated_images/01a07b76-b309-7d60-95c1-39d9f48a052e/exec-b2250da0-066c-41ee-b680-ba8c794a16ae.png` (850 × 1850 pixels). User explicitly selected the first design without imagery or a gradient.

Implementation: `docs/practice-setup-redesign/setup.jpg` (408 × 892 native Simulator window capture); additional states in `large-text.jpg` and `large-text-details.jpg`. Captured with CUA on the booted iPhone simulator. This is a native SwiftUI app, not a browser prototype; CSS viewport/density do not apply. The simulator window includes device and OS chrome, excluded from the visual assessment. The source is app content only. Source and implementation were opened together in one comparison input, comparing equivalent app-content regions at their respective display scales. This is a structural/native adaptation review, not a pixel-difference assertion.

State: Spotify mode, whole song, recording enabled, illustrative song title. The source depicts connected headphones and active microphone. The simulator reports a speaker and an unchecked microphone; these intentional data differences are retained rather than displaying false ready checks. A separate microphone-check interaction confirmed input route and live level updates.

## Comparison history

- P2: Initial vertical spacing pushed the timing control below the first viewport. Reduced section/row gaps; final normal-size capture shows song, modes, passage, recording, audio, timing, and Start together.
- P2: A scrolling custom header could slide behind the status area. Moved the navigation header into a fixed safe-area inset; final capture shows it clearly below OS chrome.
- P2: Metronome broke across characters at accessibility3. Mode controls now stack vertically at accessibility sizes. Post-fix `large-text.jpg` shows full labels; `large-text-details.jpg` shows the lower input/timing actions and persistent Start button.
- Debug fixture issue: Direct setup initially compared revisionless chart data with a later versioned response. Initialized that fixture with its versioned status analysis. Final captures open normally.

## Required fidelity surfaces

- Typography: native dynamic SF text with the selected hierarchy: modest Practice navigation, bold song title, subdued section labels, readable control names and secondary values. Large text wraps and scrolls; mode names remain intact.
- Spacing/layout: flat separated rows, circular icons, consistent 24-point horizontal margins, grouped mode control, fixed green primary action. Denser than the image's app-only canvas to accommodate real iOS safe areas and controls.
- Colors/tokens: black background; existing charcoal surfaces and secondary grays; solid existing Spotify green accent. No artwork or background gradients.
- Assets: standard SF Symbols for native controls. No album imagery. Music-note source label replaces the mock's illustrative Spotify mark using the app's existing native icon language.
- Copy: retained the source's short labels. Real route/microphone states replace sample ready indicators. The footer explicitly mentions scoring upload because the existing finish flow uploads a take; details remain accessible before starting.

Full-view captures were readable enough to inspect the header, row text, separators, modes and primary action without fabricated image crops. Large-text lower controls were captured separately to inspect action wrapping. No actionable P0/P1/P2 visual findings remain in the checked states.

## Interaction and build checks

Passage selection and summary update; microphone check and stop; recording off/play-along; metronome selection and pace controls; direct synchronization navigation; recording disclosure. Simulator and physical-iPhone target builds passed. Practice regression suite and Spotify transport/authentication checks passed. See `docs/practice-setup-redesign/README.md` for details.

## Limits

Actual phone Bluetooth route selection, live Spotify playback, and a full VoiceOver walkthrough were not performed in this UI pass. CUA pointer scrolling returned a window error; accessibility activation successfully brought lower controls into view and allowed their interaction. No claim of comprehensive accessibility compliance or new TestFlight availability.
