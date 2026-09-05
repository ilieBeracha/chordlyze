import asyncio
from concurrent.futures import ThreadPoolExecutor
import json

from fastapi import HTTPException
import pytest

from chordlyze_backend import main, song_jobs
from chordlyze_backend.analysis.engine import ChordSegment, Recognition
from chordlyze_backend.analysis.provenance import model_metadata
from chordlyze_backend.song_jobs import SongJobs, generation, reset_library
import song_worker


@pytest.fixture(autouse=True)
def cache(tmp_path, monkeypatch):
    monkeypatch.setattr(main, 'CACHE_DIR', tmp_path)
    monkeypatch.delenv('CHORDLYZE_WORKER_TOKEN', raising=False)
    return tmp_path


def request(**extra):
    return main.SongRequest(track_id='song', title='Song', artist='Band', album='Album', duration=200, **extra)


def payload(job):
    return main.SubmittedAnalysis(track_id='song', title='Song', artist='Band', album='Album',
        song_duration=200, **model_metadata('ismir2019'), audio_duration=200, audio_sha256='a' * 64,
        segments=[main.SubmittedSegment(start=0, end=200, label='C:maj7')],
        job_id=job['id'], lease=job['lease'], library_generation=job['generation'])


def test_request_is_fast_deduplicated_and_never_creates_preview(cache):
    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda _: main.request_song(request()), range(20)))
    assert all(result['analysis'] is None and result['job']['state'] == 'queued' for result in results)
    assert len(list(cache.glob('job-*.json'))) == 1
    assert main.library()['items'] == []
    job = SongJobs(cache).claim()
    assert job['song']['album'] == 'Album' and job['song']['duration'] == 200
    assert SongJobs(cache).claim() is None


def test_worker_requires_token(cache, monkeypatch):
    with pytest.raises(HTTPException) as error:
        main.claim_song(None)
    assert error.value.status_code == 503
    monkeypatch.setenv('CHORDLYZE_WORKER_TOKEN', 'test-worker-secret')
    with pytest.raises(HTTPException) as error:
        main.claim_song('Bearer wrong')
    assert error.value.status_code == 401
    assert main.claim_song('Bearer test-worker-secret') == {'job': None}
    assert main.health()['song_worker_online'] is True


def test_completed_chart_updates_same_song_and_preserves_recording_metadata(cache, monkeypatch):
    main.request_song(request())
    job = SongJobs(cache).claim()
    monkeypatch.setenv('CHORDLYZE_WORKER_TOKEN', 'token')
    main.submit_analysis(payload(job), 'Bearer token')
    result = main.song_status('song')
    assert result['job']['state'] == 'ready'
    assert result['analysis']['chords'][0]['label'] == 'C:maj7'
    assert result['song']['duration'] == 200 and result['song']['album'] == 'Album'
    assert main.library()['items'][0]['duration'] == 200


def test_reset_rejects_old_leases_and_removes_analyses_aliases_lyrics_jobs(cache, monkeypatch):
    main.request_song(request())
    job = SongJobs(cache).claim()
    for name in ['track-old', 'isrc-old', 'lyrics4-old', 'lyrics5-old']:
        (cache / f'{name}.json').write_text('{}')
    (cache / 'unrelated.txt').write_text('keep')
    before = generation(cache)
    assert reset_library(cache)['applied'] is False
    assert (cache / 'track-old.json').exists()
    result = reset_library(cache, apply=True)
    assert result['analyses'] == 1 and generation(cache) != before
    assert not list(cache.glob('*.json'))
    assert (cache / 'unrelated.txt').read_text() == 'keep'
    monkeypatch.setenv('CHORDLYZE_WORKER_TOKEN', 'token')
    with pytest.raises(HTTPException) as error:
        main.submit_analysis(payload(job), 'Bearer token')
    assert error.value.status_code == 409
    assert main.library()['items'] == []
    assert main.song_status('song')['job']['state'] == 'missing'


def test_legacy_worker_cannot_restore_library_in_production(cache, monkeypatch):
    main.request_song(request())
    job = SongJobs(cache).claim()
    monkeypatch.setenv('CHORDLYZE_WORKER_TOKEN', 'token')
    with pytest.raises(HTTPException) as error:
        main.submit_analysis(payload(job), None)
    assert error.value.status_code == 401
    assert main.library()['items'] == []


def test_expired_lease_requeues_and_stale_worker_cannot_complete(cache, monkeypatch):
    now = [1000.0]
    monkeypatch.setattr(song_jobs.time, 'time', lambda: now[0])
    jobs = SongJobs(cache)
    jobs.request(request().model_dump(exclude={'retry'}))
    first = jobs.claim()
    now[0] += 181
    second = jobs.claim()
    assert second['lease'] != first['lease'] and second['attempts'] == 2
    assert not jobs.finish('song', first['id'], first['lease'], first['generation'], 'ready')
    assert jobs.heartbeat(second['id'], second['lease'], 'analyzing')


def test_exhausted_jobs_stop_retrying_until_user_retries(cache, monkeypatch):
    now = [1000.0]
    monkeypatch.setattr(song_jobs.time, 'time', lambda: now[0])
    jobs = SongJobs(cache)
    song = request().model_dump(exclude={'retry'})
    jobs.request(song)
    for _ in range(3):
        assert jobs.claim() is not None
        now[0] += 181
    assert jobs.claim() is None
    assert jobs.get('song')['state'] == 'failed'
    jobs.request(song, retry=True)
    assert jobs.claim()['attempts'] == 1


def test_legacy_analysis_request_queues_whole_song_instead_of_unknown_offset_preview(cache, monkeypatch):
    monkeypatch.setattr(main, '_itunes_lookup', lambda *args: pytest.fail('must not analyze a preview'))
    with pytest.raises(HTTPException) as error:
        asyncio.run(main.analyze_track('song', None, 'Song', 'Band', 200, None))
    assert error.value.status_code == 202
    assert main.song_status('song')['job']['state'] == 'queued'
    assert not list(cache.glob('track-*.json'))


@pytest.mark.parametrize('failure', [False, True])
def test_worker_uses_lease_and_cleans_audio_on_success_and_failure(cache, monkeypatch, failure):
    audio = cache / 'download.wav'
    audio.write_bytes(b'test')
    monkeypatch.setattr(song_worker, 'fetch_full_track', lambda *args, **kwargs: audio)
    def recognize(*args, **kwargs):
        if failure:
            raise RuntimeError('inference failed')
        return Recognition([ChordSegment(0, 200, 'C:maj7')], 200, 'a' * 64, 'ismir2019')
    monkeypatch.setattr(song_worker, 'recognize_audio', recognize)
    monkeypatch.setattr(song_worker, 'track_beats', lambda _: None)
    main.request_song(request())
    job = SongJobs(cache).claim()
    class Client:
        def __init__(self): self.calls = []
        def post(self, path, payload=None): self.calls.append((path, payload)); return {}
    client = Client()
    assert song_worker.process_job(client, job) == ('failed' if failure else 'ready')
    assert not audio.exists()
    path, body = client.calls[-1]
    assert body['lease'] == job['lease'] and body['library_generation'] == job['generation']
    assert path == ('/internal/jobs/finish' if failure else '/analysis/submit')


def test_missing_audio_is_reported_as_unavailable(cache, monkeypatch):
    monkeypatch.setattr(song_worker, 'fetch_full_track', lambda *args, **kwargs: None)
    main.request_song(request())
    job = SongJobs(cache).claim()
    class Client:
        def post(self, path, body):
            assert path == '/internal/jobs/finish' and body['state'] == 'unavailable'
    assert song_worker.process_job(Client(), job) == 'unavailable'


def test_queue_position_counts_only_earlier_unfinished_requests(tmp_path, monkeypatch):
    now = [1000]
    monkeypatch.setattr(song_jobs.time, 'time', lambda: now[0])
    jobs = song_jobs.SongJobs(tmp_path)
    for name in ('first', 'second', 'third'):
        now[0] += 1
        jobs.request({'track_id': name, 'title': name, 'artist': 'Band', 'duration': 200})
    assert jobs.public(jobs.get('third'))['ahead'] == 2
    assert jobs.public(jobs.get('first'))['ahead'] == 0
    claimed = jobs.claim()  # first is now processing: still ahead of the others
    assert claimed['song']['track_id'] == 'first'
    assert jobs.public(jobs.get('third'))['ahead'] == 2
    jobs.finish('first', claimed['id'], claimed['lease'], claimed['generation'], 'failed')
    assert jobs.public(jobs.get('third'))['ahead'] == 1
    assert 'ahead' not in jobs.public(jobs.get('first'))
