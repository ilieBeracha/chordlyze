"""Lyric retries reuse the chart's exact source, including artist streams without ISRC."""
import json
from pathlib import Path

import pytest
import yt_dlp

from chordlyze_backend import artist_recordings, audio_apify, fulltrack, main
from chordlyze_backend.analysis.provenance import model_metadata
from chordlyze_backend.song_jobs import SongJobs
import song_worker


SONG = {'track_id': 'song', 'title': 'Authored Song', 'artist': 'Test Band', 'duration': 200}
HASH = 'a' * 64
VIDEO = 'abcdefghijk'
BANDCAMP = {'provider': 'bandcamp', 'url': 'https://test-band.bandcamp.com/track/authored-song',
            'title': SONG['title'], 'artist': SONG['artist'], 'duration': 200}
YOUTUBE = {'provider': 'apify', 'url': f'https://www.youtube.com/watch?v={VIDEO}',
           'video_id': VIDEO, 'title': SONG['title'], 'channel': SONG['artist'], 'duration': 200}


@pytest.fixture
def no_search(monkeypatch):
    def forbidden(*args, **kwargs):
        pytest.fail('A lyric retry must not search or substitute a registry recording')
    monkeypatch.setattr(fulltrack, '_search_youtube', forbidden)
    monkeypatch.setattr(artist_recordings, 'source_for', forbidden)


def fetch(source, **kwargs):
    return fulltrack.fetch_full_track(SONG['title'], SONG['artist'], SONG['duration'],
                                     recording_source=source, **kwargs)


@pytest.mark.parametrize('available', [False, True])
def test_saved_artist_stream_without_isrc_precedes_registry_and_never_falls_back(
        no_search, monkeypatch, tmp_path, available):
    audio = tmp_path / 'recording.mp3'
    seen = []
    def artist(source, title, artist, duration, **kwargs):
        seen.append((source, title, artist, duration))
        kwargs['source_info'].update(provider='bandcamp', url=source['url'])
        return audio if available else None
    monkeypatch.setattr(artist_recordings, 'fetch_artist_recording', artist)
    provenance = {}
    assert fetch(BANDCAMP, source_info=provenance) == (audio if available else None)
    assert seen == [(BANDCAMP, SONG['title'], SONG['artist'], 200)]
    if available:
        assert provenance['matching'] == 'saved_recording_title_artist_duration'


@pytest.mark.parametrize('changes', [
    {'url': 'https://evil.example/track/authored-song'}, {'url': None},
    {'title': 'Another Song'}, {'title': ['Authored Song']},
    {'title': 'Authored Song (Stripped)'}, {'artist': 'Another Band'},
    {'duration': 150}, {'duration': float('nan')}, {'duration': '200'},
    {'duration': True}, {'provider': 'unknown'},
])
def test_invalid_artist_provenance_fails_before_any_download(no_search, monkeypatch, changes):
    monkeypatch.setattr(artist_recordings, 'fetch_artist_recording',
                        lambda *a, **kw: pytest.fail('Invalid saved source reached downloader'))
    assert fetch({**BANDCAMP, **changes}) is None


@pytest.mark.parametrize('source', [{}, [], 'invalid', {'provider': 'bandcamp'}])
def test_missing_provenance_is_not_permission_to_search(no_search, source):
    assert fetch(source) is None


@pytest.mark.parametrize('changes', [
    {'video_id': 'invalid'}, {'video_id': None}, {'url': 'https://www.youtube.com/watch?v=zzzzzzzzzzz'},
    {'url': 'https://evil.example/watch?v=abcdefghijk'}, {'title': 'Authored Song (Stripped)'},
    {'channel': 'Another Band'}, {'duration': 150}, {'provider': 'unknown'},
])
def test_invalid_saved_video_cannot_fall_back(no_search, monkeypatch, changes):
    monkeypatch.setattr(audio_apify, 'ApifyAudio', lambda: pytest.fail('Invalid source reached provider'))
    assert fetch({**YOUTUBE, **changes}) is None


@pytest.mark.parametrize('checkpoint,kept', [
    (None, True),
    ({'video_id': VIDEO, 'run_id': 'same-run'}, True),
    ({'video_id': VIDEO, 'run_id': 'same-run', 'candidate': {'id': VIDEO}}, True),
    ({'video_id': 'zzzzzzzzzzz', 'run_id': 'old-run'}, False),
    ({'video_id': VIDEO, 'run_id': 'old-run', 'candidate': {'id': 'zzzzzzzzzzz'}}, False),
])
def test_saved_video_is_pinned_and_only_matching_provider_run_can_resume(
        no_search, monkeypatch, tmp_path, checkpoint, kept):
    monkeypatch.setenv('CHORDLYZE_AUDIO_PROVIDER', 'apify')
    audio = tmp_path / 'recording.mp3'
    seen = []
    class Provider:
        def search(self, *args, **kwargs):
            pytest.fail('Saved video must precede provider search')
        def download(self, candidate, duration, **kwargs):
            seen.append((candidate, kwargs['checkpoint']))
            return audio
    monkeypatch.setattr(audio_apify, 'ApifyAudio', Provider)
    provenance = {}
    assert fetch(YOUTUBE, checkpoint=checkpoint, source_info=provenance) == audio
    assert seen[0][0]['id'] == VIDEO
    assert seen[0][1] == (checkpoint if kept else None)
    assert provenance['video_id'] == VIDEO and provenance['search'] == 'saved_recording'


def test_local_downloader_also_uses_saved_video_without_search(no_search, monkeypatch):
    monkeypatch.setenv('CHORDLYZE_AUDIO_PROVIDER', 'yt_dlp')
    seen = []
    class Downloader:
        def __init__(self, options):
            self.audio = Path(options['outtmpl']).parent / 'recording.mp3'
        def __enter__(self): return self
        def __exit__(self, *args): pass
        def extract_info(self, url, download):
            seen.append((url, download))
            self.audio.write_bytes(b'authored audio fixture')
            return {}
        def prepare_filename(self, info): return str(self.audio)
    monkeypatch.setattr(yt_dlp, 'YoutubeDL', Downloader)
    audio = fetch(YOUTUBE)
    try:
        assert audio.read_bytes() == b'authored audio fixture'
        assert seen == [(YOUTUBE['url'], True)]
    finally:
        audio.unlink()


@pytest.fixture
def chart(tmp_path, monkeypatch):
    monkeypatch.setattr(main, 'CACHE_DIR', tmp_path)
    monkeypatch.setenv('CHORDLYZE_WORKER_TOKEN', 'test-token')
    main.request_song(main.SongRequest(**SONG), user='test')
    job = main.claim_song('Bearer test-token')['job']
    assert 'recording_source' not in job
    main.submit_analysis(main.SubmittedAnalysis(**SONG, **model_metadata('ismir2019'),
        audio_sha256=HASH, audio_duration=200, song_duration=200,
        source='bandcamp', audio_source=BANDCAMP,
        segments=[{'start': 0, 'end': 200, 'label': 'C:maj'}],
        job_id=job['id'], lease=job['lease'], library_generation=job['generation']),
        'Bearer test-token')
    return tmp_path


@pytest.mark.parametrize('legacy', [False, True])
def test_claim_attaches_matching_chart_source_without_persisting_it_in_job(chart, legacy):
    if legacy:
        SongJobs(chart).request(SONG, kind='lyrics')
    else:
        main.request_lyrics('song', main.LyricsRequest(), user='test')
    job = main.claim_song('Bearer test-token')['job']
    assert job['expected_audio_sha256'] == HASH and job['recording_source'] == BANDCAMP
    assert 'recording_source' not in SongJobs(chart).get('song')


@pytest.mark.parametrize('replacement', ['changed_hash', 'removed_chart', 'missing_source'])
def test_claim_never_gives_stale_job_a_replacement_source(chart, replacement, no_search):
    main.request_lyrics('song', main.LyricsRequest(), user='test')
    path = chart / 'track-song.json'
    entry = json.loads(path.read_text())
    if replacement == 'changed_hash':
        entry.update(audio_sha256='b' * 64, audio_source=YOUTUBE)
    elif replacement == 'missing_source':
        entry.pop('audio_source')
    path.write_text(json.dumps(entry))
    if replacement == 'removed_chart': path.unlink()
    before = path.read_bytes() if path.exists() else None
    job = main.claim_song('Bearer test-token')['job']
    assert job['expected_audio_sha256'] == HASH and 'recording_source' not in job
    class Client:
        def post(self, route, payload):
            method = {'/internal/jobs/heartbeat': main.heartbeat_song,
                      '/internal/jobs/finish': main.finish_song}[route]
            return method(main.WorkerUpdate(**payload), 'Bearer test-token')
    assert song_worker.process_job(Client(), job) == 'unavailable'
    assert (path.read_bytes() if path.exists() else None) == before


@pytest.mark.parametrize('kind,source,expected', [
    ('lyrics', BANDCAMP, BANDCAMP), ('lyrics', None, {}), ('analysis', BANDCAMP, None),
])
def test_worker_passes_recording_constraint_only_for_lyric_retries(monkeypatch, kind, source, expected):
    seen = []
    def download(*args, **kwargs):
        seen.append(kwargs['recording_source'])
        return None
    monkeypatch.setattr(song_worker, 'fetch_full_track', download)
    class Client:
        def post(self, *args): return {}
    job = {'song': SONG, 'id': 'job', 'lease': 'lease', 'generation': 'generation',
           'kind': kind, 'expected_audio_sha256': HASH, 'expected_lyrics_sha256': 'b' * 64,
           'recording_source': source}
    assert song_worker.process_job(Client(), job) == 'unavailable'
    assert seen == [expected]
