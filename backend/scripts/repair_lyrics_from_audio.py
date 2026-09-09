"""Repair one saved chart's malformed words using its verified audio.

Defaults to a dry run. --apply checks for concurrent changes and backs up the
original chart and matching ISRC alias before changing only their lyrics.
No downloads, catalog requests, chord inference, or account changes occur.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from chordlyze_backend.lyrics_align import transcribe_words_local
from chordlyze_backend.lyrics_timing import repair_entry_from_audio
from chordlyze_backend.song_jobs import library_lock
from scripts.repair_lyrics import atomic_write


def repair(cache: Path, track_id: str, audio: Path, *, apply: bool = False,
           transcribe=None) -> dict:
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,200}', track_id):
        raise ValueError('Invalid track identifier')
    path = cache / f'track-{track_id}.json'
    with library_lock(cache):
        entry = json.loads(path.read_text())
    stats: dict = {}
    transcribe = transcribe or (lambda clip, language: transcribe_words_local(clip, language, timeout=120))
    updated = repair_entry_from_audio(entry, audio, transcribe, stats=stats)
    result = {'track_id': track_id, 'changed': updated is not None, 'applied': False, **stats}
    if updated is None:
        return result
    result['changed_lines'] = sum(a != b for a, b in zip(entry['lyrics']['lines'], updated['lyrics']['lines']))
    if not apply:
        return result
    with library_lock(cache):
        if json.loads(path.read_text()) != entry:
            raise ValueError('The chart changed during verification; retry against the current chart')
        targets = [(path, updated)]
        isrc = ''.join(c for c in (entry.get('isrc') or '').upper() if c.isalnum())
        alias = cache / f'isrc-{isrc}.json'
        if isrc and alias.exists():
            aliased = json.loads(alias.read_text())
            if aliased.get('audio_sha256') == entry['audio_sha256'] and aliased.get('lyrics') == entry.get('lyrics'):
                targets.append((alias, {**aliased, 'lyrics': updated['lyrics']}))
        backup = cache / ('lyrics-audio-backup-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ'))
        backup.mkdir()
        for target, _ in targets:
            (backup / target.name).write_bytes(target.read_bytes())
        for target, payload in targets:
            atomic_write(target, payload)
        result.update(applied=True, backup=str(backup))
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path, required=True)
    parser.add_argument('--track-id', required=True)
    parser.add_argument('--audio', type=Path, required=True)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    print(json.dumps(repair(args.cache, args.track_id, args.audio, apply=args.apply)))
