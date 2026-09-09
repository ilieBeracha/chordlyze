"""Explicit whole-song rebuilds retain the usable chart until complete publication."""
import copy
import base64
import json

from fastapi import HTTPException
import pytest

from chordlyze_backend import corrections, main, reanalysis, song_jobs
from chordlyze_backend.analysis.engine import ChordSegment, Recognition
from chordlyze_backend.analysis.provenance import ANALYSIS_VERSION, MODEL_REVISIONS, model_metadata
from chordlyze_backend.lyrics_validation import lyric_text_sha256, reviewed_lyric_catalog
from chordlyze_backend.song_jobs import SongJobs, lyrics_fingerprint
from chordlyze_backend.users import UserLibrary
import song_worker


OLD_HASH, NEW_HASH = 'a' * 64, 'b' * 64
SONG = {'track_id': 'song', 'title': 'Authored Song', 'artist': 'Test Band',
        'album': 'Authored Album', 'duration': 20, 'isrc': 'TEST00000001',
        'artwork': 'https://example.invalid/art.png'}


def sung_lines(offset=0):
    return [{'time': start + offset, 'text': text, 'words': [
        {'time': start + offset + i * .5, 'end': start + offset + i * .5 + .3, 'text': word}
        for i, word in enumerate(text.split())]}
        for start, text in [(3, 'One two three four'), (11, 'Five six seven eight')]]


@pytest.fixture
def world(tmp_path, monkeypatch):
    monkeypatch.setattr(main, 'CACHE_DIR', tmp_path)
    monkeypatch.setenv('CHORDLYZE_WORKER_TOKEN', 'test-token')
    now = [1000.0]
    monkeypatch.setattr(song_jobs.time, 'time', lambda: now[0])
    entry = {**SONG, **model_metadata('ismir2019'), 'source': 'youtube',
        'audio_sha256': OLD_HASH, 'audio_duration': 20, 'song_duration': 20,
        'audio_source': {'provider': 'apify', 'video_id': 'abcdefghijk',
            'url': 'https://www.youtube.com/watch?v=abcdefghijk', 'title': SONG['title'],
            'channel': SONG['artist'], 'duration': 20, 'matching': 'title_artist_duration'},
        'chords': [{'start': 0, 'end': 10, 'label': 'C:maj', 'roman': 'I'},
                   {'start': 10, 'end': 20, 'label': 'G:maj', 'roman': 'V'}],
        'analyzed_end': 20, 'key': 'C major', 'key_confidence': .9,
        'genre': 'Fixture genre', 'analyzed_at': 100.0,
        'lyrics': {'synced': True, 'matched': 'aligned', 'lines': sung_lines()}}
    path = tmp_path / 'track-song.json'
    path.write_text(json.dumps(entry))
    UserLibrary(tmp_path, 'alice').add('song', now=50)
    return {'cache': tmp_path, 'path': path, 'entry': entry, 'now': now}


def request(world, revision=None, user='alice'):
    return main.reanalyze_song('song', main.ReanalyzeRequest(
        expected_chart_revision=revision or corrections.revision(world['entry'])), user=user)


def claim():
    return main.claim_song('Bearer test-token')['job']


def stage(job, audio_hash=NEW_HASH, artist_source=False):
    # Optional metadata is deliberately omitted: rebuilding harmony must not
    # remove the stored album, artwork, ISRC or genre.
    source = ({'provider': 'bandcamp', 'url': 'https://test-band.bandcamp.com/track/authored-song',
               'title': SONG['title'], 'artist': SONG['artist'], 'duration': 20,
               'matching': 'reviewed_artist_title_duration'} if artist_source else
              {'provider': 'apify', 'video_id': 'abcdefghijk',
               'url': 'https://www.youtube.com/watch?v=abcdefghijk', 'title': SONG['title'],
               'channel': SONG['artist'], 'duration': 20, 'matching': 'title_artist_duration'})
    return main.submit_analysis(main.SubmittedAnalysis(
        track_id='song', title=SONG['title'], artist=SONG['artist'],
        **model_metadata('ismir2019'), source='bandcamp' if artist_source else 'youtube', audio_sha256=audio_hash,
        audio_duration=20, song_duration=20,
        audio_source=source,
        segments=[{'start': 0, 'end': 8, 'label': 'D:min'}, {'start': 8, 'end': 20, 'label': 'A:maj'}],
        job_id=job['id'], lease=job['lease'], library_generation=job['generation'], prepare_lyrics=True),
        'Bearer test-token')


def complete(job):
    return main.attach_lyrics(main.AlignedLyrics(
        track_id='song', library_generation=job['generation'], job_id=job['id'], lease=job['lease'],
        expected_audio_sha256=job['expected_audio_sha256'],
        expected_lyrics_sha256=job['expected_lyrics_sha256'], aligner='authored-fixture',
        lines=sung_lines(1)), 'Bearer test-token')


def add_overlay(world):
    overlay = corrections.commit(world['entry'], world['entry'], None,
        [{'start': 0, 'end': 10, 'label': 'F:maj'}, {'start': 10, 'end': 20, 'label': 'G:maj'}])
    UserLibrary(world['cache'], 'alice').set_corrections('song', overlay)
    return overlay


@pytest.mark.parametrize('personal_revision', [False, True])
def test_request_accepts_raw_or_callers_personal_revision_and_keeps_chart(world, personal_revision):
    add_overlay(world)
    status = main.song_status('song', user='alice')
    revision = status['analysis']['chart_revision'] if personal_revision else corrections.revision(world['entry'])
    before = world['path'].read_bytes()
    result = request(world, revision)
    job = SongJobs(world['cache']).get('song')
    assert job['state'] == 'queued'
    assert result['job']['state'] == 'ready' and result['analysis']['audio_sha256'] == OLD_HASH
    assert result['analysis_job']['state'] == 'queued'
    assert world['path'].read_bytes() == before


def test_stale_request_rejects_before_queuing_or_changing_personal_library(world):
    mine = UserLibrary(world['cache'], 'alice')
    before, personal = world['path'].read_bytes(), mine.path.read_bytes()
    with pytest.raises(HTTPException) as error:
        request(world, 'f' * 64)
    assert error.value.status_code == 409
    assert SongJobs(world['cache']).get('song') is None
    assert world['path'].read_bytes() == before and mine.path.read_bytes() == personal


@pytest.mark.parametrize('kind', ['analysis', 'lyrics'])
@pytest.mark.parametrize('processing', [False, True])
def test_request_deduplicates_any_active_song_work(world, kind, processing):
    jobs = SongJobs(world['cache'])
    first = jobs.request(SONG, kind=kind, audio_sha256=OLD_HASH,
                         lyrics_sha256=lyrics_fingerprint(world['entry']['lyrics']))
    if processing:
        first = claim()
    for _ in range(2):
        request(world)
        current = jobs.get('song')
        assert current['id'] == first['id'] and current['kind'] == kind
        assert current['state'] == ('processing' if processing else 'queued')
    assert len(list(world['cache'].glob('job-*.json'))) == 1


def test_chords_remain_staged_until_complete_lyrics_success(world):
    before = world['path'].read_bytes()
    request(world)
    job = claim()
    world['now'][0] = 1100
    staged = stage(job)
    lyric_job = staged['lyrics_job']
    assert lyric_job['expected_audio_sha256'] == NEW_HASH
    assert world['path'].read_bytes() == before
    status = main.song_status('song', user='alice')
    assert status['job']['state'] == 'ready' and status['analysis']['audio_sha256'] == OLD_HASH
    assert status['analysis_job']['state'] == 'processing'
    assert status['analysis_info']['analyzed_at'] == 100
    world['now'][0] = 1110
    complete(lyric_job)
    published = json.loads(world['path'].read_text())
    assert published['audio_sha256'] == NEW_HASH
    assert [s['label'] for s in published['chords']] == ['D:min', 'A:maj']
    assert published['lyrics']['lines'] == sung_lines(1)
    assert published['analyzed_at'] == 1110
    for key in ('title', 'artist', 'album', 'isrc', 'artwork', 'genre'):
        assert published[key] == world['entry'][key]
    status = main.song_status('song', user='alice')
    assert status['job']['state'] == status['analysis_job']['state'] == 'ready'
    assert status['analysis_info']['analyzed_at'] == 1110


@pytest.mark.parametrize('after_staging', [False, True])
@pytest.mark.parametrize('state', ['failed', 'unavailable'])
def test_failure_preserves_old_chart_lyrics_and_completion_date(world, after_staging, state):
    before = world['path'].read_bytes()
    request(world)
    job = claim()
    if after_staging:
        job = stage(job)['lyrics_job']
    main.finish_song(main.WorkerUpdate(track_id='song', job_id=job['id'], lease=job['lease'],
        library_generation=job['generation'], state=state), 'Bearer test-token')
    assert world['path'].read_bytes() == before
    status = main.song_status('song', user='alice')
    assert status['job']['state'] == 'ready' and status['analysis_job']['state'] == state
    assert status['lyrics']['lines'] == sung_lines()
    assert status['analysis_info']['analyzed_at'] == 100


@pytest.mark.parametrize('changed_part', ['recording', 'lyrics'])
def test_changed_chart_cannot_be_overwritten_by_staged_completion(world, changed_part):
    request(world)
    job = stage(claim())['lyrics_job']
    changed = copy.deepcopy(world['entry'])
    if changed_part == 'recording':
        changed['audio_sha256'] = 'c' * 64
    else:
        changed['lyrics']['lines'][0]['text'] = 'A separately reviewed replacement phrase'
    world['path'].write_text(json.dumps(changed))
    before = world['path'].read_bytes()
    with pytest.raises(HTTPException) as error:
        complete(job)
    assert error.value.status_code == 409 and world['path'].read_bytes() == before


def test_success_retains_personal_edits_and_bound_calibration_but_marks_overlay_stale(world):
    overlay = add_overlay(world)
    mine = UserLibrary(world['cache'], 'alice')
    timing = {'offset': .35, 'scale': 1.001, 'chart_audio_sha256': OLD_HASH,
              'chart_revision': corrections.revision(world['entry']), 'spotify_track_id': 'song'}
    mine.set_timing('song', timing)
    before = mine.path.read_bytes()
    request(world)
    complete(stage(claim())['lyrics_job'])
    assert mine.path.read_bytes() == before
    assert mine.corrections('song') == overlay and mine.timing('song') == timing
    status = main.song_status('song', user='alice')
    assert status['saved'] and status['analysis']['corrections_stale']
    assert status['analysis']['chords'][0]['label'] == 'D:min'


def test_replacing_audio_binds_legacy_calibration_to_its_old_recording(world):
    mine = UserLibrary(world['cache'], 'alice')
    timing = {'offset': .35, 'scale': 1.001, 'anchors': [{'chart': 2, 'spotify': 2.35}]}
    mine.set_timing('song', timing)
    request(world)
    complete(stage(claim())['lyrics_job'])
    assert mine.timing('song') == {**timing, 'chart_audio_sha256': OLD_HASH}
    assert json.loads(mine.path.read_text())['songs']['song']['added_at'] == 50


@pytest.mark.parametrize('reclaimed', [False, True])
def test_reviewed_artist_catalog_survives_staging_and_restart_with_new_recording_identity(world, reclaimed):
    entry = world['entry']
    entry['source'] = 'bandcamp'
    entry['audio_source'] = {'provider': 'bandcamp',
        'url': 'https://test-band.bandcamp.com/track/authored-song', 'title': SONG['title'],
        'artist': SONG['artist'], 'duration': 20, 'matching': 'reviewed_artist_title_duration'}
    entry['lyrics'].update(audio_sha256=OLD_HASH, audio_duration=20,
        text_source={'provider': 'bandcamp', 'url': entry['audio_source']['url'],
                     'audio_sha256': OLD_HASH, 'text_sha256': lyric_text_sha256(sung_lines())})
    world['path'].write_text(json.dumps(entry))
    assert reviewed_lyric_catalog(entry) is not None
    before = world['path'].read_bytes()
    request(world)
    lyric_job = stage(claim(), artist_source=True)['lyrics_job']
    if reclaimed:
        world['now'][0] += song_jobs.LEASE_SECONDS + 1
        expired = lyric_job
        lyric_job = claim()
        assert lyric_job['lease'] != expired['lease']
        with pytest.raises(HTTPException) as error:
            complete(expired)
        assert error.value.status_code == 409
    assert world['path'].read_bytes() == before
    assert lyric_job['expected_audio_sha256'] == NEW_HASH
    catalog = lyric_job['lyric_catalog']
    assert catalog['synced'] is False
    assert [line['text'] for line in catalog['lines']] == [line['text'] for line in sung_lines()]
    assert all('words' not in line for line in catalog['lines'])
    complete(lyric_job)
    updated = json.loads(world['path'].read_text())
    assert updated['lyrics']['text_source']['audio_sha256'] == NEW_HASH
    assert updated['lyrics']['text_source']['url'] == entry['audio_source']['url']
    assert reviewed_lyric_catalog(updated) is not None
    assert updated['lyrics']['lines'] == sung_lines(1)


@pytest.mark.parametrize('old_version', [2, 3])
def test_older_compatible_charts_stay_playable_and_report_version_gap(world, old_version):
    entry = copy.deepcopy(world['entry'])
    entry['analysis_version'] = old_version
    entry.pop('analyzed_at')
    world['path'].write_text(json.dumps(entry))
    status = main.song_status('song', user='alice')
    assert status['job']['state'] == 'ready' and status['analysis'] is not None
    info = status['analysis_info']
    assert info['analysis_version'] == old_version and info['current_analysis_version'] == ANALYSIS_VERSION
    assert info['versions_behind'] == ANALYSIS_VERSION - old_version
    assert not info['is_current'] and info['analyzed_at'] is None
    assert info['current_version_released_at'] is None
    assert status['analysis_job'] is None


def test_current_info_includes_raw_revision_and_model_identity(world):
    add_overlay(world)
    status = main.song_status('song', user='alice')
    info = status['analysis_info']
    assert info['is_current'] and info['versions_behind'] == 0
    assert info['model'] == 'ismir2019'
    assert info['model_revision'] == info['current_model_revision'] == MODEL_REVISIONS['ismir2019']
    assert info['chart_revision'] == corrections.revision(world['entry'])
    assert info['chart_revision'] != status['analysis']['chart_revision']
    assert info['source_title'] == SONG['title'] and info['source_provider'] == 'apify'


def test_same_version_with_wrong_model_revision_is_not_reported_current(world):
    entry = copy.deepcopy(world['entry'])
    entry['model_revision'] = 'old-model-revision'
    world['path'].write_text(json.dumps(entry))
    status = main.song_status('song', user='alice')
    info = status['analysis_info']
    assert not info['is_current'] and info['current_analysis_version'] == ANALYSIS_VERSION
    assert info['model_revision'] != info['current_model_revision']
    assert status['analysis'] is None
    assert info['chart_revision'] == corrections.revision(entry)
    request(world, revision=info['chart_revision'])
    assert SongJobs(world['cache']).get('song')['state'] == 'queued'


def test_current_version_metadata_does_not_certify_the_recording_edition(world):
    entry = copy.deepcopy(world['entry'])
    entry['audio_source']['title'] += ' (Stripped)'
    world['path'].write_text(json.dumps(entry))
    info = main.song_status('song', user='alice')['analysis_info']
    assert info['is_current'] and info['versions_behind'] == 0
    assert info['source_title'].endswith('(Stripped)')


@pytest.mark.parametrize('old_version', [2, 3])
def test_compatible_old_chart_can_retime_lyrics_without_changing_analysis_version_or_date(world, old_version):
    entry = copy.deepcopy(world['entry'])
    entry['analysis_version'] = old_version
    world['path'].write_text(json.dumps(entry))
    before = {k: v for k, v in entry.items() if k != 'lyrics'}
    response = main.request_lyrics('song', main.LyricsRequest(retry=True), user='alice')
    assert response['job']['state'] == 'ready' and response['lyrics_job']['state'] == 'queued'
    job = claim()
    assert job['kind'] == 'lyrics' and not job.get('reanalysis')
    assert job['expected_audio_sha256'] == OLD_HASH
    complete(job)
    updated = json.loads(world['path'].read_text())
    assert {k: v for k, v in updated.items() if k != 'lyrics'} == before
    assert updated['lyrics']['lines'] == sung_lines(1)
    status = main.song_status('song', user='alice')
    assert status['job']['state'] == 'ready' and status['lyrics_job']['state'] == 'ready'
    assert status['analysis_info']['analysis_version'] == old_version
    assert status['analysis_info']['analyzed_at'] == 100


@pytest.mark.parametrize('known_lyrics', [False, True])
def test_instrumental_completion_cannot_erase_known_lyrics(world, known_lyrics):
    if not known_lyrics:
        world['entry'].pop('lyrics')
        world['path'].write_text(json.dumps(world['entry']))
    before = world['path'].read_bytes()
    request(world)
    job = stage(claim())['lyrics_job']
    world['now'][0] = 1010
    body = main.WorkerUpdate(track_id='song', job_id=job['id'], lease=job['lease'],
        library_generation=job['generation'], state='ready', instrumental=True)
    if known_lyrics:
        with pytest.raises(HTTPException) as error:
            main.finish_song(body, 'Bearer test-token')
        assert error.value.status_code == 422 and world['path'].read_bytes() == before
    else:
        main.finish_song(body, 'Bearer test-token')
        result = json.loads(world['path'].read_text())
        assert result['audio_sha256'] == NEW_HASH and result['analyzed_at'] == 1010
        assert result['lyrics']['instrumental'] is True and result['lyrics']['lines'] == []
        assert main.song_status('song', user='alice')['analysis_job']['state'] == 'ready'


@pytest.mark.parametrize('alignment_fails', [False, True])
def test_worker_runs_fresh_full_pipeline_and_only_publishes_after_alignment(world, monkeypatch, alignment_fails):
    # A finished old provider run must not dictate the new recording lookup.
    jobs = SongJobs(world['cache'])
    jobs.request(SONG)
    old_job = claim()
    jobs.heartbeat(old_job['id'], old_job['lease'], 'downloading',
                   {'video_id': 'zzzzzzzzzzz', 'run_id': 'old-provider-run'})
    jobs.finish('song', old_job['id'], old_job['lease'], old_job['generation'], 'ready')
    before = world['path'].read_bytes()
    request(world)
    job = claim()
    audio = world['cache'] / 'authored-audio.wav'
    calls = []
    def download(*args, **kwargs):
        assert kwargs['recording_source'] is None and kwargs['checkpoint'] == {}
        kwargs['source_info'].update(world['entry']['audio_source'])
        audio.write_bytes(b'Authored fixture; no audio providers or ASR')
        calls.append('download')
        return audio
    def recognize(*args, **kwargs):
        calls.append('recognize')
        return Recognition([ChordSegment(0, 8, 'D:min'), ChordSegment(8, 20, 'A:maj')],
                           20, NEW_HASH, 'ismir2019')
    def align(*args, **kwargs):
        calls.append('align')
        assert audio.exists() and world['path'].read_bytes() == before
        status = main.song_status('song', user='alice')
        assert status['analysis']['audio_sha256'] == OLD_HASH
        assert status['analysis_job']['state'] == 'processing'
        return None if alignment_fails else sung_lines(1)
    monkeypatch.setattr(song_worker, 'fetch_full_track', download)
    monkeypatch.setattr(song_worker, 'recognize_audio', recognize)
    monkeypatch.setattr(song_worker, 'align_lyrics', align)
    monkeypatch.setattr(song_worker, 'track_beats', lambda *a, **kw: None)
    monkeypatch.setattr(song_worker, 'lookup_genre', lambda *a, **kw: None)
    class Client:
        def get(self, route, params):
            assert route == '/lyrics'
            return {'synced': True, 'lines': sung_lines()}
        def post(self, route, payload):
            routes = {'/analysis/submit': (main.submit_analysis, main.SubmittedAnalysis),
                      '/internal/jobs/heartbeat': (main.heartbeat_song, main.WorkerUpdate),
                      '/internal/jobs/finish': (main.finish_song, main.WorkerUpdate),
                      '/internal/jobs/lyrics': (main.attach_lyrics, main.AlignedLyrics)}
            method, schema = routes[route]
            result = method(schema(**payload), 'Bearer test-token')
            if route == '/analysis/submit':
                assert world['path'].read_bytes() == before
            return result
    assert song_worker.process_job(Client(), job) == ('unavailable' if alignment_fails else 'ready')
    assert calls == ['download', 'recognize', 'align'] and not audio.exists()
    if alignment_fails:
        assert world['path'].read_bytes() == before
    else:
        assert json.loads(world['path'].read_text())['audio_sha256'] == NEW_HASH


def test_publication_io_failure_restores_chart_alias_personal_map_and_job_bytes(world, monkeypatch):
    alias = world['cache'] / f"isrc-{SONG['isrc']}.json"
    alias.write_text(json.dumps({**world['entry'], 'title': 'Preserved alias title'}))
    mine = UserLibrary(world['cache'], 'alice')
    mine.set_timing('song', {'offset': .35, 'scale': 1})
    request(world)
    job = stage(claim())['lyrics_job']
    paths = [world['path'], alias, mine.path, SongJobs(world['cache']).path('song')]
    before = {path: path.read_bytes() for path in paths}
    original = reanalysis.write_json
    def fail_after_primary_write(path, value):
        original(path, value)
        if path == world['path']:
            raise OSError('Authored publication failure')
    monkeypatch.setattr(reanalysis, 'write_json', fail_after_primary_write)
    with pytest.raises(OSError):
        complete(job)
    assert {path: path.read_bytes() for path in paths} == before
    # Rollback retains the valid staged lease, so the same completion can retry.
    monkeypatch.setattr(reanalysis, 'write_json', original)
    complete(job)
    assert json.loads(world['path'].read_text())['audio_sha256'] == NEW_HASH
    assert json.loads(alias.read_text())['title'] == 'Preserved alias title'


def interrupted_publication(world, cut):
    """Construct durable disk states a killed publisher may leave behind."""
    cache = world['cache']
    alias = cache / f"isrc-{SONG['isrc']}.json"
    alias.write_text(json.dumps({**world['entry'], 'track_id': 'alias', 'album': 'Alias album'}))
    UserLibrary(cache, 'alice').set_timing('song', {'offset': .35, 'scale': 1})
    UserLibrary(cache, 'bob').set_timing('alias', {'offset': .2, 'scale': 1})
    request(world)
    complete(stage(claim())['lyrics_job'])
    job = SongJobs(cache).get('song')
    backup = cache / job['publication']['backup']
    manifest = json.loads((backup / 'manifest.json').read_bytes())
    payload = json.loads((backup / 'pending-writes.json').read_bytes())
    final = {cache / item['file']: base64.b64decode(payload[item['file']]) for item in manifest['files']}
    original = {cache / item['file']: (backup / item['file']).read_bytes() for item in manifest['files']}
    for path in final:
        keep_after = (cut == 'all' or (cut == 'alias' and path == alias)
                      or (cut == 'primary_only' and path == world['path']))
        path.write_bytes(final[path] if keep_after else original[path])
    job.update(state='processing', attempts=3, lease='killed-publisher', lease_until=world['now'][0] - 1)
    job.pop('finished_at', None)
    SongJobs(cache).path('song').write_text(json.dumps(job))
    return job, backup, original, final


@pytest.mark.parametrize('cut', ['none', 'alias', 'all', 'primary_only'])
def test_killed_publication_recovers_every_original_target_without_recognition(world, cut):
    job, backup, original, final = interrupted_publication(world, cut)
    # Includes a separate alias track's legacy calibration in the original plan.
    assert len(final) == 4
    assert claim() is None, 'The claim completes the bounded plan instead of returning audio work.'
    assert SongJobs(world['cache']).get('song')['state'] == 'ready'
    assert {path: path.read_bytes() for path in final} == final
    assert all((backup / path.relative_to(world['cache'])).read_bytes() == raw for path, raw in original.items())
    assert (backup.stat().st_mode & 0o777) == 0o700
    assert ((backup / 'pending-writes.json').stat().st_mode & 0o777) == 0o600
    status = main.song_status('song', user='alice')
    assert status['analysis_job']['state'] == 'ready'
    assert 'publication' not in status['analysis_job'] and 'bob' not in json.dumps(status['analysis_job'])


@pytest.mark.parametrize('target_kind', ['primary', 'alias', 'personal'])
def test_publication_recovery_refuses_later_edits_without_overwriting_any_target(world, target_kind):
    _, _, _, final = interrupted_publication(world, 'alias')
    target = (world['path'] if target_kind == 'primary' else
              next(path for path in final if path.name.startswith('isrc-')) if target_kind == 'alias' else
              next(path for path in final if path.parent.name == 'users'))
    edited = json.loads(target.read_bytes())
    edited['later_edit'] = 'retain this value'
    target.write_text(json.dumps(edited))
    before = {path: path.read_bytes() for path in final}
    assert claim() is None
    assert SongJobs(world['cache']).get('song')['state'] == 'failed'
    assert {path: path.read_bytes() for path in final} == before


def test_publication_recovery_refuses_tampered_new_bytes(world):
    _, backup, _, final = interrupted_publication(world, 'none')
    payload_path = backup / 'pending-writes.json'
    payload = json.loads(payload_path.read_bytes())
    first = next(iter(payload))
    payload[first] = base64.b64encode(b'{"different": true}').decode()
    payload_path.write_text(json.dumps(payload))
    before = {path: path.read_bytes() for path in final}
    assert claim() is None
    assert SongJobs(world['cache']).get('song')['state'] == 'failed'
    assert {path: path.read_bytes() for path in final} == before


def test_successful_reanalysis_keeps_a_guarded_restorable_backup(world):
    from scripts.replace_reviewed_chart import restore_backup
    job, backup, original, _ = interrupted_publication(world, 'all')
    assert claim() is None
    preview = restore_backup(world['cache'], backup)
    assert preview['files'] == len(original)
    restore_backup(world['cache'], backup, apply=True, expected_plan=job['publication']['plan_sha256'])
    assert {path: path.read_bytes() for path in original} == original


@pytest.mark.parametrize('renamed', [False, True])
def test_terminal_job_write_failure_never_leaves_ready_with_rolled_back_targets(world, monkeypatch, renamed):
    alias = world['cache'] / f"isrc-{SONG['isrc']}.json"
    alias.write_bytes(world['path'].read_bytes())
    UserLibrary(world['cache'], 'alice').set_timing('song', {'offset': .35, 'scale': 1})
    request(world)
    job = stage(claim())['lyrics_job']
    paths = [world['path'], alias, UserLibrary(world['cache'], 'alice').path]
    before = {path: path.read_bytes() for path in paths}
    atomic = reanalysis._atomic_bytes
    job_path = SongJobs(world['cache']).path('song')
    def fail_ready(path, raw):
        if path == job_path and json.loads(raw).get('state') == 'ready':
            if renamed:
                atomic(path, raw)
            raise OSError('Authored terminal commit failure')
        atomic(path, raw)
    monkeypatch.setattr(reanalysis, '_atomic_bytes', fail_ready)
    with pytest.raises(OSError, match='terminal commit failure'):
        complete(job)
    current = SongJobs(world['cache']).get('song')
    if renamed:
        assert current['state'] == 'ready'
        assert json.loads(world['path'].read_bytes())['audio_sha256'] == NEW_HASH
        assert json.loads(alias.read_bytes())['audio_sha256'] == NEW_HASH
        assert UserLibrary(world['cache'], 'alice').timing('song')['chart_audio_sha256'] == OLD_HASH
    else:
        assert current['state'] == 'processing'
        assert {path: path.read_bytes() for path in paths} == before


@pytest.mark.parametrize('source, bounds', [
    ('itunes_preview', [(0, 20)]), ('youtube', [(2, 20)]),
    ('youtube', [(0, 9), (10, 20)]), ('youtube', [(0, 19)]),
])
def test_reanalysis_rejects_preview_and_incomplete_recording_coverage(world, source, bounds):
    request(world)
    job = claim()
    before = world['path'].read_bytes()
    with pytest.raises(HTTPException) as error:
        main.submit_analysis(main.SubmittedAnalysis(track_id='song', **model_metadata('ismir2019'),
            source=source, audio_sha256=NEW_HASH, audio_duration=20, song_duration=20,
            segments=[{'start': start, 'end': end, 'label': 'C:maj'} for start, end in bounds],
            job_id=job['id'], lease=job['lease'], library_generation=job['generation'], prepare_lyrics=True),
            'Bearer test-token')
    assert error.value.status_code == 422
    assert world['path'].read_bytes() == before


def test_future_analysis_generation_cannot_be_downgraded(world):
    entry = copy.deepcopy(world['entry'])
    entry['analysis_version'] = ANALYSIS_VERSION + 1
    world['path'].write_text(json.dumps(entry))
    info = main.song_status('song', user='alice')['analysis_info']
    assert info['versions_behind'] == 0 and not info['is_current']
    before = world['path'].read_bytes()
    with pytest.raises(HTTPException) as error:
        request(world, info['chart_revision'])
    assert error.value.status_code == 409
    assert SongJobs(world['cache']).get('song') is None and world['path'].read_bytes() == before


def test_transient_recovery_commit_io_error_keeps_journal_reclaimable(world, monkeypatch):
    _, _, _, final = interrupted_publication(world, 'all')
    atomic = reanalysis._atomic_bytes
    job_path = SongJobs(world['cache']).path('song')
    def fail_before_ready(path, raw):
        if path == job_path and json.loads(raw).get('state') == 'ready':
            raise OSError('Authored transient recovery I/O failure')
        atomic(path, raw)
    monkeypatch.setattr(reanalysis, '_atomic_bytes', fail_before_ready)
    with pytest.raises(OSError, match='transient recovery'):
        claim()
    job = SongJobs(world['cache']).get('song')
    assert job['state'] == 'processing' and job.get('publication')
    assert {path: path.read_bytes() for path in final} == final
    monkeypatch.setattr(reanalysis, '_atomic_bytes', atomic)
    world['now'][0] += song_jobs.LEASE_SECONDS + 1
    assert claim() is None
    assert SongJobs(world['cache']).get('song')['state'] == 'ready'
    assert {path: path.read_bytes() for path in final} == final
