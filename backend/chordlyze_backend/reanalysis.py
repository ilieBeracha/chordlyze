"""Presentation metadata and guarded full-chart replacement under library_lock."""
from __future__ import annotations

import copy
import base64
import hashlib
import json
import math
import os
from pathlib import Path
import re
import tempfile
import time

from . import corrections
from .analysis.provenance import ANALYSIS_VERSION, ANALYSIS_VERSION_RELEASED_AT, MODEL_REVISIONS, is_current
from .song_jobs import SongJobs, lyrics_fingerprint


def analysis_info(chart: dict | None) -> dict:
    entry = chart or {}
    version = entry.get('analysis_version')
    version = version if type(version) is int and version >= 0 else None
    analyzed = entry.get('analyzed_at')
    if type(analyzed) not in (int, float) or not math.isfinite(analyzed) or analyzed <= 0:
        analyzed = None
    source = entry.get('audio_source') or {}
    source = source if isinstance(source, dict) else {}
    model = entry.get('model') if isinstance(entry.get('model'), str) else None
    model_revision = entry.get('model_revision') if isinstance(entry.get('model_revision'), str) else None
    source_title = source.get('title') if isinstance(source.get('title'), str) else None
    provider = source.get('provider') or entry.get('source')
    provider = provider if isinstance(provider, str) else None
    return {'analyzed_at': analyzed, 'analysis_version': version,
            'current_analysis_version': ANALYSIS_VERSION,
            'versions_behind': max(0, ANALYSIS_VERSION - version) if version is not None else None,
            'is_current': bool(chart and entry.get('source') != 'itunes_preview' and is_current(entry, 'ismir2019')),
            'model': model, 'model_revision': model_revision,
            'current_model_revision': MODEL_REVISIONS.get(model, MODEL_REVISIONS['ismir2019']),
            'source_title': source_title, 'source_provider': provider,
            'current_version_released_at': ANALYSIS_VERSION_RELEASED_AT,
            'chart_revision': corrections.revision(entry) if chart else None}


def matches_original(job: dict, chart: dict) -> bool:
    expected = job.get('reanalysis') or {}
    return (expected.get('chart_revision') == corrections.revision(chart)
            and expected.get('lyrics_sha256') == lyrics_fingerprint(chart.get('lyrics')))


def chart_fingerprint(chart: dict) -> str:
    return hashlib.sha256(json.dumps(chart, sort_keys=True, ensure_ascii=False,
                                     separators=(',', ':'), allow_nan=False).encode()).hexdigest()


def _digest(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def _atomic_bytes(path: Path, raw: bytes) -> None:
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as handle:
        temporary = Path(handle.name)
        try:
            handle.write(raw)
            handle.flush()
            os.fsync(handle.fileno())
            os.replace(temporary, path)
            directory = os.open(path.parent, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            temporary.unlink(missing_ok=True)


def write_json(path: Path, value: dict) -> None:
    """Durable publication writes; ordinary job heartbeats need not fsync here."""
    _atomic_bytes(path, json.dumps(value, allow_nan=False).encode())


def _finish_publication(cache: Path, job: dict) -> bool:
    jobs = SongJobs(cache)
    track = job['song']['track_id']
    if not jobs.valid_lease(track, job['id'], job['lease'], job['generation']):
        return False
    completed = jobs.get(track)
    completed.update(state='ready', message='Full song reanalyzed.', finished_at=time.time())
    completed.pop('lease', None)
    # One commit write. A failure after rename must not roll back complete
    # targets while leaving a terminal ready marker on disk.
    _atomic_bytes(jobs.path(track), json.dumps(completed, allow_nan=False).encode())
    return True


def _target_path(cache: Path, relative: str) -> Path:
    if not (re.fullmatch(r'(?:track-|isrc-)[A-Za-z0-9]+\.json', relative)
            or re.fullmatch(r'users/[A-Za-z0-9_-]+\.json', relative)):
        raise ValueError('Invalid reanalysis publication target.')
    target = cache / relative
    if target.is_symlink() or target.parent.is_symlink():
        raise ValueError('Reanalysis publication cannot follow symbolic links.')
    return target


def recover_publication(cache: Path, job: dict, current: dict) -> bool:
    """Verify every file, then resume the bounded plan without overwriting edits."""
    publication = job.get('publication')
    if not isinstance(publication, dict):
        return False
    name = publication.get('backup')
    if not isinstance(name, str) or re.fullmatch(r'reviewed-chart-backup-reanalysis-[A-Za-z0-9_-]+', name) is None:
        return False
    backup = cache / name
    if backup.is_symlink():
        return False
    try:
        manifest = json.loads((backup / 'manifest.json').read_bytes())
        plan = manifest['files']
        if (manifest['track_id'] != job['song']['track_id']
                or chart_fingerprint({'files': plan}) != publication.get('plan_sha256')
                or manifest['plan_sha256'] != publication['plan_sha256']):
            return False
        payload = json.loads((backup / 'pending-writes.json').read_bytes())
        targets = []
        seen = set()
        for item in plan:
            relative = item['file']
            if relative in seen:
                return False
            seen.add(relative)
            target, saved = _target_path(cache, relative), _target_path(backup, relative)
            old, new, present = saved.read_bytes(), base64.b64decode(payload[relative], validate=True), target.read_bytes()
            if (_digest(old) != item['before'] or _digest(new) != item['after']
                    or _digest(present) not in (item['before'], item['after'])):
                return False
            if relative.startswith('isrc-'):
                alias_job = SongJobs(cache).get(json.loads(old).get('track_id') or job['song']['track_id'])
                if alias_job and alias_job['id'] != job['id'] and alias_job['state'] in ('queued', 'processing'):
                    return False
            targets.append((target, present, new))
        primary = cache / f"track-{job['song']['track_id']}.json"
        if primary not in [p for p, _, _ in targets]:
            return False
        # Preflight ALL current files above before replacing any. Primary last.
        targets.sort(key=lambda row: row[0] == primary)
        for target, present, new in targets:
            if target.read_bytes() != present:
                return False
            if present != new:
                _atomic_bytes(target, new)
        return _finish_publication(cache, job)
    except (FileNotFoundError, ValueError, KeyError, TypeError):
        # A missing/tampered target is a validation conflict. Other I/O errors
        # propagate so the durable journal remains reclaimable, not failed.
        return False


def publish(cache: Path, job: dict, before: dict, after: dict) -> None:
    """Publish a complete replacement while preserving all personal edit values.

    The caller holds library_lock and validated the lease/original fingerprints.
    Atomic per-file writes and exact-byte rollback protect ordinary I/O failures.
    Legacy calibrations are bound to the old chart before the primary changes.
    """
    track = before['track_id']
    primary = cache / f'track-{track}.json'
    targets: dict[Path, dict] = {}
    identities = {track: before}
    isrc = before.get('isrc')
    if isrc:
        alias_path = cache / f'isrc-{isrc.upper()}.json'
        if alias_path.exists():
            alias = json.loads(alias_path.read_bytes())
            alias_job = SongJobs(cache).get(alias.get('track_id') or track)
            alias_busy = alias_job and alias_job['id'] != job['id'] and alias_job['state'] in ('queued', 'processing')
            if (not alias_busy and corrections.revision(alias) == corrections.revision(before)
                    and lyrics_fingerprint(alias.get('lyrics')) == lyrics_fingerprint(before.get('lyrics'))):
                preserve = {k: alias[k] for k in ('track_id', 'title', 'artist', 'album', 'artwork', 'isrc') if k in alias}
                targets[alias_path] = {**copy.deepcopy(after), **preserve}
                if alias.get('track_id'):
                    identities[alias['track_id']] = alias
    for path in (cache / 'users').glob('*.json'):
        user = json.loads(path.read_bytes())
        changed = False
        for identity, old in identities.items():
            timing = user.get('songs', {}).get(identity, {}).get('timing')
            if isinstance(timing, dict) and not timing.get('chart_audio_sha256') and not timing.get('chart_revision'):
                if old.get('audio_sha256'):
                    timing['chart_audio_sha256'] = old['audio_sha256']
                else:
                    timing['chart_revision'] = corrections.revision(old)
                changed = True
        if changed:
            targets[path] = user
    targets[primary] = after
    for path in targets:
        _target_path(cache, str(path.relative_to(cache)))
    old_bytes = {path: path.read_bytes() for path in targets}
    job_path = SongJobs(cache).path(track)
    old_job = job_path.read_bytes()
    new_bytes = {path: json.dumps(data, allow_nan=False).encode() for path, data in targets.items()}
    plan = [{'file': str(path.relative_to(cache)), 'before': _digest(old_bytes[path]),
             'after': _digest(new_bytes[path])} for path in targets]
    plan_hash = chart_fingerprint({'files': plan})
    backup = Path(tempfile.mkdtemp(prefix='reviewed-chart-backup-reanalysis-' + job['id'] + '-', dir=cache))
    for path, raw in old_bytes.items():
        saved = backup / path.relative_to(cache)
        saved.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        _atomic_bytes(saved, raw)
    _atomic_bytes(backup / 'pending-writes.json', json.dumps({str(path.relative_to(cache)): base64.b64encode(raw).decode()
                                                           for path, raw in new_bytes.items()}).encode())
    _atomic_bytes(backup / 'manifest.json', json.dumps({'track_id': track, 'plan_sha256': plan_hash, 'files': plan}).encode())
    completed = []
    try:
        # The job contains only an opaque backup reference, never personal JSON.
        write_json(job_path, {**job, 'publication': {'backup': backup.name, 'plan_sha256': plan_hash}})
        for path, data in targets.items():
            if path.read_bytes() != old_bytes[path]:
                raise ValueError('A publication target changed during backup.')
            completed.append(path)
            write_json(path, data)
        if not _finish_publication(cache, job):
            raise ValueError('Reanalysis lease expired during publication.')
    except BaseException:
        terminal = SongJobs(cache).get(track)
        if (terminal and terminal['id'] == job['id'] and terminal['state'] == 'ready'
                and terminal.get('publication') == {'backup': backup.name, 'plan_sha256': plan_hash}):
            # All targets were durable before this commit point. Leave the
            # complete result and journal intact, even if ready's fsync failed.
            raise
        # Use the same atomic writer with the exact original serialization.
        for path, raw in [(p, old_bytes[p]) for p in reversed(completed)] + [(job_path, old_job)]:
            _atomic_bytes(path, raw)
        raise
