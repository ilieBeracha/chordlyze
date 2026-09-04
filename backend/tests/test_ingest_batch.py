from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import threading
import time

import pytest

import ingest_worker
from chordlyze_backend.fulltrack import fetch_full_track


def test_batch_bounds_concurrency_cleans_files_and_reports_partial_results(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(ingest_worker.LookupThrottle, 'wait', lambda self: None)
    monkeypatch.setattr(ingest_worker, 'itunes_duration', lambda title, artist: None if title == 'missing' else 200)
    active = maximum = 0
    lock = threading.Lock()
    created = []

    def fetch(title, artist, duration):
        nonlocal active, maximum
        if title == 'no upload':
            return None
        with lock:
            active += 1
            maximum = max(maximum, active)
        time.sleep(.02)
        path = tmp_path / title
        path.write_text('audio')
        created.append(path)
        return path

    def submit(audio, item):
        nonlocal active
        with lock:
            active -= 1
        if item['title'] == 'fail':
            raise RuntimeError('submission unavailable')
        return {'chords': [{'end': 200}]}

    monkeypatch.setattr(ingest_worker, 'fetch_full_track', fetch)
    monkeypatch.setattr(ingest_worker, 'submit', submit)
    items = [{'track_id': str(i), 'title': title} for i, title in enumerate(['a', 'b', 'c', 'fail', 'missing', 'no upload'])]
    assert ingest_worker.run_once(items, jobs=2) == 3
    assert maximum == 2
    assert all(not p.exists() for p in created)
    assert '3 updated, 2 skipped, 1 failed, 6 total' in capsys.readouterr().out


def test_throttle_is_shared_across_threads():
    throttle = ingest_worker.LookupThrottle(interval=.03)
    def request(_):
        throttle.wait()
        return time.monotonic()
    with ThreadPoolExecutor(max_workers=3) as pool:
        times = sorted(pool.map(request, range(3)))
    assert times[-1] - times[0] >= .055


def test_same_video_downloads_have_independent_files_and_clean_scratch(tmp_path, monkeypatch):
    import yt_dlp
    import tempfile
    monkeypatch.setattr(tempfile, 'tempdir', str(tmp_path))

    class Downloader:
        def __init__(self, options): self.options = options
        def __enter__(self): return self
        def __exit__(self, *args): pass
        def extract_info(self, url, download):
            if not download:
                return {'entries': [{'id': 'same', 'title': 'Song', 'channel': 'Band', 'duration': 200}]}
            self.path = Path(self.options['outtmpl'].replace('%(id)s', 'same').replace('%(ext)s', 'wav'))
            self.path.write_bytes(b'audio')
            return {}
        def prepare_filename(self, result): return str(self.path)

    monkeypatch.setattr(yt_dlp, 'YoutubeDL', Downloader)
    with ThreadPoolExecutor(max_workers=2) as pool:
        paths = list(pool.map(lambda _: fetch_full_track('Song', 'Band', 200), range(2)))
    try:
        assert paths[0] != paths[1]
        assert all(p.read_bytes() == b'audio' for p in paths)
        assert not list(tmp_path.glob('chordlyze-download-*'))
    finally:
        for path in paths: path.unlink()


def test_bad_parallelism_is_rejected():
    with pytest.raises(ValueError):
        ingest_worker.run_once([], jobs=0)
