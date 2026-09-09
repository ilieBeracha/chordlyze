"""Apply reviewed lyric-timing proposals with a complete backup and stale-data guard.

The private proposal file contains before/after charts. This command performs
no recognition or downloads and does not establish acoustic accuracy. Prepare
and review proposals against verified recordings first. It defaults to dry run.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from chordlyze_backend.song_jobs import library_lock
from scripts.repair_lyrics import atomic_write


def validate(proposal):
    track = proposal['track_id']
    if not isinstance(track, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,200}', track):
        raise ValueError('Invalid track identifier')
    before, after = proposal['before'], proposal['after']
    if before.get('track_id') != track or after.get('track_id') != track:
        raise ValueError('Proposal identity differs from its chart')
    if {k: v for k, v in before.items() if k != 'lyrics'} != {k: v for k, v in after.items() if k != 'lyrics'}:
        raise ValueError('A timing proposal may change only lyrics')
    old, new = before['lyrics']['lines'], after['lyrics']['lines']
    if [line['text'] for line in old] != [line['text'] for line in new]:
        raise ValueError('A timing proposal may not replace, remove, or reorder lyric text')
    if [[w['text'] for w in line.get('words') or []] for line in old] != [
            [w['text'] for w in line.get('words') or []] for line in new]:
        raise ValueError('A timing proposal may not remove source word evidence')
    json.dumps(after, allow_nan=False)


def apply_proposals(cache: Path, proposals: list[dict], *, apply: bool = False) -> dict:
    seen = set()
    for proposal in proposals:
        validate(proposal)
        if proposal['track_id'] in seen:
            raise ValueError('Duplicate chart in proposal batch')
        seen.add(proposal['track_id'])
    changed = skipped = 0
    targets = {}
    with library_lock(cache):
        # Complete the stale-data check for the entire batch before writing.
        for proposal in proposals:
            path = cache / ('track-' + proposal['track_id'] + '.json')
            current = json.loads(path.read_text())
            before, after = proposal['before'], proposal['after']
            if current == after:
                skipped += 1
                continue
            if current != before:
                raise ValueError('A chart changed after verification; regenerate the proposals')
            targets[path] = after
            changed += 1
            isrc = ''.join(c for c in (before.get('isrc') or '').upper() if c.isalnum())
            alias = cache / ('isrc-' + isrc + '.json')
            if isrc and alias.exists():
                aliased = json.loads(alias.read_text())
                if before.get('audio_sha256') and aliased.get('audio_sha256') == before['audio_sha256'] and aliased.get('lyrics') == before['lyrics']:
                    payload = {**aliased, 'lyrics': after['lyrics']}
                    if alias in targets and targets[alias] != payload:
                        raise ValueError('Conflicting corrections for a shared recording alias')
                    targets[alias] = payload
        report = {'applied': False, 'changed_tracks': changed, 'already_applied_tracks': skipped,
                  'files': len(targets), 'backup': None}
        if not apply or not targets:
            return report
        backup = cache / ('lyrics-verified-backup-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ'))
        backup.mkdir()
        for path in targets:
            (backup / path.name).write_bytes(path.read_bytes())
        completed = []
        try:
            for path, payload in targets.items():
                atomic_write(path, payload)
                completed.append(path)
        except Exception:
            for path in reversed(completed):
                atomic_write(path, json.loads((backup / path.name).read_text()))
            raise
        report.update(applied=True, backup=str(backup))
        return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path, required=True)
    parser.add_argument('--proposals', type=Path, required=True)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    print(json.dumps(apply_proposals(args.cache, json.loads(args.proposals.read_text()), apply=args.apply)))
