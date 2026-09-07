import hashlib
import json
from pathlib import Path
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor

from fastapi.testclient import TestClient
import pytest
from chordlyze_backend import main
from chordlyze_backend.auth import current_user
from chordlyze_backend.stems import StemJobs, audio_info
from chordlyze_backend.song_jobs import library_lock, reset_library
import stem_worker


@pytest.fixture
def api(tmp_path, monkeypatch):
    monkeypatch.setattr(main, 'CACHE_DIR', tmp_path)
    monkeypatch.setenv('CHORDLYZE_WORKER_TOKEN', 'worker-secret')
    main.app.dependency_overrides[current_user] = lambda: 'tester'
    chart = {'title': 'Test song', 'artist': 'Test artist', 'audio_sha256': 'a'*64,
             'audio_duration': 2, 'audio_source': {'url': 'private-source'}}
    main._track_cache_path('song').write_text(json.dumps(chart))
    with TestClient(main.app) as client:
        yield client, tmp_path
    main.app.dependency_overrides.clear()


@pytest.fixture(scope='module')
def audio(tmp_path_factory):
    path = tmp_path_factory.mktemp('audio') / 'test.m4a'
    subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-y', '-f', 'lavfi', '-i',
                    'sine=frequency=440:duration=2', '-ac', '2', '-ar', '44100', '-c:a', 'aac', str(path)], check=True)
    return path.read_bytes()


AUTH = {'Authorization': 'Bearer worker-secret'}


def prepare(client, instrument='guitar', retry=False):
    return client.post('/song/song/isolation', json={'instrument': instrument, 'retry': retry})


def claim(client):
    return client.post('/internal/isolation/claim', headers=AUTH).json()['job']


def upload(client, job, part, audio, **headers):
    return client.put(f"/internal/isolation/{job['id']}/audio/{part}",
                      headers={**AUTH, 'X-Stem-Lease': job['lease'], **headers}, content=audio)


def update(client, job, stage):
    return client.post(f"/internal/isolation/{job['id']}/update", headers=AUTH,
                       json={'lease': job['lease'], 'stage': stage})


def test_complete_authenticated_pipeline(api, audio):
    client, directory = api
    result = prepare(client).json()
    assert result['state'] == 'queued' and not result['worker_online']
    assert not {'song', 'owner', 'lease', 'generation'} & result.keys()
    job = claim(client)
    assert job['id'] == result['id']
    assert update(client, job, 'ready').status_code == 409
    assert upload(client, job, 'solo', audio).status_code == 200
    assert update(client, job, 'ready').status_code == 409
    assert upload(client, job, 'backing', audio).status_code == 200
    assert update(client, job, 'ready').status_code == 200
    status = client.get('/isolation/'+job['id']).json()
    assert status['state'] == 'ready' and status['worker_online']
    assert status['files']['solo']['sha256'] == hashlib.sha256(audio).hexdigest()
    response = client.get(f"/isolation/{job['id']}/audio/solo")
    assert response.content == audio and response.headers['cache-control'] == 'private, no-store'
    assert prepare(client, retry=True).json()['id'] == job['id']
    assert update(client, job, 'separating').status_code == 409


def test_auth_and_validation(api, audio):
    client, directory = api
    assert prepare(client, 'violin').status_code == 422
    job = prepare(client).json()
    assert client.post('/internal/isolation/claim').status_code == 401
    worker = claim(client)
    assert upload(client, worker, 'solo', audio, **{'X-Stem-Lease': 'b'*32}).status_code == 409
    assert upload(client, worker, 'solo', b'garbage').status_code == 422
    assert client.get('/isolation/not-an-id').status_code == 404
    main.app.dependency_overrides.clear()
    assert prepare(client).status_code == 401
    assert client.get('/isolation/'+job['id']).status_code == 401
    assert client.get(f"/isolation/{job['id']}/audio/solo").status_code == 401


def test_retry_returns_latest_job_and_is_deduplicated(api):
    client, directory = api
    first = prepare(client).json(); job = claim(client)
    assert update(client, job, 'failed').status_code == 200
    second = prepare(client, retry=True).json()
    assert first['id'] != second['id']
    assert prepare(client).json()['id'] == second['id']
    assert prepare(client, retry=True).json()['id'] == second['id']


def test_concurrent_prepare_and_queue_cap(api):
    client, directory = api
    queue = StemJobs(directory)
    song = {'track_id': 'song', 'audio_sha256': 'a'*64, 'duration': 2}
    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda _: queue.request(song, 'guitar', 'tester'), range(20)))
    assert len({job['id'] for job in results}) == 1
    # API owner hashes differ from the test queue owner.
    for instrument in ('bass', 'drums', 'vocals'):
        assert prepare(client, instrument).status_code == 200
    assert prepare(client, 'piano').status_code == 429


def test_lease_recovery_rejects_old_worker(api, audio):
    client, directory = api
    prepare(client); first = claim(client)
    assert upload(client, first, 'solo', audio).status_code == 200
    queue = StemJobs(directory)
    with library_lock(directory):
        stale = queue.get(first['id']); stale['lease_until'] = time.time()-1; queue.write(stale)
    second = claim(client)
    assert second['id'] == first['id'] and second['lease'] != first['lease']
    assert second['files'] == {}
    assert update(client, first, 'ready').status_code == 409
    assert upload(client, first, 'backing', audio).status_code == 409


def test_chart_change_and_reset_reject_stale_audio(api, audio):
    client, directory = api
    prepare(client); job = claim(client)
    chart_path = main._track_cache_path('song')
    chart = json.loads(chart_path.read_text()); chart['audio_sha256'] = 'b'*64
    chart_path.write_text(json.dumps(chart))
    assert upload(client, job, 'solo', audio).status_code == 409
    assert client.get('/isolation/'+job['id']).status_code == 409
    reset_library(directory, apply=True)
    assert update(client, job, 'ready').status_code in (404, 409)


def test_wrong_duration_rejected_and_cache_loss_recoverable(api, audio):
    client, directory = api
    chart_path = main._track_cache_path('song')
    chart = json.loads(chart_path.read_text()); chart['audio_duration'] = 4
    chart_path.write_text(json.dumps(chart))
    prepare(client); job = claim(client)
    assert upload(client, job, 'solo', audio).status_code == 422
    assert not list(directory.glob('stem-upload-*'))
    queue = StemJobs(directory)
    with library_lock(directory):
        value = queue.get(job['id']); value.update(state='ready', files={}); queue.write(value)
    assert client.get('/isolation/'+job['id']).json()['state'] == 'expired'
    assert prepare(client, retry=True).json()['id'] != job['id']


def test_source_identity_failure_never_runs_model(api, tmp_path, monkeypatch):
    client, directory = api
    prepare(client); job = claim(client)
    original = tmp_path / 'source.wav'; original.write_bytes(b'fixture')
    monkeypatch.setattr(stem_worker, 'fetch_full_track', lambda *args, **kwargs: original)
    monkeypatch.setattr(stem_worker, 'fingerprint', lambda *_: 'b'*64)
    monkeypatch.setattr(stem_worker.subprocess, 'Popen', lambda *a, **k: pytest.fail('mismatched source reached model'))
    class Worker:
        def post(self, path, body):
            response = client.post(path, headers=AUTH, json=body)
            assert response.status_code == 200
            return response.json()
    stem_worker.process(Worker(), job, threading.Event())
    status = client.get('/isolation/'+job['id']).json()
    assert status['state'] == 'failed' and 'Reanalyze' in status['message']
    assert not original.exists()


def test_fingerprint_matches_analysis_pcm(tmp_path):
    import wave
    source = tmp_path / 'test.wav'
    with wave.open(str(source), 'wb') as output:
        output.setnchannels(1); output.setsampwidth(2); output.setframerate(44100)
        pcm = b'\x11\x01\x23\x00' * 44100
        output.writeframes(pcm)
    assert stem_worker.fingerprint(source, tmp_path) == hashlib.sha256(pcm).hexdigest()


def test_oversize_upload_is_removed(api, audio, monkeypatch):
    from chordlyze_backend import stems
    client, directory = api
    prepare(client); job = claim(client)
    monkeypatch.setattr(stems, 'MAX_FILE_BYTES', 32)
    assert upload(client, job, 'solo', audio).status_code == 413
    assert not list(directory.glob('stem-upload-*'))
    assert StemJobs(directory).get(job['id'])['files'] == {}


def test_cache_eviction_expires_old_audio(api, audio, monkeypatch):
    from chordlyze_backend import stems
    client, directory = api
    monkeypatch.setattr(stems, 'MAX_FILE_BYTES', len(audio)+1)
    monkeypatch.setattr(stems, 'CACHE_BYTES', len(audio)*3)
    prepare(client); first = claim(client)
    for part in ('solo', 'backing'):
        assert upload(client, first, part, audio).status_code == 200
    assert update(client, first, 'ready').status_code == 200
    prepare(client, 'bass'); second = claim(client)
    assert upload(client, second, 'solo', audio).status_code == 200
    assert client.get('/isolation/'+first['id']).json()['state'] == 'expired'
    assert not (directory/'stems'/first['id']).exists()


def test_missing_recording_identity_requires_reanalysis(api):
    client, directory = api
    path = main._track_cache_path('song')
    chart = json.loads(path.read_text()); chart['audio_sha256'] = None
    path.write_text(json.dumps(chart))
    response = prepare(client)
    assert response.status_code == 409 and 'Reanalyze' in response.json()['detail']


def test_repeated_worker_failure_stops_after_three_attempts(api):
    client, directory = api
    prepare(client)
    queue = StemJobs(directory)
    for attempt in range(3):
        job = claim(client)
        assert job['attempts'] == attempt+1
        with library_lock(directory):
            job['lease_until'] = 0; queue.write(job)
    assert claim(client) is None
    assert client.get('/isolation/'+job['id']).json()['state'] == 'failed'
