"""Read-only timing audit for every saved song; outputs counts, never lyrics.

Compare cached data with the proposed on-read repair. Unresolved timing is
reported explicitly; this audit does not establish acoustic accuracy or start
downloads, transcription, jobs, or cache writes. --fail-on-invalid makes known
invalid timing an explicit release check.
"""
import argparse
from collections import Counter
import json
import math
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from chordlyze_backend.lyrics_align import reliable_word_times
from chordlyze_backend.lyrics_repair import repaired_entry


def number(value):
    return isinstance(value, (int, float)) and math.isfinite(value)


def inspect_timing(entry):
    lyrics = entry.get('lyrics') or {}
    lines = lyrics.get('lines') or []
    counts = Counter()
    previous = -1.0
    mixed = any(w.get('end') is not None for line in lines for w in line.get('words') or [])
    for i, line in enumerate(lines):
        onset = line.get('time')
        if not number(onset) or onset < 0 or onset < previous:
            counts['invalid_line_times'] += 1
        if number(onset): previous = onset
        words = line.get('words') or []
        if not line.get('text', '').strip():
            counts['blank_lines'] += 1
            continue
        counts['lyric_lines'] += 1
        if not words:
            counts['line_only_lines'] += 1
            continue
        counts['word_timed_lines'] += 1
        if not reliable_word_times(line):
            counts['malformed_word_lines'] += 1
        normalize = lambda text: ' '.join(text.split()).lower()
        if normalize(' '.join(w.get('text', '') for w in words)) != normalize(line['text']):
            counts['incomplete_word_lines'] += 1
        next_time = lines[i + 1].get('time') if i + 1 < len(lines) else entry.get('song_duration') or entry.get('audio_duration')
        if number(onset) and any(number(w.get('time')) and
                (w['time'] < onset or (number(next_time) and w['time'] >= next_time)) for w in words):
            counts['out_of_line_word_lines'] += 1
        counts['estimated_words'] += sum(w.get('estimated') is True for w in words)
        if mixed and lyrics.get('matched') in ('aligned', 'transcribed'):
            counts['unmarked_estimated_words'] += sum(w.get('end') is None and 'estimated' not in w for w in words)
    return counts


INVALID = ('invalid_line_times', 'malformed_word_lines', 'incomplete_word_lines', 'out_of_line_word_lines')


def audit(cache):
    if not cache.is_dir():
        raise ValueError('The song cache directory is unavailable')
    totals = Counter()
    sources = Counter()
    remaining_by_source = Counter()
    before, after = Counter(), Counter()
    for path in sorted(cache.glob('track-*.json')):
        totals['tracks_scanned'] += 1
        original = path.read_bytes()
        try:
            entry = json.loads(original)
            if entry.get('source') == 'itunes_preview':
                totals['preview_charts_excluded'] += 1
                continue
            lyrics = entry.get('lyrics') or {}
            source = lyrics.get('matched') or 'no_lyrics'
            sources[source if source in ('aligned', 'transcribed', 'exact', 'fuzzy', 'no_lyrics') else 'other'] += 1
            initial = inspect_timing(entry)
            updated = repaired_entry(entry, cache) or entry
            final = inspect_timing(updated)
            before.update(initial)
            after.update(final)
            if updated != entry: totals['read_repair_changed_tracks'] += 1
            if any(initial[k] for k in INVALID): totals['initially_invalid_tracks'] += 1
            if any(final[k] for k in INVALID):
                totals['remaining_invalid_tracks'] += 1
                remaining_by_source[source if source in ('aligned', 'transcribed', 'exact', 'fuzzy', 'no_lyrics') else 'other'] += 1
            if final['malformed_word_lines'] and lyrics.get('matched') == 'transcribed':
                totals['transcribed_tracks_requiring_audio_review'] += 1
            if {k: v for k, v in entry.items() if k != 'lyrics'} != {k: v for k, v in updated.items() if k != 'lyrics'}:
                totals['non_lyric_change_failures'] += 1
        except (ValueError, TypeError, KeyError, AttributeError, OverflowError):
            totals['unreadable_or_invalid_charts'] += 1
        if path.read_bytes() != original:
            totals['charts_changed_during_audit'] += 1
    for key in ('tracks_scanned', 'read_repair_changed_tracks', 'initially_invalid_tracks',
                'remaining_invalid_tracks', 'transcribed_tracks_requiring_audio_review',
                'non_lyric_change_failures', 'unreadable_or_invalid_charts', 'charts_changed_during_audit'):
        totals.setdefault(key, 0)
    return {'totals': dict(totals), 'sources': dict(sources), 'before': dict(before),
            'after_read_repair': dict(after), 'remaining_by_source': dict(remaining_by_source)}


def has_invalid(report):
    totals = report['totals']
    return not totals['tracks_scanned'] or any(totals[k] for k in ('remaining_invalid_tracks', 'non_lyric_change_failures',
                                   'unreadable_or_invalid_charts', 'charts_changed_during_audit'))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path, required=True)
    parser.add_argument('--fail-on-invalid', action='store_true')
    args = parser.parse_args()
    report = audit(args.cache)
    print(json.dumps(report, indent=2, sort_keys=True))
    if args.fail_on_invalid and has_invalid(report):
        raise SystemExit(1)
