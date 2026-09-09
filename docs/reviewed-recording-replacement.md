# Replace a reviewed recording without discarding saved work

`backend/scripts/replace_reviewed_chart.py` is a local administrative tool for one
explicitly reviewed song. It does not call providers, download audio, queue jobs,
reset the library, or delete accounts. Its default operation is a dry run.
Production use requires approval of the concrete song candidates and affected
file counts. Existing local archives can prepare a proposal; a mismatch against
the current chart must stop the operation, not be bypassed.

## Prepare and review

Create a private JSON proposal with `track_id`, `expected_before_sha256`,
`expected_audio_sha256`, and `replacement`. The first fingerprint is SHA256 of
the **current chart object**, encoded as UTF-8 using
`json.dumps(chart, sort_keys=True, ensure_ascii=False, separators=(',', ':'),
allow_nan=False)`. This supports an approved fingerprint-only diagnostic without
exporting a production chart. The second fingerprint identifies the currently
saved decoded PCM recording. Neither fingerprint certifies musical correctness.

The replacement contains the complete current ISMIR analysis, reviewed HTTPS
recording provenance, and recording-aligned lyrics. The lyrics must carry the
same `audio_sha256` and `audio_duration` as the replacement and preserve every
previously saved word occurrence in order. At least one word needs a measured
start and end; uncertain portions must retain their estimated flags. Review
coverage separately before approval: a valid payload can still be only partially
timed. Chart and lyric measurement must use the same verified recording.

The script validates the source title, artist, declared edition, exact supported
provider URL, duration, model version, continuous full-song
chord coverage, rhythmic data, and lyric compatibility. It derives chart display
fields again from the replacement chord labels. Requested metadata and the
existing library generation remain intact. A Bandcamp recording is supported.
Lyric line times must be ordered and within the recording. Unreliable word
geometry is preserved as evidence and explicitly marked estimated.

From the backend directory, using its existing Python environment:

```sh
python scripts/replace_reviewed_chart.py --cache /path/to/cache --proposal /private/proposal.json
```

The dry run reports only aggregate affected-file counts, before/after chart
revisions, and a `plan_sha256`. It creates no backups and changes no chart or user
JSON. The ordinary library lock file may be created. A review plan fingerprints
the exact bytes of every proposed target, so an alias change, personal edit, or
new unbound calibration after review requires another dry run.

## Exact update scope

For each requested song the tool updates its track chart, its existing ISRC alias
only when the alias has the same old recording and compatible chart/lyrics, and
personal song timing maps only when both recording and chart revision are absent.
Each such legacy map gains the **old** recording hash. Its offset, scale, anchors,
and all other stored values remain intact. Already bound maps are unchanged.
Personal chord correction overlays, histories, account fields, other songs, and
practice recordings are retained. The changed chart identity makes prior chord
overlays and timing calibrations stale instead of applying them to another
recording. Existing practice takes tied to the previous revision remain stored;
the current scoring API may reject them as stale.

A batch of two songs therefore means two individually reviewed track replacements,
their compatible aliases, and the relevant legacy maps, with a separate backup
and plan for each song. It does not authorize a library-wide repair. Another track
cache file sharing an ISRC is not implicitly updated.

## Apply and recover

After approval, apply exactly the reviewed plan:

```sh
python scripts/replace_reviewed_chart.py --cache /path/to/cache --proposal /private/proposal.json --apply --expected-plan REVIEWED_PLAN_SHA256
```

Queued or running work for the track or alias prevents replacement. All checks
and writes hold the existing library lock. Before the first update, the script
saves every original target byte-for-byte and a private manifest under a new
`reviewed-chart-backup-*` directory inside the cache. Directories are mode 0700
and files 0600. Writes use flush, file sync, atomic replacement, and directory
sync. A caught write failure rolls back completed writes to their exact original
bytes, unless a non-cooperating writer has since changed them. A process killed
between file writes can leave a partial update; its already-complete backup is
the recovery source. Keep backups private because they include affected account
files. Successful output contains the backup path, not the saved personal data.

Review and restore that backup using the same plan fingerprint:

```sh
python scripts/replace_reviewed_chart.py --cache /path/to/cache --restore-backup /path/to/cache/reviewed-chart-backup-TIMESTAMP
python scripts/replace_reviewed_chart.py --cache /path/to/cache --restore-backup /path/to/cache/reviewed-chart-backup-TIMESTAMP --apply --expected-plan REVIEWED_PLAN_SHA256
```

Restore validates every backup and current target before writing. Current bytes
must equal the exact before or after version in the manifest; later edits block
restoration and must be inspected separately. It handles both fully applied and
partially applied plans. Repeating the replacement reports completion only when a
matching intact backup proves every target reached its final version. A primary
chart match alone never certifies an interrupted plan; restore its backup first.
Repeated restoration is safe, and interrupted restoration can be resumed with the same backup.
The tool does not modify completed job history or rewrite catalog lyrics.

`backend/tests/test_reviewed_chart_replacement.py` uses authored fixtures for
canonical fingerprints, dry-run privacy, backups, preservation of overlays and
maps, stale review guards, active work, recording/lyric validation, write failure,
interrupted recovery, idempotence, and tampered backups. No provider or production
calls are part of these tests.
