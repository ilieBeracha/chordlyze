# Chord placement and lyric timing

Chord events remain the authority for playback. The sheet uses the existing beat grid, calibration and display lead; lyric wrapping never rewrites a chord's onset, duration, label or order. The progression strip stays outside the lyric scroll view. During N.C. the first future shape is marked NEXT rather than playing.

The existing typography, colors and compact flow are retained. Reliable word timestamps can place a change above a sung word or a phrase it anticipates by at most 350 ms. A change between timed words has its own blank lyric cell; it does not detach other chords from their words. Cells wrap with their associated words, and oversized cells wrap within the viewport. A held chord is not repeated as a new attack at the next phrase. When only line timing is available, changes keep their chronological order in a separate chord line. No extra timestamps or instrumental labels are added. The chord cursor interpolates linearly between actual chord onsets, including mixed rows; lyric glows continue using vocal timestamps independently.

## Estimated words and measured rests

Words interpolated by the recording aligner carry optional `estimated: true`. Heard onsets without an end carry `estimated: false`; ordinary measured spans retain their existing payload. The worker sanitizer and API preserve this optional field, so older clients and payloads remain readable.

An estimated onset cannot anchor a chord. Splitting a phrase requires a measured end for the preceding word and a measured onset for the following word. Unknown ends no longer manufacture a one-second vocal duration or an instrumental tail. Enhanced LRC without word ends remains usable for placement but does not establish silence. Genuine measured rests and explicit blank LRC lines retain their behavior.

Existing recording-aligned charts with a mix of heard word ends and missing ends get estimate flags on read, even if their catalog cache is unavailable. Completely onset-only sources are not reclassified. Explicit provenance is preserved. The repair copies the response, leaves shared cache bytes and chord revisions unchanged, and is idempotent. Its completeness version is 3.

## Malformed saved timing

The inspected Shadows chart placed its first lyric at 0:00 and stretched a single word for 25.62 seconds. Its synchronized catalog places that phrase at 28.38 seconds. This is a timing fault, not evidence that its musical chord sequence should be replaced with a repeating pattern.

Transcript word spans over eight seconds, reversed spans and nonfinite/unordered timestamps decline word precision. This is a conservative precision limit, not a claim that sustained notes cannot be longer. With a synchronized catalog, the backend restores the affected line timestamp and uses a local offset only when at least three nearby valid alignments agree within one second of their median. On the inspected Shadows data, the resulting approximate opening timestamp is 28.225 seconds. All 33 nonblank lyric lines remain.

Song and track-analysis reads repair existing aligned responses from the cached catalog; no provider calls, reanalysis, chart revision changes, or persistent chart writes are needed. Missing or unreadable catalogs leave the chart available. Unsynchronized catalogs cannot supply a recovered vocal onset. Approximate lines retain the existing timing note. This improves placement; it does not establish the acoustic accuracy of every recognized chord.

## Validation

- `bash scripts/test_song_sheet.sh`: event preservation across vocal boundaries, intro/rest separation, word-end boundaries, line-only fallback, malformed spans, and linear chord-cursor movement, plus existing sheet/playback regressions.
- `bash scripts/test_chord_layout.sh`: compiles the actual SwiftUI row, chip and layout. It renders four widths, both styles, transposition, playback states, RTL, line-only fallback and oversized content. Pixel checks verify that chords remain above their associated words after wrapping, and that every authored word/change appears. It saves reviewable PNGs under `/tmp/chordlyze-alignment-renders` by default.
- Backend lyric, repair, analysis-version, HTTP, correction and boundary suites: old-chart repair is idempotent and leaves saved chart bytes and musical revisions intact.
- Debug simulator build and offline visual playback fixture: `--song-sheet-preview --independent-chords-preview --song-sheet-preview-playing -chordRail YES`. Add `--independent-chords-vocal` to start at the opening vocal. The fixture uses authored sample words and the reported timing geometry; it does not request real audio.
- Mixed timing regression fixture: `--song-sheet-preview --mixed-word-timing-preview`. This uses the reported Shadows timing geometry with authored replacement words and estimate flags. It exercises the actual song page, including phrase spacing.

On-device playback against the source recording remains the final check of perceived musical alignment. No new TestFlight build is implied by simulator verification.
