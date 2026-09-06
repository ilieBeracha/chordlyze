"""Durable, leased full-song requests; no preview is a finished song chart."""
from __future__ import annotations

from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import uuid

_lock = threading.RLock()
_local = threading.local()
LEASE_SECONDS = 180


@contextmanager
def library_lock(directory: Path):
    directory.mkdir(parents=True, exist_ok=True)
    with _lock:
        depth = getattr(_local, 'depth', 0)
        if depth:
            _local.depth += 1
            try:
                yield
            finally:
                _local.depth -= 1
        else:
            with (directory / '.library.lock').open('a') as handle:
                fcntl.flock(handle, fcntl.LOCK_EX)
                _local.depth = 1
                try:
                    yield
                finally:
                    _local.depth = 0
                    fcntl.flock(handle, fcntl.LOCK_UN)


def write_json(path: Path, value: dict) -> None:
    with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, delete=False) as handle:
        temporary = Path(handle.name)
        try:
            json.dump(value, handle, allow_nan=False)
            handle.flush()
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)


def generation(directory: Path) -> str:
    with library_lock(directory):
        path = directory / 'library-generation'
        if not path.exists():
            path.write_text(uuid.uuid4().hex)
        return path.read_text().strip()


def reset_library(directory: Path, *, apply: bool = False) -> dict:
    """Explicit administrative reset; does not touch credentials or model assets."""
    with library_lock(directory):
        files = list(directory.glob('*.json'))
        tracks = sum(p.name.startswith('track-') for p in files)
        if apply:
            for path in files:
                path.unlink()
            (directory / 'library-generation').write_text(uuid.uuid4().hex)
        return {'applied': apply, 'analyses': tracks, 'song_cache_files': len(files),
                'generation': generation(directory)}


class SongJobs:
    def __init__(self, directory: Path):
        self.directory = directory

    def path(self, track_id: str) -> Path:
        digest = hashlib.sha256(track_id.encode()).hexdigest()[:24]
        return self.directory / f'job-{digest}.json'

    def get(self, track_id: str) -> dict | None:
        with library_lock(self.directory):
            path = self.path(track_id)
            return json.loads(path.read_text()) if path.exists() else None

    def request(self, song: dict, *, retry: bool = False, kind: str = 'analysis') -> dict:
        """kind 'analysis' makes a chart; 'lyrics' re-fetches the recording of
        an existing chart only to time its lyrics. A lyrics job replaces a
        finished record for the track, never one still queued or running."""
        with library_lock(self.directory):
            previous = self.get(song['track_id'])
            if previous and kind == 'analysis' and not (retry and previous['state'] in ('failed', 'unavailable')):
                return previous
            if previous and kind == 'lyrics' and previous['state'] in ('queued', 'processing'):
                return previous
            job = {'id': uuid.uuid4().hex, 'generation': generation(self.directory), 'kind': kind,
                   'song': song, 'state': 'queued', 'created_at': time.time(), 'attempts': 0,
                   'message': 'Waiting to analyze the full song.' if kind == 'analysis' else 'Waiting to time the lyrics.'}
            write_json(self.path(song['track_id']), job)
            return job

    def worker_online(self) -> bool:
        path = self.directory / 'worker-heartbeat.json'
        with library_lock(self.directory):
            return path.exists() and time.time() - json.loads(path.read_text())['at'] < 60

    def heartbeat(self, job_id: str | None = None, lease: str | None = None,
                  stage: str | None = None, download_checkpoint: dict | None = None) -> bool:
        with library_lock(self.directory):
            write_json(self.directory / 'worker-heartbeat.json', {'at': time.time()})
            if not job_id:
                return True
            for path in self.directory.glob('job-*.json'):
                job = json.loads(path.read_text())
                if (job['id'] == job_id and job.get('lease') == lease and job['state'] == 'processing'
                        and job.get('lease_until', 0) >= time.time()
                        and job['generation'] == generation(self.directory)):
                    job['lease_until'] = time.time() + LEASE_SECONDS
                    if stage in ('downloading', 'analyzing'):
                        job['stage'] = stage
                    if download_checkpoint is not None:
                        job['download_checkpoint'] = download_checkpoint
                    write_json(path, job)
                    return True
            return False

    def claim(self) -> dict | None:
        with library_lock(self.directory):
            self.heartbeat()
            jobs = sorted((json.loads(p.read_text()) for p in self.directory.glob('job-*.json')),
                          key=lambda j: j['created_at'])
            for job in jobs:
                expired = job['state'] == 'processing' and job.get('lease_until', 0) < time.time()
                if job['state'] != 'queued' and not expired:
                    continue
                if job['attempts'] >= 3:
                    job.update(state='failed', message='Analysis was interrupted. Retry this song.')
                    write_json(self.path(job['song']['track_id']), job)
                    continue
                job.update(state='processing', stage='downloading', lease=uuid.uuid4().hex,
                           lease_until=time.time() + LEASE_SECONDS, attempts=job['attempts'] + 1)
                write_json(self.path(job['song']['track_id']), job)
                return job
            return None

    def valid_lease(self, track_id: str, job_id: str, lease: str, epoch: str) -> bool:
        job = self.get(track_id)
        return bool(job and job['id'] == job_id and job.get('lease') == lease
                    and job['state'] == 'processing' and job.get('lease_until', 0) >= time.time()
                    and job['generation'] == epoch == generation(self.directory))

    def finish(self, track_id: str, job_id: str, lease: str, epoch: str,
               state: str, message: str | None = None) -> bool:
        with library_lock(self.directory):
            if not self.valid_lease(track_id, job_id, lease, epoch):
                return False
            job = self.get(track_id)
            job.update(state=state, message=message, finished_at=time.time())
            job.pop('lease', None)
            write_json(self.path(track_id), job)
            return True

    def ahead(self, job: dict) -> int:
        """Earlier requests still waiting or being processed."""
        with library_lock(self.directory):
            count = 0
            for path in self.directory.glob('job-*.json'):
                other = json.loads(path.read_text())
                if (other['id'] != job['id'] and other['state'] in ('queued', 'processing')
                        and other['created_at'] < job['created_at']):
                    count += 1
            return count

    def public(self, job: dict | None) -> dict:
        if not job:
            return {'state': 'missing', 'worker_online': self.worker_online()}
        result = {key: job.get(key) for key in ('state', 'stage', 'message')} | {
            'worker_online': self.worker_online()}
        if job['state'] == 'queued':
            result['ahead'] = self.ahead(job)
        return result
