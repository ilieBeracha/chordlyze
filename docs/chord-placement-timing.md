# Chord placement and lyric timing

Chord events remain the authority for playback. The sheet preserves measured chord starts and ends, without snapping them to nearby beats. The beat grid is retained for navigation and metronome timing. Song calibration maps the recording to Spotify once; the old global display lead is no longer applied. Negative calibrated time remains before the opening chord. Lyric wrapping never rewrites a chord onset, duration, label or order. The progression strip stays outside the lyric scroll view. During N.C. or before the recording begins, a future shape is marked NEXT rather than playing.

The sheet uses plain chord names above lyrics, with compact, consistent spacing. Reliable word timestamps can place a change above a sung word or a phrase it anticipates by at most 350 ms. If any change has no supported word anchor, the row keeps its changes in a separate chronological chord line. Cells wrap with their associated words, and oversized cells wrap within the viewport. Layout measurement and placement use the same proposed width, including fractional widths.

At the first vocal passage, or after a measured chord-bearing instrumental break of at least three seconds, the sounding chord can appear above the first word as a plain chord. Ordinary following lyric rows and visual wraps do not repeat it. This opening notation references the original event and gets no practice verdict or new scoring target. A supported word onset or synchronized line onset is required; an explicitly estimated first word cannot establish the entrance. It adds no explanatory caption. The ordinary sheet has no separate first-chord display or per-chord timestamps; exact timestamps remain in the explicitly opened independent chord timeline.

Lyrics stay at a constant readable brightness. Only the sounding chord becomes bright green, with no color-transition delay, lyric glow, or moving cursor. Automatic scrolling follows measured vocal intervals and actual instrumental rows; guessed catalog positions do not advance the lyric page. Completely unsynchronized lyrics retain separate current/next guidance during playback; partial word timing does not add another chord summary above a timed sheet. The page offers an explicit Sync lyrics action when needed.

## Estimated words and measured rests

Words interpolated by the recording aligner carry optional `estimated: true`. Heard onsets without an end carry `estimated: false`; ordinary measured spans retain their existing payload. The worker sanitizer and API preserve this optional field, so older clients and payloads remain readable.

An estimated onset cannot anchor a chord or drive vocal auto-follow. Auto-follow requires a measured start and positive measured end, and stops at the exact end of a word; a missing end does not imply a held vocal. Splitting a phrase requires a measured end for the preceding word and a measured onset for the following word. Unknown ends no longer manufacture a one-second vocal duration or an instrumental tail. Enhanced LRC without word ends remains usable for placement but does not establish silence. Genuine measured rests and explicit blank LRC lines retain their behavior.

Existing aligned and transcribed charts with a mix of heard word ends and missing ends get estimate flags on read, even if their catalog cache is unavailable. Completely onset-only sources are not reclassified. Explicit provenance is preserved. The repair copies the response, leaves shared cache bytes and chord revisions unchanged, and is idempotent. Its completeness version is 3. Catalog text never replaces a transcription-only chart through this read path.

## Malformed saved timing

The inspected Shadows chart placed its first lyric at 0:00 and stretched a single word for 25.62 seconds. Its synchronized catalog places that phrase at 28.38 seconds. This is a timing fault, not evidence that its musical chord sequence should be replaced with a repeating pattern.

Transcript word spans over eight seconds, reversed spans and nonfinite/unordered timestamps decline word precision. This is a conservative precision limit, not a claim that sustained notes cannot be longer. With a synchronized catalog, the backend restores the affected line timestamp and uses a local offset only when at least three nearby valid alignments agree within one second of their median. On the inspected Shadows data, the resulting approximate opening timestamp is 28.225 seconds. All 33 nonblank lyric lines remain.

Song and track-analysis reads repair existing aligned responses from the cached catalog; no provider calls, reanalysis, chart revision changes, or persistent chart writes are needed. Missing or unreadable catalogs leave the chart available. Unsynchronized catalogs cannot supply a recovered vocal onset. Approximate lines retain the existing timing note. This improves placement; it does not establish the acoustic accuracy of every recognized chord.

### Recordings without a lyric catalog

The approved The Push payload has `matched: transcribed`, no cached catalog, and a word spanning 3.36–20.14 seconds. The former catalog-only repair never reached it. The invalid span caused the client to fall back to a line beginning at zero, displaying six instrumental changes with the first vocal phrase.

Both raw transcription paths now retry malformed phrases using the bundled local speech model. There are at most three crops per song, each at most 30 seconds, with a 120-second transcription timeout. Healthy transcripts perform no extra work and no extra paid provider request is made. A recovered phrase must match the same normalized words exactly once, contain valid spans, and agree with at least two subsequent healthy anchors (at least 75% of them, within 750 ms). A candidate pinned to the crop boundary, missing text, poor confidence, conflicting order, or a failed retry is rejected. Existing healthy suffix timestamps are retained exactly; only the damaged prefix is replaced. This is acoustic recovery, not interpolated replacement timestamps.

Existing transcriptions require the analyzed recording to recover missing timing. `scripts/repair_lyrics_from_audio.py` verifies its decoded PCM SHA-256 with the same decoder as analysis. It defaults to a dry run. With `--apply`, it checks that the chart has not changed during verification, saves backups, and atomically replaces only the lyrics in the chart and any unchanged matching ISRC alias. Chords, corrections and chart revisions remain intact. A mismatched recording or unavailable timing evidence never produces a guessed repair.

```sh
python scripts/repair_lyrics_from_audio.py \
  --cache /data/analysis_cache --track-id TRACK_ID --audio /tmp/verified-recording.wav
```

On The Push's verified recording, the opening is recovered at 18.600 seconds. Only the first two word stamps change; the remaining words, all 37 lines, and all 65 chord events are retained. This does not establish perfect transcription accuracy for every song or every possible malformed span. Cases without enough acoustic evidence continue to decline word precision.

## Validation

- `bash scripts/test_song_sheet.sh`: event preservation across vocal boundaries, intro/rest separation, word-end boundaries, line-only fallback, malformed spans, and linear chord-cursor movement, plus existing sheet/playback regressions.
- `bash scripts/test_chord_layout.sh`: compiles the actual SwiftUI row, chip and layout. It renders four widths, both styles, transposition, playback states, RTL, line-only fallback and oversized content. Pixel checks verify that chords remain above their associated words after wrapping, and that every authored word/change appears. It saves reviewable PNGs under `/tmp/chordlyze-alignment-renders` by default.
- Backend lyric, repair, analysis-version, HTTP, correction and boundary suites: old-chart repair is idempotent and leaves saved chart bytes and musical revisions intact.
- `backend/tests/test_lyrics_timing.py`: both transcription providers, no work for healthy timing, rejected conflicting text/anchors, retry limits/timeouts, recording identity, dry run, backups, concurrent chart changes, alias preservation and idempotence. The render suite also covers the recovered no-catalog intro at four widths using authored words.
- Debug simulator build and offline visual playback fixture: `--song-sheet-preview --independent-chords-preview --song-sheet-preview-playing -chordRail YES`. Add `--independent-chords-vocal` to start at the opening vocal. The fixture uses authored sample words and the reported timing geometry; it does not request real audio.
- Mixed timing regression fixture: `--song-sheet-preview --mixed-word-timing-preview`. This uses the reported Shadows timing geometry with authored replacement words and estimate flags. It exercises the actual song page, including phrase spacing.

On-device playback against the source recording remains the final check of perceived musical alignment. No new TestFlight build is implied by simulator verification.

For existing charts, run `python scripts/audit_lyrics_timing.py --cache /data/analysis_cache --fail-on-invalid` before making an all-song acceptance claim. It returns aggregate before/after counts without lyrics or song identities and fails when structurally invalid timing remains. A clean audit still requires representative acoustic checks: valid timestamps alone cannot prove that words were recognized at the correct moment. The initial whole-cache audit still flags additional charts after read repair, so the current correction is not an all-song repair of saved timing data.
