"""On-demand, leased instrument mixes. No raw paths, leases or source URLs in public status."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
from typing import Literal
import uuid

from fastapi import APIRouter, Depends, Header, HTTPException, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from .auth import current_user
from .song_jobs import generation, library_lock, write_json

MODEL = 'htdemucs_6s-5c90dfd2-v1'
INSTRUMENTS = ('guitar', 'bass', 'drums', 'vocals', 'piano')
PARTS = ('solo', 'backing')
MAX_SECONDS = 1200
MAX_FILE_BYTES = 48 * 1024 * 1024
CACHE_BYTES = 384 * 1024 * 1024
LEASE_SECONDS = 180


def audio_info(path: Path) -> dict:
    try:
        result = subprocess.run(['ffprobe', '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(path)],
                                capture_output=True, timeout=20, check=True)
        data = json.loads(result.stdout)
        streams = data['streams']
        if len(streams) != 1 or streams[0]['codec_name'] != 'aac' or int(streams[0]['sample_rate']) != 44100 or streams[0]['channels'] != 2:
            raise ValueError('expected stereo AAC at 44100 Hz')
        duration = float(data['format']['duration'])
        if not 0 < duration <= MAX_SECONDS + 1:
            raise ValueError('invalid audio duration')
        return {'duration': duration, 'bytes': path.stat().st_size,
                'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        raise HTTPException(422, 'Invalid isolation audio.') from error


class StemJobs:
    def __init__(self, directory: Path):
        self.directory = directory
        self.root = directory / 'stems'

    def path(self, identifier: str) -> Path:
        if len(identifier) != 32 or any(c not in '0123456789abcdef' for c in identifier):
            raise HTTPException(404, 'Isolation not found.')
        return self.directory / f'isolation-{identifier}.json'

    def get(self, identifier: str) -> dict:
        path = self.path(identifier)
        if not path.exists():
            raise HTTPException(404, 'Isolation not found.')
        job = json.loads(path.read_text())
        if job['generation'] != generation(self.directory):
            raise HTTPException(409, 'The song library changed. Prepare the instrument again.')
        return job

    def all(self):
        return [json.loads(path.read_text()) for path in self.directory.glob('isolation-*.json')]

    def write(self, job):
        write_json(self.path(job['id']), job)

    def online(self):
        path = self.directory / 'stem-worker-heartbeat.json'
        return path.exists() and time.time() - json.loads(path.read_text())['at'] < 60

    def pulse(self):
        write_json(self.directory / 'stem-worker-heartbeat.json', {'at': time.time()})

    def request(self, song, instrument, owner, retry=False):
        with library_lock(self.directory):
            self.prune()
            jobs = self.all()
            for previous in sorted(jobs, key=lambda j: j['created_at'], reverse=True):
                if (previous['song']['track_id'] == song['track_id'] and previous['audio_sha256'] == song['audio_sha256']
                        and previous['instrument'] == instrument and previous['model'] == MODEL):
                    if previous['state'] not in ('failed', 'expired') or not retry:
                        return previous
                    break
            if sum(j['state'] in ('queued', 'processing') for j in jobs) >= 12:
                raise HTTPException(429, 'Isolation queue is full. Try again later.')
            if sum(j['state'] in ('queued', 'processing') and j['owner'] == owner for j in jobs) >= 3:
                raise HTTPException(429, 'Wait for one of your instruments to finish first.')
            job = dict(id=uuid.uuid4().hex, generation=generation(self.directory), model=MODEL,
                       song=song, audio_sha256=song['audio_sha256'], instrument=instrument,
                       owner=owner, state='queued', stage='queued', created_at=time.time(), attempts=0, files={})
            self.write(job)
            return job

    def prune(self):
        self.root.mkdir(parents=True, exist_ok=True)
        jobs = self.all()
        live = {j['id'] for j in jobs}
        for path in self.root.iterdir():
            if path.is_dir() and path.name not in live:
                shutil.rmtree(path)
        for job in jobs:
            if job['state'] == 'ready' and (time.time() - job.get('used_at', job['created_at']) > 7*86400
                    or any(not (self.root / job['id'] / f'{part}.m4a').exists() for part in PARTS)):
                self.expire(job)
            if job['state'] in ('failed', 'expired'):
                shutil.rmtree(self.root / job['id'], ignore_errors=True)

    def expire(self, job):
        job.update(state='expired', files={}, message='Cached audio expired. Prepare it again.')
        self.write(job)
        shutil.rmtree(self.root / job['id'], ignore_errors=True)

    def reserve(self, count, keep):
        """Bound shared audio storage; old mixes can be generated again."""
        size = sum(p.stat().st_size for p in self.root.rglob('*.m4a'))
        for job in sorted(self.all(), key=lambda j: j.get('used_at', j['created_at'])):
            if size + count <= CACHE_BYTES:
                break
            if job['state'] == 'ready' and job['id'] != keep:
                size -= sum(v['bytes'] for v in job['files'].values())
                self.expire(job)
        if size + count > CACHE_BYTES or shutil.disk_usage(self.directory).free < count + 64*1024*1024:
            raise HTTPException(507, 'Isolation storage is full. Try again later.')

    def claim(self):
        with library_lock(self.directory):
            self.pulse(); self.prune()
            for job in sorted(self.all(), key=lambda j: j['created_at']):
                if job['state'] != 'queued' and not (job['state'] == 'processing' and job.get('lease_until', 0) < time.time()):
                    continue
                if job['attempts'] >= 3:
                    job.update(state='failed', message='Isolation was interrupted. Try preparing it again.')
                    self.write(job); continue
                shutil.rmtree(self.root / job['id'], ignore_errors=True)
                job.update(state='processing', stage='downloading', files={}, lease=uuid.uuid4().hex,
                           lease_until=time.time() + LEASE_SECONDS, attempts=job['attempts'] + 1)
                self.write(job)
                return job
            return None

    def leased(self, identifier, lease):
        job = self.get(identifier)
        if job['state'] != 'processing' or job.get('lease') != lease or job.get('lease_until', 0) < time.time():
            raise HTTPException(409, 'Isolation lease expired.')
        return job

    def public(self, job):
        return {k: job.get(k) for k in ('id', 'state', 'stage', 'instrument', 'model', 'audio_sha256', 'message', 'files')} | {
            'worker_online': self.online(), 'duration': job['song']['duration']}


class StemRequest(BaseModel):
    instrument: Literal['guitar', 'bass', 'drums', 'vocals', 'piano']
    retry: bool = False


class StemUpdate(BaseModel):
    lease: str = Field(min_length=32, max_length=32)
    stage: Literal['downloading', 'separating', 'uploading', 'ready', 'failed']
    error_code: Literal['recording_changed', 'unavailable', 'processing_failed', 'provider_limit'] | None = None


def router(cache, chart_path, worker_auth):
    routes = APIRouter()

    def current_chart(track):
        path = chart_path(track)
        if not path.exists():
            raise HTTPException(409, 'Analyze this song before preparing instruments.')
        chart = json.loads(path.read_text())
        fingerprint = chart.get('audio_sha256') or ''
        if not isinstance(fingerprint, str) or len(fingerprint) != 64 or any(c not in '0123456789abcdef' for c in fingerprint) or not chart.get('title'):
            raise HTTPException(409, 'Reanalyze this song to prepare its instruments.')
        return chart

    def valid_chart(job):
        if current_chart(job['song']['track_id'])['audio_sha256'] != job['audio_sha256']:
            raise HTTPException(409, 'The recording changed. Prepare the instrument again.')

    @routes.post('/song/{track_id}/isolation')
    def prepare(track_id: str, body: StemRequest, user: str = Depends(current_user)):
        with library_lock(cache()):
            chart = current_chart(track_id)
            duration = chart.get('audio_duration') or chart.get('song_duration') or 0
            if not 0 < duration <= MAX_SECONDS:
                raise HTTPException(422, 'Instrument isolation supports songs up to 20 minutes.')
            song = {key: chart.get(key) for key in ('title', 'artist', 'album', 'isrc', 'audio_sha256', 'audio_source')}
            song.update(track_id=track_id, duration=duration)
            jobs = StemJobs(cache())
            job = jobs.request(song, body.instrument, hashlib.sha256(user.encode()).hexdigest(), body.retry)
            return jobs.public(job)

    @routes.get('/isolation/{identifier}')
    def status(identifier: str, user: str = Depends(current_user)):
        with library_lock(cache()):
            jobs = StemJobs(cache()); jobs.prune()
            job = jobs.get(identifier); valid_chart(job)
            return jobs.public(job)

    @routes.get('/isolation/{identifier}/audio/{part}')
    def audio(identifier: str, part: Literal['solo', 'backing'], user: str = Depends(current_user)):
        with library_lock(cache()):
            jobs = StemJobs(cache()); job = jobs.get(identifier); valid_chart(job)
            path = jobs.root / identifier / f'{part}.m4a'
            if job['state'] != 'ready' or not path.exists():
                raise HTTPException(409, 'Prepare the instrument again; audio is not ready.')
            handle = path.open('rb')  # Keep a descriptor open across cache eviction.
            job['used_at'] = time.time(); jobs.write(job)
            size = path.stat().st_size
        def chunks():
            try:
                while data := handle.read(256*1024):
                    yield data
            finally:
                handle.close()
        return StreamingResponse(chunks(), media_type='audio/mp4', headers={
            'Content-Length': str(size), 'Cache-Control': 'private, no-store',
            'ETag': '"' + job['files'][part]['sha256'] + '"'})

    @routes.post('/internal/isolation/claim')
    def claim(authorization: str | None = Header(default=None)):
        worker_auth(authorization)
        return {'job': StemJobs(cache()).claim()}

    @routes.post('/internal/isolation/{identifier}/update')
    def update(identifier: str, body: StemUpdate, authorization: str | None = Header(default=None)):
        worker_auth(authorization)
        with library_lock(cache()):
            jobs = StemJobs(cache()); job = jobs.leased(identifier, body.lease); valid_chart(job)
            jobs.pulse()
            if body.stage == 'ready':
                if set(job['files']) != set(PARTS):
                    raise HTTPException(409, 'Both mixes must be uploaded before publication.')
                if abs(job['files']['solo']['duration'] - job['files']['backing']['duration']) > .025:
                    raise HTTPException(422, 'Instrument mixes are not aligned.')
                job.update(state='ready', used_at=time.time())
            elif body.stage == 'failed':
                messages = {'recording_changed': 'The recording no longer matches this chart. Reanalyze the song.',
                            'unavailable': 'A matching recording is unavailable.',
                            'provider_limit': 'The recording provider is busy. Try again later.'}
                job.update(state='failed', message=messages.get(body.error_code, 'Instrument preparation failed. Try again.'))
            job.update(stage=body.stage, lease_until=time.time()+LEASE_SECONDS)
            jobs.write(job)
            return {'ok': True}

    @routes.put('/internal/isolation/{identifier}/audio/{part}')
    async def upload(identifier: str, part: Literal['solo', 'backing'], request: Request,
                     x_stem_lease: str = Header(), authorization: str | None = Header(default=None)):
        worker_auth(authorization)
        jobs = StemJobs(cache())
        with library_lock(cache()):
            job = jobs.leased(identifier, x_stem_lease); valid_chart(job)
            jobs.reserve(MAX_FILE_BYTES, identifier)
        fd, name = tempfile.mkstemp(prefix='stem-upload-', suffix='.m4a', dir=cache())
        temporary = Path(name)
        try:
            total = 0
            with os.fdopen(fd, 'wb') as handle:
                async for chunk in request.stream():
                    total += len(chunk)
                    if total > MAX_FILE_BYTES:
                        raise HTTPException(413, 'Isolation audio exceeds its size limit.')
                    handle.write(chunk)
            # ffprobe is bounded and runs outside the event loop.
            import anyio
            info = await anyio.to_thread.run_sync(audio_info, temporary)
            with library_lock(cache()):
                job = jobs.leased(identifier, x_stem_lease); valid_chart(job)
                if abs(info['duration'] - job['song']['duration']) > .1:
                    raise HTTPException(422, 'Isolation duration does not match the recording.')
                target = jobs.root / identifier / f'{part}.m4a'
                target.parent.mkdir(parents=True, exist_ok=True)
                temporary.replace(target)
                job['files'][part] = info
                job['lease_until'] = time.time()+LEASE_SECONDS
                jobs.write(job)
            return {'ok': True}
        finally:
            temporary.unlink(missing_ok=True)

    return routes
