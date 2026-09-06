"""Real HTTP request/lease/publish/reset lifecycle, with synthetic chart data."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

import pytest

from chordlyze_backend.analysis.provenance import model_metadata
from chordlyze_backend.song_jobs import SongJobs, reset_library
from song_worker import WorkerClient
from tests.fake_spotify import fake_spotify


def test_song_request_to_ready_and_reset_over_http(tmp_path):
    backend = Path(__file__).resolve().parents[1]
    with fake_spotify() as me_url, socket.socket() as listener, (tmp_path / 'server.log').open('w+') as log:
        env = {**os.environ, 'PYTHONPATH': str(backend), 'CHORDLYZE_CACHE': str(tmp_path / 'cache'),
               'CHORDLYZE_WORKER_TOKEN': 'local-test-only', 'CHORDLYZE_SPOTIFY_ME_URL': me_url}
        listener.bind(('127.0.0.1', 0))
        listener.listen()
        url = f'http://127.0.0.1:{listener.getsockname()[1]}'
        process = subprocess.Popen([sys.executable, '-m', 'uvicorn', 'chordlyze_backend.main:app',
                                    '--fd', str(listener.fileno()), '--log-level', 'warning'],
                                   env=env, cwd=backend, pass_fds=(listener.fileno(),), stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 30
            while True:
                try:
                    with urllib.request.urlopen(url + '/health', timeout=.5): break
                except OSError:
                    if process.poll() is not None or time.monotonic() > deadline:
                        pytest.fail('HTTP fixture failed to start')
                    time.sleep(.1)
            public = WorkerClient(url, 'listener')   # a signed-in app user; the fake Spotify maps token -> id
            worker = WorkerClient(url, 'local-test-only')

            def fetch(path, token='listener'):
                request = urllib.request.Request(url + path, headers={'Authorization': 'Bearer ' + token})
                with urllib.request.urlopen(request) as response:
                    return json.load(response)

            with pytest.raises(urllib.error.HTTPError) as signed_out:
                WorkerClient(url, '').post('/song/request', {'track_id': 'x', 'title': 'x'})
            assert signed_out.value.code == 401
            with pytest.raises(urllib.error.HTTPError) as expired:
                WorkerClient(url, 'bad').post('/song/request', {'track_id': 'x', 'title': 'x'})
            assert expired.value.code == 401
            request = {'track_id': 'synthetic', 'title': 'Synthetic test', 'artist': 'Test', 'duration': 8}
            pending = public.post('/song/request', request)
            assert pending['analysis'] is None and pending['job']['state'] == 'queued'
            with pytest.raises(urllib.error.HTTPError) as denied:
                public.post('/internal/jobs/claim')
            assert denied.value.code == 401
            job = worker.post('/internal/jobs/claim')['job']
            identity = {'track_id': 'synthetic', 'job_id': job['id'], 'lease': job['lease'],
                        'library_generation': job['generation']}
            checkpoint = {'search_run_id': 'search123', 'run_id': 'run123', 'video_id': 'abcdefghijk',
                          'candidate': {'id': 'abcdefghijk', 'title': 'Synthetic test',
                                        'channel': 'Test', 'duration': 8}}
            worker.post('/internal/jobs/heartbeat', {**identity, 'stage': 'downloading',
                                                     'download_checkpoint': checkpoint})
            with pytest.raises(urllib.error.HTTPError) as malformed:
                worker.post('/internal/jobs/heartbeat', {**identity,
                    'download_checkpoint': {'run_id': 'https://invalid.test'}})
            assert malformed.value.code == 422
            worker.post('/internal/jobs/heartbeat', {**identity, 'stage': 'analyzing'})
            assert SongJobs(tmp_path / 'cache').get('synthetic')['download_checkpoint'] == checkpoint
            assert 'download_checkpoint' not in fetch('/song/synthetic')['job']
            lyrics = {'track_id': 'synthetic', 'library_generation': job['generation'], 'aligner': 'test',
                      'lines': [{'time': 1, 'text': 'Hello there',
                                 'words': [{'time': 1, 'text': 'Hello'}, {'time': 1.6, 'text': 'there'}]},
                                {'time': 5, 'text': 'Goodbye'}]}
            with pytest.raises(urllib.error.HTTPError) as early:
                worker.post('/internal/jobs/lyrics', lyrics)
            assert early.value.code == 404
            submission = {**identity, **model_metadata('ismir2019'), 'title': 'Synthetic test',
                          'audio_duration': 8, 'song_duration': 8, 'audio_sha256': 'a' * 64,
                          'source': 'youtube', 'segments': [{'start': 0, 'end': 8, 'label': 'C:maj7'}]}
            worker.post('/analysis/submit', submission)
            ready = fetch('/song/synthetic')
            assert ready['job']['state'] == 'ready'
            assert ready['analysis']['chords'][0]['label'] == 'C:maj7'
            assert ready['lyrics'] is None
            assert ready['saved'] is True, 'requesting the song put it in the listener\'s library'
            assert [i['track_id'] for i in fetch('/library')['items']] == ['synthetic']
            assert fetch('/library', token='someone-else')['items'] == [], 'another account has its own list'
            assert [i['track_id'] for i in fetch('/catalog', token='someone-else')['items']] == ['synthetic'], 'the chart is global'
            assert public.post('/song/request', request)['job']['state'] == 'ready'
            with pytest.raises(urllib.error.HTTPError) as anonymous:
                public.post('/internal/jobs/lyrics', lyrics)
            assert anonymous.value.code == 401
            with pytest.raises(urllib.error.HTTPError) as unordered:
                worker.post('/internal/jobs/lyrics', {**lyrics, 'lines': lyrics['lines'][::-1]})
            assert unordered.value.code == 422
            assert worker.post('/internal/jobs/lyrics', lyrics)['lines'] == 2
            timed = fetch('/song/synthetic')['lyrics']
            assert timed['synced'] and timed['matched'] == 'aligned'
            assert timed['lines'][0]['words'][1]['text'] == 'there' and 'words' not in timed['lines'][1]
            assert worker.post('/internal/jobs/lyrics', {**lyrics, 'source': 'transcribed'})['lines'] == 2
            assert fetch('/song/synthetic')['lyrics']['matched'] == 'transcribed'
            with pytest.raises(urllib.error.HTTPError) as bad_source:
                worker.post('/internal/jobs/lyrics', {**lyrics, 'source': 'guessed'})
            assert bad_source.value.code == 422
            reset_library(tmp_path / 'cache', apply=True)
            with pytest.raises(urllib.error.HTTPError) as after_reset:
                worker.post('/internal/jobs/lyrics', lyrics)
            assert after_reset.value.code == 409
            with pytest.raises(urllib.error.HTTPError) as stale:
                worker.post('/analysis/submit', submission)
            assert stale.value.code == 409
            assert fetch('/library')['items'] == []
            fresh = public.post('/song/request', request)
            assert fresh['library_generation'] != ready['library_generation']
            assert fresh['job']['state'] == 'queued'
        finally:
            process.terminate()
            try: process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
