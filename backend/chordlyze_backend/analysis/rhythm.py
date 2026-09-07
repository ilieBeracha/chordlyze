"""Bounded resident Beat This process, isolated from API/chord dependencies."""
from __future__ import annotations
import atexit
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import threading
import time
import numpy as np

MODEL = "beat-this-1.1.0-final0-minimal-v1"
CHECKPOINT_SHA256 = "8c328b45f59d8dd3dff219253ff6a8d6482be57d0133a29140e2febbf8eb8331"


def runtime_root() -> Path:
    return Path(os.environ.get('CHORDLYZE_RHYTHM_DIR', str(Path(__file__).resolve().parents[2])))


def checkpoint_path() -> Path:
    return runtime_root()/'rhythm-models/hub/checkpoints/beat_this-final0.ckpt'


class RhythmUnavailable(RuntimeError):
    pass


class RhythmProcess:
    def __init__(self, timeout=180):
        self.timeout = timeout
        self._lock = threading.RLock()
        self._process = None

    def _response(self):
        deadline, data = time.monotonic()+self.timeout, bytearray()
        while True:
            remaining = deadline-time.monotonic()
            if remaining <= 0 or not select.select([self._process.stdout], [], [], remaining)[0]:
                raise RhythmUnavailable('rhythm analysis timed out')
            chunk = os.read(self._process.stdout.fileno(), 65536)
            if not chunk: raise RhythmUnavailable('rhythm worker stopped')
            data.extend(chunk)
            if len(data) > 1024*1024: raise RhythmUnavailable('oversized rhythm response')
            if b'\n' in data:
                result = json.loads(data)
                if not isinstance(result, dict) or 'error' in result:
                    raise RhythmUnavailable(result.get('error', 'invalid rhythm response') if isinstance(result, dict) else 'invalid rhythm response')
                return result

    def _start(self):
        if self._process is not None and self._process.poll() is None: return
        self.close()
        python = runtime_root()/'.venv-rhythm/bin/python'
        if not python.exists() or not checkpoint_path().exists():
            raise RhythmUnavailable('rhythm model not installed; run scripts/setup_rhythm.sh')
        env = dict(os.environ)
        env['PYTHONPATH'] = str(Path(__file__).resolve().parents[2])
        self._process = subprocess.Popen([str(python), '-u', '-m', 'chordlyze_backend.analysis.rhythm_worker'],
            env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        if self._response().get('ready') is not True: raise RhythmUnavailable('rhythm worker not ready')

    def warm(self):
        with self._lock:
            try: self._start()
            except Exception:
                self.close(); raise

    def predict(self, y: np.ndarray):
        if not self._lock.acquire(timeout=self.timeout): raise RhythmUnavailable('rhythm worker busy')
        try:
            self._start()
            with tempfile.TemporaryDirectory(prefix='chordlyze-rhythm-') as temp:
                path = Path(temp)/'audio.npy'
                np.save(path, y.astype(np.float32), allow_pickle=False)
                self._process.stdin.write((json.dumps({'path': str(path)})+'\n').encode())
                self._process.stdin.flush()
                response = self._response()
            for key in ('beats', 'downbeats'):
                values = response.get(key)
                if (not isinstance(values, list) or len(values) > 10000
                        or any(type(t) not in (int, float) or not np.isfinite(t) or t < 0 or t >= len(y)/22050 for t in values)
                        or any(b <= a for a,b in zip(values, values[1:]))):
                    raise RhythmUnavailable('invalid rhythm times')
            return response['beats'], response['downbeats']
        except (OSError, ValueError, RhythmUnavailable) as exc:
            self.close(); raise RhythmUnavailable(str(exc)) from exc
        finally:
            self._lock.release()

    def close(self):
        with self._lock:
            process, self._process = self._process, None
            if process is None: return
            if process.poll() is None:
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait()
            for stream in (process.stdin, process.stdout):
                if stream: stream.close()


worker = RhythmProcess()
atexit.register(worker.close)
