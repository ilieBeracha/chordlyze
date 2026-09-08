"""Repair cached lyric omissions. Defaults to a dry run; --apply writes backups.

Run on the API machine with its usual CHORDLYZE_CACHE. This uses cached catalog
text only and never changes chords, chart identities, user edits, or timing maps.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from chordlyze_backend.lyrics_repair import repaired_entry
from chordlyze_backend.song_jobs import library_lock


def atomic_write(path: Path, data: dict) -> None:
    temporary = path.with_name(path.name + '.lyrics-repair.tmp')
    try:
        with temporary.open('w') as handle:
            json.dump(data, handle, ensure_ascii=False)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def repair(cache: Path, apply: bool = False) -> dict:
    backup = cache / ('lyrics-repair-backup-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ'))
    changes = []
    with library_lock(cache):
        for path in sorted(cache.glob('track-*.json')):
            entry = json.loads(path.read_text())
            updated = repaired_entry(entry, cache)
            if updated is None:
                continue
            changes.append({'track_id': entry.get('track_id'), 'title': entry.get('title'),
                            'before': len(entry['lyrics']['lines']), 'after': len(updated['lyrics']['lines'])})
            if not apply:
                continue
            targets = [(path, updated)]
            isrc = ''.join(c for c in (entry.get('isrc') or '').upper() if c.isalnum())
            alias = cache / f'isrc-{isrc}.json'
            if isrc and alias.exists():
                aliased = json.loads(alias.read_text())
                if entry.get('audio_sha256') and aliased.get('audio_sha256') == entry['audio_sha256']:
                    targets.append((alias, {**aliased, 'lyrics': updated['lyrics']}))
            backup.mkdir(exist_ok=True)
            for target, _ in targets:
                original = backup / target.name
                if not original.exists():
                    original.write_bytes(target.read_bytes())
            for target, payload in targets:
                atomic_write(target, payload)
    return {'applied': apply, 'changes': changes, 'backup': str(backup) if apply and changes else None}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--cache', type=Path, default=Path(os.environ.get('CHORDLYZE_CACHE', 'analysis_cache')))
    args = parser.parse_args()
    print(json.dumps(repair(args.cache, args.apply)))
