"""Reconcile existing recording-aligned lyrics with the exact cached catalog.

No provider calls, downloads, recognition, or changes to chord/timing revisions.
"""
from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path

from .lyrics_align import complete_lyrics, mark_estimated_words
from .lyrics_validation import mark_unreliable_words


def repaired_entry(entry: dict, cache: Path) -> dict | None:
    lyrics = entry.get('lyrics') or {}
    if lyrics.get('matched') not in ('aligned', 'transcribed'):
        return None
    lines = copy.deepcopy(lyrics.get('lines') or [])
    mark_estimated_words(lines)
    note = None
    duration = entry.get('song_duration') or entry.get('audio_duration')
    key = f"{entry.get('title', '')}|{entry.get('artist', '')}|{entry.get('album') or ''}|{round(duration) if duration else ''}"
    path = cache / ('lyrics5-' + hashlib.sha256(key.lower().encode()).hexdigest()[:24] + '.json')
    try:
        catalog = json.loads(path.read_text())
    except (OSError, ValueError):
        catalog = None
    if (lyrics.get('matched') == 'aligned' and isinstance(catalog, dict)
            and catalog.get('lines') and not catalog.get('instrumental')):
        lines, note = complete_lyrics(catalog, lines)
    review = mark_unreliable_words(lines, entry.get('audio_duration') or duration)
    if lines == lyrics.get('lines') and review == lyrics.get('timing_review'):
        return None
    result = copy.deepcopy(entry)
    result['lyrics']['lines'] = lines
    result['lyrics']['timing_note'] = note or 'Some lyric timing is approximate.'
    result['lyrics']['completeness_version'] = 3
    if review:
        result['lyrics']['timing_review'] = review
    else:
        result['lyrics'].pop('timing_review', None)
    return result
