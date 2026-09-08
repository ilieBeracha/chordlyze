"""Reconcile existing recording-aligned lyrics with the exact cached catalog.

No provider calls, downloads, recognition, or changes to chord/timing revisions.
"""
from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path

from .lyrics_align import complete_lyrics


def repaired_entry(entry: dict, cache: Path) -> dict | None:
    lyrics = entry.get('lyrics') or {}
    if lyrics.get('matched') != 'aligned':
        return None
    duration = entry.get('song_duration') or entry.get('audio_duration')
    key = f"{entry.get('title', '')}|{entry.get('artist', '')}|{entry.get('album') or ''}|{round(duration) if duration else ''}"
    path = cache / ('lyrics5-' + hashlib.sha256(key.lower().encode()).hexdigest()[:24] + '.json')
    if not path.exists():
        return None
    catalog = json.loads(path.read_text())
    if not catalog.get('lines') or catalog.get('instrumental'):
        return None
    lines, note = complete_lyrics(catalog, lyrics.get('lines') or [])
    if lines == lyrics.get('lines'):
        return None
    result = copy.deepcopy(entry)
    result['lyrics']['lines'] = lines
    result['lyrics']['timing_note'] = note or 'Some lyric timing is approximate.'
    result['lyrics']['completeness_version'] = 2
    return result
