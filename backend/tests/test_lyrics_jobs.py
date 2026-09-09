"""Recording-backed lyric recovery through the actual API/worker contracts."""
import json
from pathlib import Path

from fastapi import HTTPException
import pytest

from chordlyze_backend import main, song_jobs
from chordlyze_backend.analysis import engine
from chordlyze_backend.analysis.provenance import model_metadata
from chordlyze_backend.song_jobs import SongJobs, lyrics_fingerprint
import song_worker


HASH = 'a' * 64
SONG = {'track_id': 'song', 'title': 'Authored test song', 'artist': 'Test', 'duration': 200}
CATALOG = {'synced': False, 'lines': [{'time': 1, 'text': 'One two three four'},
                                     {'time': 4, 'text': 'Five six seven eight'}]}
LINES = [{'time': start, 'text': text, 'words': [
    {'time': start + i, 'end': start + i + .5, 'text': word}
    for i, word in enumerate(text.split())]} for start, text in
    [(19, 'One two three four'), (28, 'Five six seven eight')]]


@pytest.fixture
def world(tmp_path, monkeypatch):
    monkeypatch.setattr(main, 'CACHE_DIR', tmp_path)
    monkeypatch.setenv('CHORDLYZE_WORKER_TOKEN', 'test-token')
    monkeypatch.setattr(song_worker, 'lookup_genre', lambda *a, **k: None)
    monkeypatch.setattr(song_worker, 'track_beats', lambda *a, **k: None)
    calls = {'download': 0, 'recognize': 0, 'align': 0, 'identity': 0}

    def fetch(*args, **kwargs):
        calls['download'] += 1
        audio = tmp_path / 'recording.wav'
        audio.write_bytes(b'authored recording fixture')
        return audio

    def recognize(*args, **kwargs):
        calls['recognize'] += 1
        return engine.Recognition([engine.ChordSegment(0, 200, 'C:maj7')], 200, HASH, 'ismir2019')

    def align(*args, **kwargs):
        calls['align'] += 1
        return LINES

    def identity(audio):
        calls['identity'] += 1
        return 200, HASH

    monkeypatch.setattr(song_worker, 'fetch_full_track', fetch)
    monkeypatch.setattr(song_worker, 'recognize_audio', recognize)
    monkeypatch.setattr(song_worker, 'align_lyrics', align)
    monkeypatch.setattr(song_worker, 'audio_identity', identity)

    class Client:
        def post(self, path, payload=None):
            routes = {'/analysis/submit': (main.submit_analysis, main.SubmittedAnalysis),
                      '/internal/jobs/heartbeat': (main.heartbeat_song, main.WorkerUpdate),
                      '/internal/jobs/finish': (main.finish_song, main.WorkerUpdate),
                      '/internal/jobs/lyrics': (main.attach_lyrics, main.AlignedLyrics)}
            method, body = routes[path]
            return method(body(**payload), 'Bearer test-token')

        def get(self, path, params):
            assert path == '/lyrics'
            return CATALOG

    return tmp_path, calls, Client()


def publish_chart(*, prepare=False):
    main.request_song(main.SongRequest(**SONG), user='test')
    job = main.claim_song('Bearer test-token')['job']
    body = {**SONG, **model_metadata('ismir2019'), 'audio_sha256': HASH, 'audio_duration': 200,
            'song_duration': 200, 'source': 'youtube', 'prepare_lyrics': prepare,
            'segments': [{'start': 0, 'end': 200, 'label': 'C:maj7'}],
            'job_id': job['id'], 'lease': job['lease'], 'library_generation': job['generation']}
    main.submit_analysis(main.SubmittedAnalysis(**body), 'Bearer test-token')
    return job


def lyric_payload(job):
    return main.AlignedLyrics(track_id='song', library_generation=job['generation'],
        job_id=job['id'], lease=job['lease'], expected_audio_sha256=job['expected_audio_sha256'],
        expected_lyrics_sha256=job['expected_lyrics_sha256'], aligner='fixture', lines=LINES)


def test_ready_chart_reads_do_not_schedule_and_explicit_request_is_deduplicated(world):
    cache, calls, _ = world
    publish_chart()
    before = SongJobs(cache).get('song')
    for _ in range(3):
        status = main.song_status('song', user='test')
        assert status['job']['state'] == 'ready' and status['lyrics_job']['state'] == 'missing'
    assert SongJobs(cache).get('song') == before and not any(calls.values())
    status = main.request_lyrics('song', main.LyricsRequest(), user='test')
    queued = SongJobs(cache).get('song')
    assert status['job']['state'] == 'ready' and status['lyrics_job']['state'] == 'queued'
    assert queued['expected_audio_sha256'] == HASH
    assert queued['expected_lyrics_sha256'] == lyrics_fingerprint(None)
    for retry in (False, True):
        main.request_lyrics('song', main.LyricsRequest(retry=retry), user='test')
        assert SongJobs(cache).get('song')['id'] == queued['id']
    assert main.claim_song('Bearer test-token')['job']['kind'] == 'lyrics'
    assert main.claim_song('Bearer test-token')['job'] is None


def test_new_analysis_keeps_chart_usable_and_aligns_once_from_same_download(world, monkeypatch):
    cache, calls, client = world
    main.request_song(main.SongRequest(**SONG), user='test')
    job = main.claim_song('Bearer test-token')['job']
    original = song_worker.align_lyrics

    def align(*args, **kwargs):
        status = main.song_status('song', user='test')
        assert status['job']['state'] == 'ready' and status['analysis']['chords']
        assert status['lyrics_job']['state'] == 'processing'
        assert status['lyrics_job']['stage'] == 'aligning'
        assert SongJobs(cache).heartbeat(job['id'], job['lease'], 'aligning')
        return original(*args, **kwargs)

    monkeypatch.setattr(song_worker, 'align_lyrics', align)
    assert song_worker.process_job(client, job) == 'ready'
    assert calls == {'download': 1, 'recognize': 1, 'align': 1, 'identity': 0}
    status = main.song_status('song', user='test')
    assert status['lyrics']['lines'][0]['time'] == 19
    assert status['job']['state'] == status['lyrics_job']['state'] == 'ready'
    assert not (cache / 'recording.wav').exists()
    assert main.claim_song('Bearer test-token')['job'] is None


def test_interrupted_published_analysis_reclaims_only_lyric_phase_and_checkpoint(world, monkeypatch):
    cache, calls, client = world
    now = [1000.0]
    monkeypatch.setattr(song_jobs.time, 'time', lambda: now[0])
    first = publish_chart(prepare=True)
    jobs = SongJobs(cache)
    checkpoint = {'video_id': 'abcdefghijk', 'run_id': 'original-run'}
    assert jobs.heartbeat(first['id'], first['lease'], 'aligning', checkpoint)
    assert jobs.get('song')['kind'] == 'lyrics'
    now[0] += song_jobs.LEASE_SECONDS + 1
    recovered = main.claim_song('Bearer test-token')['job']
    assert recovered['kind'] == 'lyrics' and recovered['id'] == first['id']
    assert recovered['lease'] != first['lease'] and recovered['download_checkpoint'] == checkpoint
    assert main.claim_song('Bearer test-token')['job'] is None
    assert song_worker.process_job(client, recovered) == 'ready'
    assert calls == {'download': 1, 'recognize': 0, 'align': 1, 'identity': 1}


@pytest.mark.parametrize('fault', ['recording', 'lyrics', 'lease', 'unguarded'])
def test_stale_attachments_cannot_replace_saved_evidence(world, monkeypatch, fault):
    cache, _, _ = world
    publish_chart(prepare=True)
    job = SongJobs(cache).get('song')
    body = lyric_payload(job)
    path = cache / 'track-song.json'
    entry = json.loads(path.read_text())
    if fault == 'recording':
        entry['audio_sha256'] = 'b' * 64
    elif fault == 'lyrics':
        entry['lyrics'] = {'synced': True, 'lines': [{'time': 40, 'text': 'New evidence'}]}
    elif fault == 'lease':
        body.lease = 'obsolete-lease'
    else:
        body.job_id = body.lease = body.expected_audio_sha256 = body.expected_lyrics_sha256 = None
    path.write_text(json.dumps(entry))
    before = path.read_bytes()
    with pytest.raises(HTTPException) as error:
        main.attach_lyrics(body, 'Bearer test-token')
    assert error.value.status_code == 409 and path.read_bytes() == before


def test_recording_mismatch_does_not_transcribe_or_change_chart(world, monkeypatch):
    cache, calls, client = world
    publish_chart()
    main.request_lyrics('song', main.LyricsRequest(), user='test')
    job = main.claim_song('Bearer test-token')['job']
    before = (cache / 'track-song.json').read_bytes()
    monkeypatch.setattr(song_worker, 'audio_identity', lambda audio: (200, 'b' * 64))
    assert song_worker.process_job(client, job) == 'unavailable'
    assert calls['align'] == calls['recognize'] == 0
    assert (cache / 'track-song.json').read_bytes() == before
    status = main.song_status('song', user='test')
    assert status['job']['state'] == 'ready' and status['lyrics_job']['state'] == 'unavailable'
    assert 'differs' in status['lyrics_job']['message']


@pytest.mark.parametrize('result', ['unaligned', 'failure'])
def test_unsuccessful_alignment_preserves_chart_and_needs_explicit_retry(world, monkeypatch, result):
    cache, _, client = world
    publish_chart()
    path = cache / 'track-song.json'
    entry = json.loads(path.read_text())
    entry['lyrics'] = {'synced': True, 'matched': 'aligned', 'lines': LINES}
    path.write_text(json.dumps(entry))
    main.request_lyrics('song', main.LyricsRequest(retry=True), user='test')
    job = main.claim_song('Bearer test-token')['job']
    before = (cache / 'track-song.json').read_bytes()

    def align(*a, **k):
        if result == 'failure':
            raise OSError('temporary transcription failure')
        return None

    monkeypatch.setattr(song_worker, 'align_lyrics', align)
    state = 'failed' if result == 'failure' else 'unavailable'
    assert song_worker.process_job(client, job) == state
    assert (cache / 'track-song.json').read_bytes() == before
    status = main.song_status('song', user='test')
    assert status['job']['state'] == 'ready' and status['lyrics_job']['state'] == state
    main.request_lyrics('song', main.LyricsRequest(), user='test')
    assert SongJobs(cache).get('song')['id'] == job['id']
    main.request_lyrics('song', main.LyricsRequest(retry=True), user='test')
    retried = SongJobs(cache).get('song')
    assert retried['id'] != job['id'] and retried['state'] == 'queued'


def test_attachment_completes_lease_even_if_worker_does_not_receive_reply(world):
    cache, _, _ = world
    publish_chart(prepare=True)
    job = SongJobs(cache).get('song')
    main.attach_lyrics(lyric_payload(job), 'Bearer test-token')
    assert SongJobs(cache).get('song')['state'] == 'ready'
    assert main.claim_song('Bearer test-token')['job'] is None
    with pytest.raises(HTTPException) as error:
        main.attach_lyrics(lyric_payload(job), 'Bearer test-token')
    assert error.value.status_code == 409


def test_older_admin_job_gets_recording_guards_at_claim(world):
    cache, _, _ = world
    publish_chart()
    SongJobs(cache).request(SONG, kind='lyrics')
    job = main.claim_song('Bearer test-token')['job']
    assert job['expected_audio_sha256'] == HASH
    assert job['expected_lyrics_sha256'] == lyrics_fingerprint(None)


@pytest.mark.parametrize('kind', ['estimated', 'missing_end'])
def test_alignment_without_measured_sung_intervals_is_unavailable(world, monkeypatch, kind):
    import copy
    cache, _, client = world
    publish_chart()
    main.request_lyrics('song', main.LyricsRequest(), user='test')
    job = main.claim_song('Bearer test-token')['job']
    lines = copy.deepcopy(LINES)
    for line in lines:
        for word in line['words']:
            if kind == 'estimated':
                word['estimated'] = True
            else:
                word.pop('end')
    monkeypatch.setattr(song_worker, 'align_lyrics', lambda *a, **k: lines)
    assert song_worker.process_job(client, job) == 'unavailable'
    assert main.song_status('song', user='test')['lyrics'] is None


def test_cancelled_alignment_cannot_publish_and_remains_reclaimable(world, monkeypatch):
    import threading
    cache, _, client = world
    publish_chart()
    main.request_lyrics('song', main.LyricsRequest(), user='test')
    job = main.claim_song('Bearer test-token')['job']
    stopping = threading.Event()

    def align(*args, **kwargs):
        stopping.set()
        return LINES

    monkeypatch.setattr(song_worker, 'align_lyrics', align)
    assert song_worker.process_job(client, job, stopping) == 'abandoned'
    assert SongJobs(cache).get('song')['state'] == 'processing'
    assert main.song_status('song', user='test')['lyrics'] is None
    assert not (cache / 'recording.wav').exists()


def test_matching_alias_keeps_its_non_lyric_metadata(world):
    cache, _, _ = world
    publish_chart(prepare=True)
    path = cache / 'track-song.json'
    entry = json.loads(path.read_text())
    entry['isrc'] = 'TEST123'
    path.write_text(json.dumps(entry))
    alias = {**entry, 'title': 'Alias title', 'track_id': 'alias-track'}
    alias_path = cache / 'isrc-TEST123.json'
    alias_path.write_text(json.dumps(alias))
    job = SongJobs(cache).get('song')
    main.attach_lyrics(lyric_payload(job), 'Bearer test-token')
    updated = json.loads(alias_path.read_text())
    assert {k: v for k, v in updated.items() if k != 'lyrics'} == alias
    assert updated['lyrics']['lines'][0]['time'] == 19


def test_audio_identity_matches_recognizer_pcm_metadata(tmp_path, monkeypatch):
    import shutil
    import wave
    fixture = tmp_path / 'source.wav'
    with wave.open(str(fixture), 'wb') as out:
        out.setparams((1, 2, 44100, 0, 'NONE', 'not compressed'))
        out.writeframes(bytes(range(256)) * 400)
    monkeypatch.setattr(engine, '_decode_to_wav', lambda src, dst: shutil.copyfile(src, dst))
    from chordlyze_backend.analysis import ismir
    monkeypatch.setattr(ismir, 'recognize', lambda wav: [(0, .5, 'C:maj')])
    duration, fingerprint = engine.audio_identity(fixture)
    recognized = engine.recognize_audio(fixture)
    assert (duration, fingerprint) == (recognized.duration, recognized.audio_sha256)


def test_final_catalog_reconciliation_cannot_publish_only_estimated_words(world):
    import hashlib
    cache, _, _ = world
    publish_chart(prepare=True)
    job = SongJobs(cache).get('song')
    key = f"{SONG['title']}|{SONG['artist']}||200"
    digest = hashlib.sha256(key.lower().encode()).hexdigest()[:24]
    (cache / f'lyrics5-{digest}.json').write_text(json.dumps({'synced': False, 'lines': [
        {'time': 1, 'text': 'Different catalog opening'}, {'time': 10, 'text': 'Different catalog ending'}]}))
    path = cache / 'track-song.json'
    before = path.read_bytes()
    with pytest.raises(HTTPException) as error:
        main.attach_lyrics(lyric_payload(job), 'Bearer test-token')
    assert error.value.status_code == 422
    assert path.read_bytes() == before and SongJobs(cache).get('song')['state'] == 'processing'


@pytest.mark.parametrize('source', ['transcribed', 'catalog_aligned'])
def test_retry_cannot_drop_known_lyric_occurrences(world, source):
    import copy
    cache, _, _ = world
    publish_chart()
    original = []
    for index in range(6):
        line = copy.deepcopy(LINES[index % 2])
        offset = index * 10 + 19 - line['time']
        line['time'] += offset
        for word in line['words']:
            word['time'] += offset
            word['end'] += offset
        original.append(line)
    path = cache / 'track-song.json'
    entry = json.loads(path.read_text())
    entry['lyrics'] = {'synced': True, 'matched': 'transcribed', 'lines': original}
    path.write_text(json.dumps(entry))
    main.request_lyrics('song', main.LyricsRequest(retry=True), user='test')
    job = main.claim_song('Bearer test-token')['job']
    body = lyric_payload(job).model_copy(update={'source': source, 'lines': [
        main.AlignedLine(**line) for line in original[:3]]})
    before = path.read_bytes()
    with pytest.raises(HTTPException) as error:
        main.attach_lyrics(body, 'Bearer test-token')
    assert error.value.status_code == 422
    assert path.read_bytes() == before and SongJobs(cache).get('song')['state'] == 'processing'


def test_complete_retry_allows_line_reflow_and_punctuation_without_losing_words(world):
    cache, _, _ = world
    publish_chart()
    path = cache / 'track-song.json'
    entry = json.loads(path.read_text())
    entry['lyrics'] = {'synced': True, 'matched': 'transcribed', 'lines': LINES}
    path.write_text(json.dumps(entry))
    main.request_lyrics('song', main.LyricsRequest(retry=True), user='test')
    job = main.claim_song('Bearer test-token')['job']
    text = 'ONE, TWO three four FIVE six seven EIGHT!'
    lines = [{'time': 19, 'text': text, 'words': [
        {'time': 19 + index, 'end': 19.5 + index, 'text': word}
        for index, word in enumerate(text.split())]},
        {'time': 40, 'text': 'Additional refrain', 'words': [
            {'time': 40, 'end': 40.5, 'text': 'Additional'}, {'time': 41, 'end': 41.5, 'text': 'refrain'}]}]
    body = lyric_payload(job).model_copy(update={'source': 'transcribed', 'lines': [
        main.AlignedLine(**line) for line in lines]})
    main.attach_lyrics(body, 'Bearer test-token')
    assert SongJobs(cache).get('song')['state'] == 'ready'
    saved = json.loads(path.read_text())
    assert saved['lyrics']['lines'][0]['text'] == text
    assert saved['chords'] == entry['chords']
