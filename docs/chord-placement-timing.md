# Chord placement and lyric timing

Chord events remain the authority for playback. The sheet uses the existing beat grid, calibration and display lead; lyric wrapping never rewrites a chord's onset, duration, label or order. The progression strip stays outside the lyric scroll view. During N.C. the first future shape is marked NEXT rather than playing.

The existing typography, colors and compact flow are retained. Reliable word timestamps can place a change above a sung word or a phrase it anticipates by at most 350 ms. Changes in a rest stay independent, and a held chord is not repeated as a new attack at the next phrase. Without reliable word timing, changes keep their chronological order in a separate chord line. No extra timestamps or instrumental labels are added. Its cursor interpolates linearly between actual chord onsets; lyric glows continue using vocal timestamps independently.

## Malformed saved timing

The inspected Shadows chart placed its first lyric at 0:00 and stretched a single word for 25.62 seconds. Its synchronized catalog places that phrase at 28.38 seconds. This is a timing fault, not evidence that its musical chord sequence should be replaced with a repeating pattern.

Transcript word spans over eight seconds, reversed spans and nonfinite/unordered timestamps decline word precision. This is a conservative precision limit, not a claim that sustained notes cannot be longer. With a synchronized catalog, the backend restores the affected line timestamp and uses a local offset only when at least three nearby valid alignments agree within one second of their median. On the inspected Shadows data, the resulting approximate opening timestamp is 28.225 seconds. All 33 nonblank lyric lines remain.

Song and track-analysis reads repair existing aligned responses from the cached catalog; no provider calls, reanalysis, chart revision changes, or persistent chart writes are needed. Missing or unreadable catalogs leave the chart available. Unsynchronized catalogs cannot supply a recovered vocal onset. Approximate lines retain the existing timing note. This improves placement; it does not establish the acoustic accuracy of every recognized chord.

## Validation

- `bash scripts/test_song_sheet.sh`: event preservation across vocal boundaries, intro/rest separation, word-end boundaries, line-only fallback, malformed spans, and linear chord-cursor movement, plus existing sheet/playback regressions.
- Backend lyric, repair, analysis-version, HTTP, correction and boundary suites: old-chart repair is idempotent and leaves saved chart bytes and musical revisions intact.
- Debug simulator build and offline visual playback fixture: `--song-sheet-preview --independent-chords-preview --song-sheet-preview-playing -chordRail YES`. Add `--independent-chords-vocal` to start at the opening vocal. The fixture uses authored sample words and the reported timing geometry; it does not request real audio.

On-device playback against the source recording remains the final check of perceived musical alignment. No new TestFlight build is implied by simulator verification.
