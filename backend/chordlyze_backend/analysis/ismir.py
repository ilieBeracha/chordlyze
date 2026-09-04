"""Serialized, resident ISMIR inference isolated from the API's dependencies."""
from __future__ import annotations

import atexit
import json
import os
import select
import subprocess
import threading
import time
from pathlib import Path


class RecognitionUnavailable(RuntimeError):
    pass


def model_directory() -> Path:
    return Path(os.environ.get("CHORDLYZE_ISMIR_DIR", "~/.chordlyze/ismir2019")).expanduser()


def ismir_available() -> bool:
    root = model_directory()
    return (root / "chord_recognition.py").is_file() and (root / ".venv/bin/python").is_file()


class IsmirProcess:
    def __init__(self, timeout: float = 600):
        self.timeout = timeout
        self._lock = threading.RLock()
        self._process: subprocess.Popen | None = None

    def _response(self) -> dict:
        deadline = time.monotonic() + self.timeout
        data = bytearray()
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self._process.stdout], [], [], remaining)[0]:
                raise RecognitionUnavailable("chord recognition timed out")
            chunk = os.read(self._process.stdout.fileno(), 65536)
            if not chunk:
                raise RecognitionUnavailable("chord recognizer stopped unexpectedly")
            data.extend(chunk)
            if len(data) > 16 * 1024 * 1024:
                raise RecognitionUnavailable("invalid response from chord recognizer")
            if b"\n" in data:
                response = json.loads(data)
                if not isinstance(response, dict):
                    raise RecognitionUnavailable("invalid response from chord recognizer")
                if "error" in response:
                    raise RecognitionUnavailable(str(response["error"]))
                return response

    def _start(self) -> None:
        if self._process is not None and self._process.poll() is None:
            return
        self.close()
        root = model_directory()
        if not ismir_available():
            raise RecognitionUnavailable("rich chord model is not installed; run scripts/setup_ismir.sh")
        env = dict(os.environ)
        backend = str(Path(__file__).resolve().parents[2])
        env["PYTHONPATH"] = os.pathsep.join(filter(None, [backend, env.get("PYTHONPATH")]))
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        self._process = subprocess.Popen(
            [str(root / ".venv/bin/python"), "-u", "-m", "chordlyze_backend.analysis.ismir_worker"],
            cwd=root, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )
        if self._response().get("ready") is not True:
            raise RecognitionUnavailable("chord recognizer did not initialize")

    def recognize(self, wav: Path) -> list:
        if not self._lock.acquire(timeout=self.timeout):
            raise RecognitionUnavailable("chord recognizer is busy; try again shortly")
        try:
            self._start()
            self._process.stdin.write((json.dumps({"path": str(wav.resolve())}) + "\n").encode())
            self._process.stdin.flush()
            result = self._response()
            if not isinstance(result.get("segments"), list):
                raise RecognitionUnavailable("invalid segments from chord recognizer")
            return result["segments"]
        except (OSError, ValueError, RecognitionUnavailable) as exc:
            self.close()
            raise RecognitionUnavailable(str(exc)) from exc
        finally:
            self._lock.release()

    def close(self) -> None:
        with self._lock:
            proc, self._process = self._process, None
            if proc is None:
                return
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
            for stream in (proc.stdin, proc.stdout):
                if stream:
                    stream.close()


_worker = IsmirProcess()
atexit.register(_worker.close)


def recognize(wav: Path) -> list:
    return _worker.recognize(wav)


def close() -> None:
    _worker.close()
