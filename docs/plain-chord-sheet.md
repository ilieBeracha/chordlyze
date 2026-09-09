# Plain chord sheet — 9 September 2026

The sheet uses conventional chord-over-lyric notation. A passage-opening chord may be repeated as a plain symbol for reading; subsequent lines and screen-width wraps show only actual changes. A lead-in of at most two seconds containing only that same opening chord is folded into the first lyric row; longer intros and progressions stay visible. Wrapped lines without chord changes reserve no empty chord band; words in the same visual row keep a shared baseline. The playback and practice timelines remain unchanged. No per-line explanatory captions or pre-play first-chord summary are added. The Developer tools feature remains available in Song settings.

The comparison included the user's Ultimate Guitar screenshots for High No More and Silver Lining, the official [ChordPro chord-over-lyric example](https://www.chordpro.org/chordpro/chords-over-lyrics/), and the artist-published [Amazing Grace chart](https://www.reawakenhymns.com/amazinggrace). The examples support plain opening chords and sparse subsequent changes. They are presentation references, not replacement transcriptions or evidence that our saved song data matches those arrangements.

The authored offline fixtures reproduce the two reported layouts without embedding additional song lyrics or requesting production data. Launch the Debug simulator with `--song-sheet-preview --plain-chords-preview`. Regression checks cover initial held chords, actual changes on the first word, ordinary subsequent lines, repeated phrases, instrumental re-entry, mixed/line-only timing, uncertain onsets, transposition, playback highlights, and multi-row wrapping.

Run `bash scripts/test_song_sheet.sh` for the model/playback and actual SwiftUI rendering checks. Build the Debug simulator and Release iPhone targets to verify app integration. This is an iPhone presentation change; no backend deployment, analysis-generation change, or saved-song migration is required.

## Validation

- 2,720 model/playback checks passed on the final model and store sources.
- 380 actual SwiftUI rendering checks passed, producing 89 retained PNGs. New cases cover 280, 320, 375.5, 390, 430.5 and 464-point widths, both row styles, transposition, glyph visibility, overlap, compact wraps and practice verdicts.
- Debug Simulator and unsigned Release iPhone builds passed; all 51 production Swift source hashes remained unchanged during these final builds.
- Independent review verified the display-only opening notation, long-intro preservation, and scrolling to folded lead-ins.
- Simulator previews use authored offline sample data. They validate layout, not the musical accuracy of any saved song.
