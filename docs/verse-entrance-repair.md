# Chord guidance at the vocal entrance

The reported failures have separate causes. The selected Spotify song can be
matched to an explicitly different recording edition; a speech transcript can
assign plausible but incorrect word intervals; and the sheet previously omitted
the chord continuing across a lyric boundary. Removing lyric highlighting does
not correct any of those inputs.

## Presentation

Lyrics keep a steady appearance. A measured vocal entrance can identify the
chord already sounding, without creating another chord event or practice attack.
Where a row has any unanchored changes, its complete chronological chord sequence
uses explicit timestamps instead of positions inferred from estimated words.
Wordless rows have neutral time captions, not invented verse or intro labels.

Completely unsynchronized lyrics display independently from the chord timeline.
Their fabricated catalog times cannot drive scrolling, lyric seeking, or a
practice passage. Current and next chord guidance remains available whenever
lyric timing is incomplete. An optional chord timeline preserves access to every
change; diagrams retain their existing explicit toggle and collapsed default.

## Recording and lyric evidence

The recording selector requires declared edition markers to match in both
directions, including `stripped`. Matching artist, title and duration remains a
candidate filter, not proof that two recordings have identical audio.

Lyric retries reuse the saved recording source. A Bandcamp recording can be
retried without an ISRC; a YouTube recording retains its video ID. Missing,
invalid or unavailable provenance does not start another source search. The
existing decoded-audio fingerprint check still runs before lyric alignment.

Reviewed artist lyrics retain their source URL, complete ordered-text fingerprint
and recording identity. Reading the chart or retrying its timing cannot replace
that text with an older catalog entry. Timing retries preserve this provenance
only while the recording and complete lyric text still match the review.

Large catalog/transcript onset disagreements trigger a bounded acoustic review
only when at least three nearby measured entrances corroborate a recording
offset. Catalog time never becomes a measured word timestamp. Recovery requires
matching text, confident recovered words, and agreeing retained anchors. If the
audio confirms the original sustained singing, its timing remains unchanged.
Unresolved prefixes preserve their source stamps as uncertain evidence.

Explicitly estimated, low-confidence or invalid-duration recognition cannot
become a measured anchor through either alignment or recovery. Healthy suffix words, other lyric
lines, and chord timestamps are preserved by a local lyric repair.

## Existing songs

The reported Love Again chart used an explicitly Stripped source. Its first
lyric was stored at 30 seconds; the synchronized catalog and the user's playback
observation place it near 36 seconds. Independent local recognition of both the
archived source and the artist's regular recording confirms the early-prefix
problem, without claiming millisecond acoustic certainty.

Snake With a Bone had only unsynchronized catalog lyrics. Their character-based
distribution started well before the observed singing. Those guesses no longer
create timed chord associations in the sheet.

Code deployment alone cannot replace either saved chart. Recording-dependent
data is prepared locally and reviewed separately. The
[replacement procedure](reviewed-recording-replacement.md) backs up each affected
file, checks the chart and complete write plan for concurrent changes, preserves
personal corrections, and binds unbound legacy calibration to the old recording
so it cannot silently apply to new audio. A guarded restore is available.

No production replacement is implied by the existence of a local proposal.
Actual phone playback remains the final check for latency, calibration and
musical accuracy; automated tests establish internal behavior and safeguards.

## Regression checks

- Real SwiftUI renders cover narrow widths, wrapping, transposition, held chords,
  mixed word confidence and independent lyrics/current-next guidance.
- Model checks preserve each actual chord event exactly once.
- Backend checks cover both directions of edition mismatch, pinned lyric retry
  sources, low-confidence evidence, outlier entrances, legitimate sustained words,
  bounded recognition, stale replacement plans, backups and interrupted restore.
- Reviewed artist text survives cached catalog reads and future timing retries;
  a changed recording, source URL or lyric fingerprint invalidates its authority.

Private song recordings and full lyric proposals remain outside the repository.
