"""Install one reviewed recording/chart replacement; default is a private dry run.

Proposal: track_id, expected_before_sha256 (canonical JSON),
expected_audio_sha256, and replacement (complete analysis plus reviewed lyrics).
Run a dry run first, then pass its plan_sha256 with --apply --expected-plan.
No providers, recognition, requeues, cache reset, or personal edit deletion.
"""
from __future__ import annotations

import argparse
import copy
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from chordlyze_backend import corrections
from chordlyze_backend.analysis.beats import validate_tempo
from chordlyze_backend.analysis.engine import validated_segments
from chordlyze_backend.analysis.keyfinder import analyze
from chordlyze_backend.analysis.provenance import is_current
from chordlyze_backend.analysis.review import matching_review
from chordlyze_backend.artist_recordings import valid_source_url
from chordlyze_backend.fulltrack import _recording_candidate
from chordlyze_backend.lyrics_validation import finite, has_measured_words, mark_unreliable_words, preserves_lyric_text
from chordlyze_backend.song_jobs import SongJobs, library_lock, lyrics_fingerprint


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def encoded(data: dict) -> bytes:
    return json.dumps(data, sort_keys=True, ensure_ascii=False,
                      separators=(',', ':'), allow_nan=False).encode('utf-8')


def atomic_bytes(path: Path, data: bytes) -> None:
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as handle:
        temporary = Path(handle.name)
        try:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
            os.replace(temporary, path)
            directory_fd = os.open(path.parent, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        finally:
            temporary.unlink(missing_ok=True)


def verified_applied(cache: Path, proposal: dict, after: dict) -> bool:
    """A matching primary alone cannot prove an interrupted plan completed."""
    track = proposal['track_id']
    primary = f'track-{track}.json'
    for backup in cache.glob('reviewed-chart-backup-*'):
        if backup.is_symlink() or not backup.is_dir():
            continue
        try:
            manifest = json.loads((backup / 'manifest.json').read_bytes())
            plan = manifest['files']
            if (manifest['track_id'] != track or digest(encoded({'files': plan})) != manifest['plan_sha256']
                    or not any(item['file'] == primary and item['after'] == digest(encoded(after)) for item in plan)):
                continue
            old = json.loads((backup / primary).read_bytes())
            if (digest(encoded(old)) != proposal['expected_before_sha256']
                    or old.get('audio_sha256') != proposal['expected_audio_sha256']):
                continue
            for item in plan:
                relative = Path(item['file'])
                if (relative.is_absolute() or '..' in relative.parts
                        or not (re.fullmatch(r'(?:track-|isrc-)[A-Za-z0-9]+\.json', str(relative))
                                or re.fullmatch(r'users/[^/]+\.json', str(relative)))):
                    break
                saved, target = backup / relative, cache / relative
                if (any(p.is_symlink() for p in (saved, saved.parent, target, target.parent))
                        or digest(saved.read_bytes()) != item['before']
                        or digest(target.read_bytes()) != item['after']):
                    break
            else:
                return True
        except (OSError, ValueError, KeyError, TypeError):
            continue
    return False


def replacement_chart(before: dict, candidate: dict, track: str) -> dict:
    if candidate.get('track_id') != track or before.get('track_id') != track:
        raise ValueError('The replacement must identify the same song.')
    if not is_current(candidate, model='ismir2019') or candidate.get('source') == 'itunes_preview':
        raise ValueError('A complete current chord analysis is required.')
    if not re.fullmatch(r'[0-9a-f]{64}', candidate.get('audio_sha256') or ''):
        raise ValueError('A verified recording identity is required.')
    duration = candidate.get('audio_duration')
    if isinstance(duration, bool) or not isinstance(duration, (float, int)) or not math.isfinite(duration) or not 0 < duration <= 1203:
        raise ValueError('Invalid recording duration.')
    expected_duration = before.get('song_duration') or before.get('audio_duration')
    if expected_duration and abs(duration - expected_duration) > max(2, min(3, expected_duration * .01)):
        raise ValueError('The recording duration differs from the requested song.')
    for key in ('title', 'artist'):
        if candidate.get(key) != before.get(key):
            raise ValueError('The replacement must preserve the requested song metadata.')
    source = candidate.get('audio_source') or {}
    if (not isinstance(source, dict) or not str(source.get('matching') or '').startswith('reviewed_')
            or not _recording_candidate(source, before['title'], before['artist'], expected_duration)):
        raise ValueError('Reviewed recording provenance is required.')
    if source.get('provider') == 'bandcamp':
        valid_url = candidate['source'] == 'bandcamp' and valid_source_url(source.get('url'))
    else:
        video = source.get('video_id')
        valid_url = (candidate['source'] == 'youtube' and source.get('provider') in ('youtube', 'yt_dlp', 'apify')
                     and isinstance(video, str) and re.fullmatch(r'[A-Za-z0-9_-]{11}', video)
                     and source.get('url') == f'https://www.youtube.com/watch?v={video}')
    if not valid_url:
        raise ValueError('A supported exact recording URL is required.')
    rows = candidate.get('chords') or []
    if not rows or any(row['end'] > duration for row in rows):
        raise ValueError('Chord coverage exceeds or omits the recording.')
    segments = validated_segments([(row['start'], row['end'], row['label']) for row in rows], duration)
    if (not segments or segments[0].start > .1 or duration - segments[-1].end > .1
            or any(abs(a.end - b.start) > 1e-5 for a, b in zip(segments, segments[1:]))):
        raise ValueError('A complete continuous chord timeline is required.')
    lyrics = copy.deepcopy(candidate.get('lyrics'))
    if not isinstance(lyrics, dict) or not lyrics.get('synced') or lyrics.get('matched') not in ('aligned', 'transcribed'):
        raise ValueError('The new recording needs its own reviewed lyric timing.')
    if lyrics.get('audio_sha256') != candidate['audio_sha256'] or lyrics.get('audio_duration') != duration:
        raise ValueError('Lyric timing must identify the replacement recording.')
    lines = lyrics.get('lines') or []
    if (not isinstance(lines, list) or not 1 <= len(lines) <= 2000
            or any(not isinstance(line, dict) or not isinstance(line.get('text'), str)
                   or len(line['text']) > 1000 or not finite(line.get('time'))
                   or not 0 <= line['time'] < duration for line in lines)
            or any(a['time'] > b['time'] for a, b in zip(lines, lines[1:]))):
        raise ValueError('Lyric lines must be ordered and within the recording.')
    for index, line in enumerate(lines):
        words = line.get('words') or []
        if (not isinstance(words, list) or len(words) > 200
                or any(not isinstance(w, dict) or not isinstance(w.get('text'), str)
                       or not 1 <= len(w['text']) <= 200 or not finite(w.get('time'))
                       or (w.get('end') is not None and not finite(w['end'])) for w in words)):
            raise ValueError('Invalid lyric word evidence.')
        boundary = lines[index + 1]['time'] if index + 1 < len(lines) else duration
        for word in words:
            if word.get('end') is None or word['end'] > boundary:
                word['estimated'] = True
    mark_unreliable_words(lines, duration)
    if not has_measured_words(lines, duration):
        raise ValueError('The replacement has no measured sung-word intervals.')
    if not preserves_lyric_text((before.get('lyrics') or {}).get('lines') or [], lines):
        raise ValueError('The replacement would lose existing lyric text.')
    after = copy.deepcopy(before)
    after.update(analyze(segments))
    for key in ('model', 'model_revision', 'analysis_version', 'audio_sha256', 'audio_duration', 'source'):
        after[key] = candidate[key]
    after.update(audio_source=copy.deepcopy(source), lyrics=lyrics,
                 tempo=validate_tempo(candidate.get('tempo'), duration))
    after['chord_review'] = matching_review(candidate.get('chord_review') or [], after['chords'])
    for transient in ('analysis_stale', 'chart_revision', 'corrections_stale', 'can_undo', 'boundaries_edited'):
        after.pop(transient, None)
    encoded(after)
    return after


def replace_chart(cache: Path, proposal: dict, *, apply: bool = False,
                  expected_plan: str | None = None) -> dict:
    track = proposal.get('track_id') or ''
    if not re.fullmatch(r'[A-Za-z0-9]{1,200}', track):
        raise ValueError('Invalid track identifier.')
    for key in ('expected_before_sha256', 'expected_audio_sha256'):
        if not re.fullmatch(r'[0-9a-f]{64}', proposal.get(key) or ''):
            raise ValueError('Expected chart and recording fingerprints are required.')
    cache = Path(cache)
    path = cache / f'track-{track}.json'
    with library_lock(cache):
        if path.is_symlink():
            raise ValueError('Chart paths may not be symbolic links.')
        raw = path.read_bytes()
        before = json.loads(raw)
        after = replacement_chart(before, proposal['replacement'], track)
        result = {'track_id': track, 'applied': False, 'already_applied': False,
                  'files': 0, 'aliases_updated': 0, 'legacy_maps_bound': 0, 'backup': None}
        if before == after:
            if verified_applied(cache, proposal, after):
                return {**result, 'already_applied': True}
            raise ValueError('The primary chart was replaced but the complete plan is not verified; inspect and restore its backup.')
        if digest(encoded(before)) != proposal['expected_before_sha256'] or before.get('audio_sha256') != proposal['expected_audio_sha256']:
            raise ValueError('The saved chart changed after review; refresh the proposal.')
        job = SongJobs(cache).get(track)
        if job and job['state'] in ('queued', 'processing'):
            raise ValueError('This song has active work; wait for it before replacing its chart.')
        targets = {path: (raw, encoded(after))}
        isrc = ''.join(c for c in (before.get('isrc') or '').upper() if c.isalnum())
        alias_path = cache / f'isrc-{isrc}.json'
        if isrc and alias_path.exists():
            if alias_path.is_symlink():
                raise ValueError('Alias paths may not be symbolic links.')
            alias_raw = alias_path.read_bytes()
            alias = json.loads(alias_raw)
            if alias.get('audio_sha256') == before['audio_sha256']:
                alias_job = SongJobs(cache).get(alias.get('track_id') or track)
                if alias_job and alias_job['state'] in ('queued', 'processing'):
                    raise ValueError('The recording alias has active work; wait before replacing it.')
                if (corrections.revision(alias) != corrections.revision(before)
                        or lyrics_fingerprint(alias.get('lyrics')) != lyrics_fingerprint(before.get('lyrics'))):
                    raise ValueError('The recording alias has different reviewed data; inspect it separately.')
                updated_alias = replacement_chart(alias, {**proposal['replacement'],
                    'track_id': alias.get('track_id'), 'title': alias.get('title'), 'artist': alias.get('artist')},
                    alias.get('track_id'))
                targets[alias_path] = (alias_raw, encoded(updated_alias))
                result['aliases_updated'] = 1
        if before['audio_sha256'] != after['audio_sha256']:
            if (cache / 'users').is_symlink():
                raise ValueError('Personal library directories may not be symbolic links.')
            for user_path in sorted((cache / 'users').glob('*.json')):
                if user_path.is_symlink():
                    raise ValueError('Personal library paths may not be symbolic links.')
                user_raw = user_path.read_bytes()
                user = json.loads(user_raw)
                timing = user.get('songs', {}).get(track, {}).get('timing')
                if isinstance(timing, dict) and not timing.get('chart_audio_sha256') and not timing.get('chart_revision'):
                    timing['chart_audio_sha256'] = before['audio_sha256']
                    targets[user_path] = (user_raw, encoded(user))
                    result['legacy_maps_bound'] += 1
        plan = [{"file": str(p.relative_to(cache)), "before": digest(old), "after": digest(new)}
                for p, (old, new) in sorted(targets.items())]
        plan_sha = digest(encoded({'files': plan}))
        result.update(files=len(targets), plan_sha256=plan_sha,
                      before_revision=corrections.revision(before), after_revision=corrections.revision(after))
        if not apply:
            return result
        if expected_plan != plan_sha:
            raise ValueError('The replacement plan changed; review a fresh dry run before applying.')
        backup = cache / ('reviewed-chart-backup-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ'))
        backup.mkdir(mode=0o700)
        for target, (old, _) in targets.items():
            saved = backup / target.relative_to(cache)
            saved.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            atomic_bytes(saved, old)
        atomic_bytes(backup / 'manifest.json', encoded({'track_id': track, 'plan_sha256': plan_sha, 'files': plan}))
        completed = []
        try:
            for target, (old, new) in targets.items():
                # Preserve non-cooperating changes too, even under the lock.
                if target.read_bytes() != old:
                    raise ValueError('A replacement target changed while backing up; no overwrite is allowed.')
                # A replace may succeed before its directory fsync fails.
                # Include that target in rollback even if atomic_bytes raises.
                completed.append(target)
                atomic_bytes(target, new)
        except BaseException:
            for target in reversed(completed):
                if target.read_bytes() == targets[target][1]:
                    atomic_bytes(target, targets[target][0])
            raise
        return {**result, 'applied': True, 'backup': str(backup)}


def restore_backup(cache: Path, backup: Path, *, apply: bool = False,
                   expected_plan: str | None = None) -> dict:
    """Recover an interrupted/successful application without replacing later edits.

    Every target must still contain either its exact before or after bytes. All
    backups and targets are checked before any restore; repeated restore is safe.
    """
    cache, backup = Path(cache).resolve(), Path(backup)
    if backup.is_symlink() or backup.resolve().parent != cache or not backup.name.startswith('reviewed-chart-backup-'):
        raise ValueError('Use the original backup directory inside this cache.')
    with library_lock(cache):
        manifest = json.loads((backup / 'manifest.json').read_bytes())
        plan = manifest['files']
        if digest(encoded({'files': plan})) != manifest['plan_sha256']:
            raise ValueError('The backup manifest changed.')
        job = SongJobs(cache).get(manifest['track_id'])
        if job and job['state'] in ('queued', 'processing'):
            raise ValueError('This song has active work; wait before restoring its chart.')
        targets = []
        seen = set()
        for item in plan:
            relative = Path(item['file'])
            if (relative.is_absolute() or '..' in relative.parts or relative in seen
                    or not (re.fullmatch(r'(?:track-|isrc-)[A-Za-z0-9]+\.json', str(relative))
                            or re.fullmatch(r'users/[^/]+\.json', str(relative)))):
                raise ValueError('Invalid backup target.')
            seen.add(relative)
            saved, target = backup / relative, cache / relative
            if any(p.is_symlink() for p in (saved, saved.parent, target, target.parent)):
                raise ValueError('Backup targets may not be symbolic links.')
            old, current = saved.read_bytes(), target.read_bytes()
            if digest(old) != item['before'] or digest(current) not in (item['before'], item['after']):
                raise ValueError('A backup or saved file changed; inspect it before restoring.')
            if relative.name.startswith('isrc-'):
                alias_job = SongJobs(cache).get(json.loads(old).get('track_id') or manifest['track_id'])
                if alias_job and alias_job['state'] in ('queued', 'processing'):
                    raise ValueError('The recording alias has active work; wait before restoring.')
            if current != old:
                targets.append((target, old, current))
        result = {'track_id': manifest['track_id'], 'restored': False,
                  'files': len(targets), 'plan_sha256': manifest['plan_sha256']}
        if not apply:
            return result
        if expected_plan != manifest['plan_sha256']:
            raise ValueError('Pass the reviewed backup plan fingerprint to restore.')
        for target, old, current in targets:
            if target.read_bytes() != current:
                raise ValueError('A saved file changed during restore; no overwrite is allowed.')
            atomic_bytes(target, old)
        return {**result, 'restored': True}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path, required=True)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument('--proposal', type=Path)
    action.add_argument('--restore-backup', type=Path)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--expected-plan')
    args = parser.parse_args()
    result = (restore_backup(args.cache, args.restore_backup, apply=args.apply, expected_plan=args.expected_plan)
              if args.restore_backup else replace_chart(args.cache, json.loads(args.proposal.read_text()),
                                                        apply=args.apply, expected_plan=args.expected_plan))
    print(json.dumps(result))
