"""Reviewed artist text survives catalog fallback and exact-recording retries."""
import copy
import hashlib
import json

import pytest
from fastapi import HTTPException

from chordlyze_backend import lyrics_repair, lyrics_validation, main
from chordlyze_backend.analysis.provenance import model_metadata
from chordlyze_backend.song_jobs import SongJobs, lyrics_fingerprint
import song_worker


HASH = 'a' * 64
URL = 'https://fixture-band.bandcamp.com/track/river-room'
TRACK = 'reviewedartist'
TEXTS = ['Silver lanterns guide us home', 'Quiet footsteps cross the stone']


def text_hash(lines):
    """Independent contract encoder: normalized line texts, no timing fields."""
    import unicodedata
    normalized = [' '.join(unicodedata.normalize('NFKC', line['text']).split()) for line in lines]
    return hashlib.sha256(json.dumps(normalized, ensure_ascii=False, separators=(',', ':')).encode()).hexdigest()


def measured_lines(offset=0):
    return [{'time': start + offset, 'text': text, 'words': [
        {'time': start + i + offset, 'end': start + i + .6 + offset, 'text': word}
        for i, word in enumerate(text.split())]} for start, text in zip([8, 18], TEXTS)]


def reviewed_entry():
    lines = measured_lines()
    return {'track_id': TRACK, 'title': 'River Room', 'artist': 'Fixture Band', 'album': 'Authored Album',
            'song_duration': 40, 'audio_duration': 40, 'audio_sha256': HASH, 'source': 'bandcamp',
            **model_metadata('ismir2019'),
            'chords': [{'start': 0, 'end': 40, 'label': 'C:maj'}],
            'audio_source': {'provider': 'bandcamp', 'url': URL, 'title': 'River Room',
                             'artist': 'Fixture Band', 'duration': 40,
                             'matching': 'reviewed_artist_title_duration'},
            'lyrics': {'lines': lines, 'synced': True, 'matched': 'aligned',
                       'audio_sha256': HASH, 'audio_duration': 40, 'aligner': 'authored',
                       'text_source': {'provider': 'bandcamp', 'url': URL, 'audio_sha256': HASH,
                                       'text_sha256': text_hash(lines)}}}


def catalog_path(cache, entry):
    key = f"{entry['title']}|{entry['artist']}|{entry['album']}|{round(entry['song_duration'])}"
    return cache / ('lyrics5-' + hashlib.sha256(key.lower().encode()).hexdigest()[:24] + '.json')


@pytest.fixture
def world(tmp_path, monkeypatch):
    monkeypatch.setattr(main, 'CACHE_DIR', tmp_path)
    monkeypatch.setenv('CHORDLYZE_WORKER_TOKEN', 'authored-token')
    entry = reviewed_entry()
    path = tmp_path / f'track-{TRACK}.json'
    path.write_text(json.dumps(entry))
    wrong = {'synced': True, 'lines': [
        {'time': 1, 'text': 'Clouds dissolve in winter light'},
        {'time': 7, 'text': TEXTS[0]}, {'time': 17, 'text': TEXTS[1]},
        {'time': 29, 'text': 'Clouds dissolve in winter light'}]}
    catalog_path(tmp_path, entry).write_text(json.dumps(wrong))
    return tmp_path, path, entry


def claim_retry():
    main.request_lyrics(TRACK, main.LyricsRequest(retry=True), user='authored-user')
    return main.claim_song('Bearer authored-token')['job']


def attachment(job, lines):
    return {'track_id': TRACK, 'library_generation': job['generation'], 'job_id': job['id'],
            'lease': job['lease'], 'expected_audio_sha256': job['expected_audio_sha256'],
            'expected_lyrics_sha256': job['expected_lyrics_sha256'], 'aligner': 'authored-retry', 'lines': lines}


def test_text_fingerprint_normalizes_unicode_whitespace_but_preserves_occurrences_and_punctuation():
    a = [{'time': 1, 'text': '  Café\tＦＯＸ! '}, {'time': 3, 'text': 'Again'}]
    b = [{'time': 50, 'text': 'Cafe\u0301 FOX!', 'words': []}, {'time': 70, 'text': 'Again'}]
    assert lyrics_validation.lyric_text_sha256(a) == text_hash(a)
    assert lyrics_validation.lyric_text_sha256(a) == lyrics_validation.lyric_text_sha256(b)
    for changed in [[{'text': 'Café FOX'}, {'text': 'Again'}],
                    [{'text': 'café FOX!'}, {'text': 'Again'}], list(reversed(b)), b + b[-1:]]:
        assert lyrics_validation.lyric_text_sha256(changed) != text_hash(a)


def test_reviewed_catalog_is_text_only_not_a_new_timing_claim():
    entry = reviewed_entry()
    original = copy.deepcopy(entry)
    result = lyrics_validation.reviewed_lyric_catalog(entry)
    assert result['synced'] is False
    assert result['lines'] == [{'time': line['time'], 'text': line['text']} for line in entry['lyrics']['lines']]
    assert entry == original
    for line in entry['lyrics']['lines']:
        line['time'] += .25
        for word in line['words']:
            word['time'] += .25
            word['end'] += .25
    assert lyrics_validation.reviewed_lyric_catalog(entry) is not None


@pytest.mark.parametrize('fault', ['missing', 'provider', 'url', 'hash', 'text_hash', 'text',
                                  'recording', 'source_url', 'source_provider', 'source_matching',
                                  'source_title', 'source_artist', 'source_duration'])
def test_untrusted_or_tampered_source_cannot_bypass_normal_catalog_rules(fault):
    entry = reviewed_entry()
    if fault == 'missing': entry['lyrics'].pop('text_source')
    elif fault == 'provider': entry['lyrics']['text_source']['provider'] = 'unreviewed'
    elif fault == 'url': entry['lyrics']['text_source']['url'] = 'https://other.bandcamp.com/track/river-room'
    elif fault == 'hash': entry['lyrics']['text_source']['audio_sha256'] = 'b' * 64
    elif fault == 'text_hash': entry['lyrics']['text_source']['text_sha256'] = 'b' * 64
    elif fault == 'text': entry['lyrics']['lines'][0]['text'] += ' Added'
    elif fault == 'recording': entry['audio_sha256'] = 'b' * 64
    elif fault == 'source_url':
        entry['audio_source']['url'] = 'https://outside.example/track/river-room'
        entry['lyrics']['text_source']['url'] = entry['audio_source']['url']
    elif fault == 'source_provider': entry['audio_source']['provider'] = 'youtube'
    elif fault == 'source_matching': entry['audio_source']['matching'] = 'automatic_search'
    elif fault == 'source_title': entry['audio_source']['title'] = 'Other Song'
    elif fault == 'source_artist': entry['audio_source']['artist'] = 'Other Band'
    elif fault == 'source_duration': entry['audio_source']['duration'] = 90
    before = copy.deepcopy(entry)
    assert lyrics_validation.reviewed_lyric_catalog(entry) is None
    assert entry == before


def test_get_style_repair_keeps_reviewed_artist_text_and_never_writes_cache(world):
    cache, path, entry = world
    saved = path.read_bytes()
    repaired = lyrics_repair.repaired_entry(entry, cache) or entry
    assert repaired['lyrics']['lines'] == entry['lyrics']['lines']
    assert repaired['lyrics']['text_source'] == entry['lyrics']['text_source']
    status = main.song_status(TRACK, user='authored-user')
    assert status['lyrics']['lines'] == entry['lyrics']['lines']
    assert status['lyrics']['text_source'] == entry['lyrics']['text_source']
    assert path.read_bytes() == saved
    assert not list(cache.glob('job-*'))


def test_claim_attaches_artist_catalog_without_persisting_it_in_job(world):
    cache, _, entry = world
    job = claim_retry()
    assert job['lyric_catalog'] == lyrics_validation.reviewed_lyric_catalog(entry)
    assert job['expected_audio_sha256'] == HASH
    assert job['expected_lyrics_sha256'] == lyrics_fingerprint(entry['lyrics'])
    assert 'lyric_catalog' not in SongJobs(cache).get(TRACK)


@pytest.mark.parametrize('changed', ['audio', 'lyrics'])
def test_stale_job_never_receives_newer_reviewed_text(world, changed):
    _, path, entry = world
    main.request_lyrics(TRACK, main.LyricsRequest(retry=True), user='authored-user')
    if changed == 'audio':
        entry['audio_sha256'] = entry['lyrics']['audio_sha256'] = entry['lyrics']['text_source']['audio_sha256'] = 'b' * 64
    else:
        entry['lyrics']['lines'][0]['text'] += ' Again'
        entry['lyrics']['text_source']['text_sha256'] = text_hash(entry['lyrics']['lines'])
    path.write_text(json.dumps(entry))
    job = main.claim_song('Bearer authored-token')['job']
    assert 'lyric_catalog' not in job


def test_recording_retry_aligns_artist_words_without_catalog_get_and_preserves_provenance(world, monkeypatch):
    cache, path, entry = world
    job = claim_retry()
    calls = {'align': 0, 'download': 0}
    audio = cache / 'authored-audio.wav'

    def download(*args, **kwargs):
        assert kwargs['recording_source'] == entry['audio_source']
        calls['download'] += 1
        audio.write_bytes(b'authored audio')
        return audio

    def align(_, texts, **kwargs):
        assert texts == TEXTS
        calls['align'] += 1
        return measured_lines(.2)

    monkeypatch.setattr(song_worker, 'fetch_full_track', download)
    monkeypatch.setattr(song_worker, 'audio_identity', lambda _: (40, HASH))
    monkeypatch.setattr(song_worker, 'align_lyrics', align)
    monkeypatch.setattr(song_worker, 'recognize_audio', lambda *a, **k: pytest.fail('Retry must not rerun chord inference'))
    monkeypatch.setattr(song_worker, 'finalize_line_timings', lambda audio, lines, duration, **kw: (lines, None))

    class Client:
        def get(self, *args, **kwargs):
            pytest.fail('Reviewed artist text must not fetch the conflicting catalog')

        def post(self, route, payload=None):
            function, schema = {
                '/internal/jobs/heartbeat': (main.heartbeat_song, main.WorkerUpdate),
                '/internal/jobs/finish': (main.finish_song, main.WorkerUpdate),
                '/internal/jobs/lyrics': (main.attach_lyrics, main.AlignedLyrics),
            }[route]
            return function(schema(**payload), 'Bearer authored-token')

    assert song_worker.process_job(Client(), job) == 'ready'
    after = json.loads(path.read_text())
    assert calls == {'align': 1, 'download': 1}
    assert after['lyrics']['text_source'] == entry['lyrics']['text_source']
    assert [line['text'] for line in after['lyrics']['lines']] == TEXTS
    assert after['lyrics']['lines'][0]['time'] == 8.2
    assert lyrics_validation.reviewed_lyric_catalog(after) is not None
    assert after['audio_sha256'] == HASH and after['chords'] == entry['chords']
    assert SongJobs(cache).get(TRACK)['state'] == 'ready'
    assert not audio.exists()


@pytest.mark.parametrize('change', ['new_text', 'transcribed'])
def test_retry_cannot_replace_the_reviewed_text_or_its_source_identity(world, change):
    cache, path, _ = world
    job = claim_retry()
    lines = measured_lines()
    if change == 'new_text':
        # Adding words preserves the old text but is a different reviewed source.
        lines.append({'time': 30, 'text': 'Stay', 'words': [{'time': 30, 'end': 30.5, 'text': 'Stay'}]})
    catalog_path(cache, reviewed_entry()).unlink()
    before = path.read_bytes()
    payload = attachment(job, lines)
    if change == 'transcribed': payload['source'] = 'transcribed'
    with pytest.raises(HTTPException) as failure:
        main.attach_lyrics(main.AlignedLyrics(**payload), 'Bearer authored-token')
    assert failure.value.status_code == 422
    assert path.read_bytes() == before
    assert lyrics_validation.reviewed_lyric_catalog(json.loads(before)) is not None


def test_worker_cannot_introduce_reviewed_source_marker(world):
    cache, path, entry = world
    claimed_marker = entry['lyrics'].pop('text_source')
    path.write_text(json.dumps(entry))
    catalog_path(cache, entry).unlink()
    job = claim_retry()
    payload = {**attachment(job, measured_lines()), 'text_source': claimed_marker}
    main.attach_lyrics(main.AlignedLyrics(**payload), 'Bearer authored-token')
    after = json.loads(path.read_text())
    assert 'text_source' not in after['lyrics']
    assert lyrics_validation.reviewed_lyric_catalog(after) is None
