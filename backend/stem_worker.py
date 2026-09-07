"""Dedicated isolation queue worker; never occupies the chord-analysis worker."""
from __future__ import annotations
import hashlib
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import threading
import time
import wave
import requests
from dotenv import load_dotenv
from chordlyze_backend.fulltrack import fetch_full_track


def fingerprint(source: Path, directory: Path) -> str:
    decoded = directory / 'identity.wav'
    subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-y', '-i', str(source), '-vn', '-ac', '1',
                    '-ar', '44100', '-acodec', 'pcm_s16le', str(decoded)], check=True, timeout=120)
    digest = hashlib.sha256()
    with wave.open(str(decoded), 'rb') as audio:
        while chunk := audio.readframes(65536):
            digest.update(chunk)
    decoded.unlink()
    return digest.hexdigest()


class Client:
    def __init__(self, base, token):
        self.base = base.rstrip('/')
        self.headers = {'Authorization': 'Bearer ' + token}

    def post(self, path, body=None):
        response = requests.post(self.base+path, headers=self.headers, json=body or {}, timeout=(10, 30))
        response.raise_for_status()
        return response.json()

    def upload(self, path, lease, file):
        with file.open('rb') as data:
            response = requests.put(self.base+path, headers={**self.headers, 'X-Stem-Lease': lease,
                                    'Content-Type': 'audio/mp4'}, data=data, timeout=(10, 120))
        response.raise_for_status()


def process(client, job, stopping):
    endpoint = '/internal/isolation/' + job['id']
    stage = 'downloading'
    last_heartbeat = time.monotonic()
    finished, lost = threading.Event(), threading.Event()
    def update(value, **extra):
        return client.post(endpoint+'/update', {'lease': job['lease'], 'stage': value, **extra})
    def heartbeat():
        nonlocal last_heartbeat
        while not finished.wait(15):
            try:
                update(stage)
                last_heartbeat = time.monotonic()
            except requests.HTTPError as error:
                if error.response.status_code in (401, 404, 409):
                    lost.set(); return
            except requests.RequestException:
                pass
            if time.monotonic() - last_heartbeat > 150:
                lost.set(); return
    thread = threading.Thread(target=heartbeat, daemon=True)
    thread.start()
    source = None
    child = None
    try:
        song = job['song']
        previous = song.get('audio_source') or {}
        candidate = {'id': previous.get('video_id'), 'title': previous.get('title'),
                     'channel': previous.get('channel'), 'duration': previous.get('duration')}
        source = fetch_full_track(song['title'], song.get('artist') or '', song['duration'], isrc=song.get('isrc'),
                                  checkpoint={'candidate': candidate} if candidate['id'] else {},
                                  cancelled=lambda: stopping.is_set() or lost.is_set())
        if source is None:
            update('failed', error_code='unavailable'); return
        with tempfile.TemporaryDirectory(prefix='chordlyze-stems-') as temporary:
            directory = Path(temporary)
            if fingerprint(source, directory) != job['audio_sha256']:
                update('failed', error_code='recording_changed'); return
            stage = 'separating'; update(stage)
            runtime = Path(os.environ.get('CHORDLYZE_STEMS_DIR', Path(__file__).parent / '.stems'))
            environment = {**os.environ, 'TORCH_HOME': str(runtime / 'torch')}
            child = subprocess.Popen([str(runtime / 'venv/bin/python'), '-m', 'chordlyze_backend.analysis.stem_worker',
                                      str(source), str(directory), job['instrument']], env=environment)
            deadline = time.monotonic()+3600
            while child.poll() is None:
                if stopping.wait(1) or lost.is_set() or time.monotonic() > deadline:
                    raise RuntimeError('Separation interrupted')
            if child.returncode:
                raise RuntimeError('Separation failed')
            stage = 'uploading'; update(stage)
            for part in ('solo', 'backing'):
                client.upload(endpoint+'/audio/'+part, job['lease'], directory / f'{part}.m4a')
            # Stop heartbeats before publishing so no stale processing update races ready.
            finished.set(); thread.join(timeout=35)
            update('ready')
    except Exception as error:
        print(f"isolation {job['id']}: {type(error).__name__}", flush=True)
        if not stopping.is_set() and not lost.is_set():
            try:
                update('failed', error_code='processing_failed')
            except requests.RequestException:
                pass
    finally:
        finished.set(); thread.join(timeout=35)
        if child is not None and child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                child.kill(); child.wait()
        if source:
            source.unlink(missing_ok=True)


def main():
    load_dotenv()
    client = Client(os.environ['CHORDLYZE_API_URL'], os.environ['CHORDLYZE_WORKER_TOKEN'])
    stopping = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stopping.set())
    while not stopping.is_set():
        try:
            job = client.post('/internal/isolation/claim')['job']
            if job:
                process(client, job, stopping)
                continue
        except requests.RequestException as error:
            print(f'Isolation queue unavailable: {type(error).__name__}', flush=True)
        stopping.wait(5)


if __name__ == '__main__':
    main()
