from pathlib import Path
import threading

import pytest
import requests

from chordlyze_backend import audio_apify as cloud, fulltrack, main, song_jobs
from chordlyze_backend.audio_apify import ApifyAudio, AudioProviderError, DownloadCancelled
import song_worker

VIDEO = 'abcdefghijk'
CANDIDATE = {'id': VIDEO, 'title': 'Song', 'channel': 'Band - Topic', 'duration': 200}
URL = f'https://api.apify.com/v2/key-value-stores/store123/records/{VIDEO}.mp3'
RUN = {'id': 'run123', 'status': 'SUCCEEDED', 'defaultDatasetId': 'dataset123', 'buildId': 'build123'}


class Response:
    def __init__(self, data=None, *, status=200, chunks=(b'audio',), headers=None):
        self.data, self.status_code, self.chunks = data, status, chunks
        self.headers = {'Content-Type': 'audio/mpeg'} if headers is None else headers
    def __enter__(self): return self
    def __exit__(self, *args): pass
    def json(self): return self.data
    def iter_content(self, _size): yield from self.chunks


class Session:
    def __init__(self, *responses): self.responses, self.calls = list(responses), []
    def request(self, method, url, **kwargs):
        self.calls.append((method, url, kwargs))
        value = self.responses.pop(0)
        if isinstance(value, Exception): raise value
        return value


@pytest.fixture(autouse=True)
def isolated(tmp_path, monkeypatch):
    monkeypatch.setattr(cloud.tempfile, 'tempdir', str(tmp_path))
    monkeypatch.delenv('CHORDLYZE_AUDIO_PROVIDER', raising=False)
    for name in ('CHORDLYZE_APIFY_TIMEOUT', 'CHORDLYZE_APIFY_MAX_CHARGE_USD', 'CHORDLYZE_AUDIO_MAX_MB'):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setattr(cloud.time, 'sleep', lambda _: None)


def items(**override):
    return [{'id': VIDEO, 'durationSeconds': 200, 'downloadedFileUrl': URL, **override}]


def test_cloud_download_uses_stored_file_and_keeps_token_off_media_request(monkeypatch):
    api = Session(Response({'data': {**RUN, 'status': 'RUNNING'}}),
                  Response({'data': RUN}), Response(items()))
    media = []
    monkeypatch.setattr(cloud.requests, 'get', lambda url, **kw: media.append((url, kw)) or Response())
    saved, provenance = [], {}
    path = ApifyAudio('private-token', session=api).download(CANDIDATE, 200,
        save_checkpoint=saved.append, source_info=provenance)
    assert path.read_bytes() == b'audio'
    assert saved[0]['run_id'] == 'run123'
    assert api.calls[0][2]['params']['maxTotalChargeUsd'] == 1
    assert api.calls[0][2]['params']['timeout'] == 300
    assert api.calls[0][2]['json']['storeInKVStore'] is True
    assert 'headers' not in media[0][1] and media[0][1]['allow_redirects'] is False
    assert provenance['provider'] == 'apify' and provenance['build_id'] == 'build123'


def test_restart_reuses_existing_paid_run_without_starting_another(monkeypatch):
    api = Session(Response({'data': RUN}), Response(items()))
    monkeypatch.setattr(cloud.requests, 'get', lambda *a, **kw: Response())
    ApifyAudio('token', session=api).download(CANDIDATE, 200,
        checkpoint={'video_id': VIDEO, 'run_id': 'run123'})
    assert all(method == 'GET' for method, _, _ in api.calls)


@pytest.mark.parametrize('response', [None, [], {}, {'data': None}, {'data': {'id': 'another-run'}}])
def test_malformed_resume_does_not_launch_another_paid_run(response):
    api = Session(Response(response))
    with pytest.raises(AudioProviderError, match='provider_response'):
        ApifyAudio('token', session=api).download(CANDIDATE, 200,
            checkpoint={'video_id': VIDEO, 'run_id': 'run123'})
    assert len(api.calls) == 1 and api.calls[0][0] == 'GET'


def test_fractional_timeout_cannot_disable_provider_limit(monkeypatch):
    monkeypatch.setenv('CHORDLYZE_APIFY_TIMEOUT', '.5')
    assert ApifyAudio('token').timeout == 1


def test_provider_timeout_reports_retryable_timeout():
    api = Session(Response({'data': {**RUN, 'status': 'TIMED-OUT'}}))
    with pytest.raises(AudioProviderError, match='provider_timeout'):
        ApifyAudio('token', session=api).download(CANDIDATE, 200)


def test_ambiguous_start_is_not_retried_or_leaked():
    api = Session(requests.ConnectionError('secret-token response-body'))
    with pytest.raises(AudioProviderError, match='^provider_connection$'):
        ApifyAudio('token', session=api).download(CANDIDATE, 200)
    assert len(api.calls) == 1


def test_transient_read_retries_without_launching_duplicate_work():
    api = Session(requests.ConnectionError('temporary failure'), Response(status=503), Response({'data': RUN}))
    client = ApifyAudio('token', session=api)
    assert client.request('GET', '/actor-runs/run123')['data'] == RUN
    assert len(api.calls) == 3 and all(call[0] == 'GET' for call in api.calls)


@pytest.mark.parametrize('status,code', [(401, 'provider_authentication'), (403, 'provider_authentication'),
    (402, 'provider_limit'), (429, 'provider_limit'), (503, 'provider_connection')])
def test_api_errors_are_bounded_and_safe(status, code):
    with pytest.raises(AudioProviderError, match=f'^{code}$'):
        ApifyAudio('token', session=Session(Response(status=status))).download(CANDIDATE, 200)


@pytest.mark.parametrize('override,code', [({'id': 'wrong-video'}, 'provider_response'),
    ({'durationSeconds': 30}, 'recording_mismatch'),
    ({'durationSeconds': float('nan')}, 'recording_mismatch'),
    ({'durationSeconds': None}, 'recording_mismatch')])
def test_wrong_or_incomplete_recording_never_downloads(monkeypatch, override, code):
    monkeypatch.setattr(cloud.requests, 'get', lambda *a, **kw: pytest.fail('unmatched recording fetched'))
    with pytest.raises(AudioProviderError, match=f'^{code}$'):
        ApifyAudio('token', session=Session(Response({'data': RUN}), Response(items(**override)))).download(CANDIDATE, 200)


@pytest.mark.parametrize('url', ['http://127.0.0.1/file', 'https://api.apify.com.evil.test/file',
    'https://api.apify.com@evil.test/file', 'https://api.apify.com/v2/users/me',
    URL+'?token=secret', 'https://video.googlevideo.com/audio'])
def test_untrusted_media_urls_never_receive_a_request(monkeypatch, url):
    monkeypatch.setattr(cloud.requests, 'get', lambda *a, **kw: pytest.fail('unsafe URL fetched'))
    with pytest.raises(AudioProviderError, match='provider_response'):
        ApifyAudio('token').download_file(url)


@pytest.mark.parametrize('response,code', [
    (Response(status=302), 'provider_download'),
    (Response(headers={'Content-Type': 'text/html'}), 'provider_response'),
    (Response(headers={'Content-Type': 'audio/mpeg', 'Content-Length': '50'}), 'provider_download'),
    (Response(chunks=()), 'provider_download'),
    (Response(chunks=(b'12345', b'67890')), 'recording_too_large'),
])
def test_bad_streams_remove_partial_audio(monkeypatch, tmp_path, response, code):
    monkeypatch.setattr(cloud.requests, 'get', lambda *a, **kw: response)
    client = ApifyAudio('token'); client.max_bytes = 8 if code == 'recording_too_large' else 100
    with pytest.raises(AudioProviderError, match=code): client.download_file(URL)
    assert list(tmp_path.iterdir()) == []


def test_cancellation_stops_download_and_cleans_partial_file(monkeypatch, tmp_path):
    monkeypatch.setattr(cloud.requests, 'get', lambda *a, **kw: Response())
    with pytest.raises(DownloadCancelled): ApifyAudio('token').download_file(URL, cancelled=lambda: True)
    assert not list(tmp_path.iterdir())


def test_deadline_aborts_provider_run(monkeypatch):
    api = Session(Response({'data': {**RUN, 'status': 'RUNNING'}}), Response({}))
    clock = iter([0, 1000])
    monkeypatch.setattr(cloud.time, 'monotonic', lambda: next(clock))
    with pytest.raises(AudioProviderError, match='provider_timeout'):
        ApifyAudio('token', session=api).download(CANDIDATE, 200)
    assert api.calls[-1][1].endswith('/actor-runs/run123/abort')


def test_cloud_search_normalizes_duration_and_preserves_hebrew():
    api = Session(Response({'data': RUN}), Response([
        {'id': VIDEO, 'title': 'שיר', 'channelName': 'זמר - Topic', 'duration': '00:03:20'},
        {'id': 'bad', 'duration': 'live'}, {'id': 'bad2', 'duration': float('nan')},
    ]))
    saved = []
    rows = ApifyAudio('token', session=api).search('שיר', 'זמר', save_checkpoint=saved.append)
    assert rows == [{'id': VIDEO, 'title': 'שיר', 'channel': 'זמר - Topic', 'duration': 200}]
    assert api.calls[0][2]['params']['maxTotalChargeUsd'] == .05
    assert api.calls[0][2]['json']['maxResults'] == 8
    assert saved == [{'search_run_id': 'run123'}]


def test_cloud_path_never_uses_direct_youtube(monkeypatch, tmp_path):
    monkeypatch.setenv('CHORDLYZE_AUDIO_PROVIDER', 'apify')
    import yt_dlp
    monkeypatch.setattr(yt_dlp, 'YoutubeDL', lambda *a, **kw: pytest.fail('direct YouTube used'))
    path = tmp_path / 'audio.mp3'; path.write_bytes(b'audio')
    class Provider:
        def search(self, *a, **kw): return [CANDIDATE]
        def download(self, candidate, *a, **kw):
            assert candidate == CANDIDATE
            return path
    monkeypatch.setattr(cloud, 'ApifyAudio', Provider)
    assert fulltrack.fetch_full_track('Song', 'Band', 200) == path


def test_reclaimed_job_keeps_download_checkpoint_and_reset_rejects_old_updates(tmp_path, monkeypatch):
    now = [1000]
    monkeypatch.setattr(song_jobs.time, 'time', lambda: now[0])
    jobs = song_jobs.SongJobs(tmp_path)
    jobs.request({'track_id': 'song', 'title': 'Song', 'artist': 'Band', 'duration': 200})
    first = jobs.claim()
    checkpoint = {'search_run_id': 'search123', 'run_id': 'run123', 'video_id': VIDEO, 'candidate': CANDIDATE}
    assert jobs.heartbeat(first['id'], first['lease'], 'downloading', checkpoint)
    now[0] += 181
    second = jobs.claim()
    assert second['download_checkpoint'] == checkpoint
    assert not jobs.heartbeat(first['id'], first['lease'], 'downloading', {'run_id': 'wrong'})
    song_jobs.reset_library(tmp_path, apply=True)
    assert not jobs.heartbeat(second['id'], second['lease'], 'downloading', checkpoint)


def test_worker_shutdown_does_not_publish_or_fail_a_job(monkeypatch, tmp_path):
    stopped = threading.Event(); stopped.set()
    monkeypatch.setattr(song_worker, 'fetch_full_track', lambda *a, **kw: (_ for _ in ()).throw(DownloadCancelled()))
    class Client:
        def post(self, *a, **kw): pytest.fail('cancelled job published')
    job = {'id': 'job', 'lease': 'lease', 'generation': 'gen', 'song':
           {'track_id': 'song', 'title': 'Song', 'artist': 'Band', 'duration': 200}}
    assert song_worker.process_job(Client(), job, stopped) == 'abandoned'


def test_checkpoint_api_schema_rejects_urls_as_run_ids():
    with pytest.raises(ValueError): main.DownloadCheckpoint(run_id='https://evil.test')


@pytest.mark.parametrize('value', ['nan', 'inf', '-1', '0', 'not-a-number', '100'])
def test_invalid_spending_limits_fail_before_any_job(value, monkeypatch):
    monkeypatch.setenv('CHORDLYZE_APIFY_MAX_CHARGE_USD', value)
    with pytest.raises(AudioProviderError, match='provider_configuration'): ApifyAudio('token')
