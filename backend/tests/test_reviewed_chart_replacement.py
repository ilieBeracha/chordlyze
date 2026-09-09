"""Reviewed recording replacement preserves private edits and is recoverable."""
import copy
import json
from pathlib import Path

import pytest

from chordlyze_backend import corrections
from chordlyze_backend.analysis.provenance import model_metadata
from chordlyze_backend.song_jobs import SongJobs
from chordlyze_backend.lyrics_validation import lyric_text_sha256, reviewed_lyric_catalog
from scripts import replace_reviewed_chart as repair


@pytest.fixture
def world(tmp_path):
    old_hash, new_hash = 'a' * 64, 'b' * 64
    chart = {'track_id': 'authored', 'title': 'Test song', 'artist': 'Tést Artist',
             'isrc': 'GBTEST123456', 'album': 'Saved album', 'genre': 'indie',
             'library_generation': 'existing-generation', 'song_duration': 40,
             'audio_duration': 40, 'audio_sha256': old_hash, 'source': 'youtube',
             **model_metadata('ismir2019'),
             'chords': [{'start': 0, 'end': 40, 'label': 'C:maj'}],
             'lyrics': {'lines': [{'time': 1, 'text': 'One two two three'}]}}
    path = tmp_path / 'track-authored.json'
    path.write_text(json.dumps(chart, ensure_ascii=True, indent=2))
    alias = {**chart, 'track_id': 'edition', 'album': 'Alias album'}
    alias_path = tmp_path / 'isrc-GBTEST123456.json'
    alias_path.write_text(json.dumps(alias, indent=3))
    overlay = {'base_revision': corrections.revision(chart), 'labels': {'0': 'D:maj'},
               'history': [[{'start': 0, 'end': 40, 'label': 'C:maj'}]]}
    timing = {'offset': 1.75, 'scale': 1, 'anchors': [{'playback': 9, 'chart': 10}]}
    (tmp_path / 'users').mkdir()
    user = {'name': 'Private fixture', 'songs': {
        'authored': {'timing': timing, 'corrections': overlay, 'last_opened': 100},
        'other': {'timing': {'offset': 9}}}}
    user_path = tmp_path / 'users' / 'private.json'
    user_path.write_text(json.dumps(user, indent=2))
    bound_user = copy.deepcopy(user)
    bound_user['songs']['authored']['timing']['chart_revision'] = corrections.revision(chart)
    bound_path = tmp_path / 'users' / 'bound.json'
    bound_path.write_text(json.dumps(bound_user, indent=3))
    replacement = {**chart, 'audio_sha256': new_hash, 'source': 'bandcamp',
        'audio_source': {'url': 'https://artist.bandcamp.com/track/test-song',
                         'title': 'Test song', 'artist': 'Tést Artist', 'duration': 40,
                         'matching': 'reviewed_artist_album_title_duration', 'provider': 'bandcamp'},
        'chords': [{'start': 0, 'end': 20, 'label': 'D:min7'}, {'start': 20, 'end': 40, 'label': 'F:maj7'}],
        'tempo': {'bpm': 100, 'beats': [1, 1.6, 2.2]},
        'lyrics': {'synced': True, 'matched': 'aligned', 'audio_sha256': new_hash,
                   'audio_duration': 40, 'lines': [{'time': 18, 'text': 'One two two three',
                    'words': [{'time': 18 + i, 'end': 18.5 + i, 'text': word}
                              for i, word in enumerate('One two two three'.split())]}]}}
    proposal = {'track_id': 'authored', 'expected_before_sha256': repair.digest(repair.encoded(chart)),
                'expected_audio_sha256': old_hash, 'replacement': replacement}
    return tmp_path, proposal, [path, alias_path, user_path, bound_path]


def snapshot(paths):
    return {p: p.read_bytes() for p in paths}


def apply(world):
    cache, proposal, _ = world
    plan = repair.replace_chart(cache, proposal)
    return repair.replace_chart(cache, proposal, apply=True, expected_plan=plan['plan_sha256'])


def test_canonical_json_matches_review_contract_despite_whitespace_and_unicode(world):
    cache, proposal, paths = world
    chart = json.loads(paths[0].read_bytes())
    expected = json.dumps(chart, sort_keys=True, ensure_ascii=False,
                          separators=(',', ':'), allow_nan=False).encode('utf-8')
    assert repair.encoded(chart) == expected
    assert repair.digest(paths[0].read_bytes()) != proposal['expected_before_sha256']
    assert repair.replace_chart(cache, proposal)['files'] == 3


def test_dry_run_changes_nothing_and_emits_only_aggregate_review(world):
    cache, proposal, paths = world
    originals = snapshot(paths)
    plan = repair.replace_chart(cache, proposal)
    assert snapshot(paths) == originals
    assert plan['files'] == 3 and plan['aliases_updated'] == plan['legacy_maps_bound'] == 1
    assert plan['before_revision'] != plan['after_revision']
    assert plan['backup'] is None and not list(cache.glob('reviewed-chart-backup-*'))
    assert 'private' not in json.dumps(plan) and 'Private fixture' not in json.dumps(plan)
    assert not list(cache.glob('job-*'))


def test_apply_backs_up_all_targets_and_retains_personal_edits(world):
    cache, proposal, paths = world
    originals = snapshot(paths)
    result = apply(world)
    backup = Path(result['backup'])
    for path in paths[:3]:
        assert (backup / path.relative_to(cache)).read_bytes() == originals[path]
    assert (backup.stat().st_mode & 0o777) == 0o700
    assert ((backup / 'manifest.json').stat().st_mode & 0o777) == 0o600
    chart = json.loads(paths[0].read_bytes())
    assert chart['audio_sha256'] == 'b' * 64 and chart['source'] == 'bandcamp'
    assert chart['album'] == 'Saved album' and chart['library_generation'] == 'existing-generation'
    assert chart['lyrics']['lines'][0]['time'] == 18
    assert chart['tempo']['beats'] == [1, 1.6, 2.2]
    alias = json.loads(paths[1].read_bytes())
    assert alias['track_id'] == 'edition' and alias['album'] == 'Alias album'
    assert alias['audio_sha256'] == chart['audio_sha256']
    user = json.loads(paths[2].read_bytes())
    old_user = json.loads(originals[paths[2]])
    old_user['songs']['authored']['timing']['chart_audio_sha256'] = 'a' * 64
    assert user == old_user
    overlay = user['songs']['authored']['corrections']
    assert corrections.apply(chart, overlay)['corrections_stale']
    assert paths[3].read_bytes() == originals[paths[3]]
    assert repair.replace_chart(cache, proposal, apply=True)['already_applied']
    assert len(list(cache.glob('reviewed-chart-backup-*'))) == 1


@pytest.mark.parametrize('change', ['primary', 'alias', 'user', 'new_user'])
def test_stale_state_refuses_before_any_write(world, change):
    cache, proposal, paths = world
    plan = repair.replace_chart(cache, proposal)
    if change == 'new_user':
        new = cache / 'users' / 'new.json'
        new.write_bytes(paths[2].read_bytes())
        paths.append(new)
    else:
        path = paths[{'primary': 0, 'alias': 1, 'user': 2}[change]]
        data = json.loads(path.read_bytes())
        data['concurrent_edit'] = True
        path.write_text(json.dumps(data))
    expected = snapshot(paths)
    with pytest.raises(ValueError, match='changed'):
        repair.replace_chart(cache, proposal, apply=True, expected_plan=plan['plan_sha256'])
    assert snapshot(paths) == expected
    assert not list(cache.glob('reviewed-chart-backup-*'))


@pytest.mark.parametrize('track', ['authored', 'edition'])
def test_active_chart_or_alias_work_blocks_replacement(world, track):
    cache, proposal, paths = world
    SongJobs(cache).request({'track_id': track})
    before = snapshot(paths)
    with pytest.raises(ValueError, match='active work'):
        repair.replace_chart(cache, proposal)
    assert snapshot(paths) == before


@pytest.mark.parametrize('change', ['hash', 'lyrics_recording', 'lost_text', 'all_estimated', 'gap', 'wrong_title'])
def test_unreviewed_or_incomplete_candidate_is_rejected(world, change):
    cache, proposal, paths = world
    candidate = proposal['replacement']
    if change == 'hash':
        proposal['expected_audio_sha256'] = 'c' * 64
    elif change == 'lyrics_recording':
        candidate['lyrics']['audio_sha256'] = 'a' * 64
    elif change == 'lost_text':
        candidate['lyrics']['lines'][0]['text'] = 'One two three'
    elif change == 'all_estimated':
        for word in candidate['lyrics']['lines'][0]['words']:
            word['estimated'] = True
    elif change == 'gap':
        candidate['chords'][1]['start'] = 21
    else:
        candidate['title'] = 'Different song'
    original = snapshot(paths)
    with pytest.raises(ValueError):
        repair.replace_chart(cache, proposal)
    assert snapshot(paths) == original


def test_write_failure_rolls_back_exact_original_bytes(world, monkeypatch):
    cache, proposal, paths = world
    originals = snapshot(paths)
    atomic = repair.atomic_bytes

    def fail_alias(path, data):
        if path == paths[1] and data != originals[path]:
            raise OSError('authored write failure')
        atomic(path, data)

    monkeypatch.setattr(repair, 'atomic_bytes', fail_alias)
    with pytest.raises(OSError, match='authored write failure'):
        apply(world)
    assert snapshot(paths) == originals
    backup, = cache.glob('reviewed-chart-backup-*')
    for path in paths[:3]:
        assert (backup / path.relative_to(cache)).read_bytes() == originals[path]


def test_failure_after_atomic_replace_also_restores_that_target(world, monkeypatch):
    _, _, paths = world
    originals = snapshot(paths)
    atomic = repair.atomic_bytes

    def fail_after_replace(path, data):
        atomic(path, data)
        if path == paths[1] and data != originals[path]:
            raise OSError('authored directory sync failure')

    monkeypatch.setattr(repair, 'atomic_bytes', fail_after_replace)
    with pytest.raises(OSError, match='directory sync failure'):
        apply(world)
    assert snapshot(paths) == originals


@pytest.mark.parametrize('interrupted', [False, True])
def test_restore_recovers_complete_or_interrupted_install_idempotently(world, interrupted):
    cache, proposal, paths = world
    originals = snapshot(paths)
    result = apply(world)
    backup = Path(result['backup'])
    if interrupted:
        paths[0].write_bytes(originals[paths[0]])
    dry_run = repair.restore_backup(cache, backup)
    assert dry_run['files'] == (2 if interrupted else 3)
    restored = repair.restore_backup(cache, backup, apply=True, expected_plan=result['plan_sha256'])
    assert restored['restored'] and snapshot(paths) == originals
    assert repair.restore_backup(cache, backup, apply=True, expected_plan=result['plan_sha256'])['files'] == 0


def test_retry_cannot_report_partial_install_as_complete(world):
    cache, proposal, paths = world
    originals = snapshot(paths)
    result = apply(world)
    # Reproduce process termination after the first file was replaced.
    for path in paths[1:3]:
        path.write_bytes(originals[path])
    partial = snapshot(paths)
    with pytest.raises(ValueError, match='complete plan is not verified'):
        repair.replace_chart(cache, proposal, apply=True, expected_plan=result['plan_sha256'])
    assert snapshot(paths) == partial
    repair.restore_backup(cache, Path(result['backup']), apply=True, expected_plan=result['plan_sha256'])
    assert snapshot(paths) == originals


def test_retry_checks_the_complete_backup_and_later_personal_edits(world):
    cache, proposal, paths = world
    apply(world)
    user = json.loads(paths[2].read_bytes())
    user['later_change'] = True
    paths[2].write_text(json.dumps(user))
    with pytest.raises(ValueError, match='complete plan is not verified'):
        repair.replace_chart(cache, proposal)


@pytest.mark.parametrize('changed', ['target', 'backup', 'manifest'])
def test_restore_refuses_concurrent_change_or_damaged_backup_without_mutation(world, changed):
    cache, _, paths = world
    result = apply(world)
    backup = Path(result['backup'])
    target = {'target': paths[2], 'backup': backup / paths[0].name, 'manifest': backup / 'manifest.json'}[changed]
    data = json.loads(target.read_bytes())
    if changed == 'manifest':
        data['files'][0]['file'] = '../outside.json'
    else:
        data['later_edit'] = True
    target.write_text(json.dumps(data))
    original = snapshot(paths)
    with pytest.raises(ValueError):
        repair.restore_backup(cache, backup, apply=True, expected_plan=result['plan_sha256'])
    assert snapshot(paths) == original


@pytest.mark.parametrize('change', ['edition', 'artist', 'duration', 'url', 'youtube_url'])
def test_review_label_cannot_override_recording_identity(world, change):
    cache, proposal, paths = world
    source = proposal['replacement']['audio_source']
    if change == 'edition':
        source['title'] += ' (Stripped)'
    elif change == 'artist':
        source['artist'] = 'Another artist'
    elif change == 'duration':
        source['duration'] = 50
    elif change == 'url':
        source['url'] = 'https://artist.bandcamp.com.attacker.example/track/test-song'
    else:
        proposal['replacement']['source'] = 'youtube'
        source.update(provider='yt_dlp', video_id='abcdefghijk', url='https://www.youtube.com/watch?v=differentid')
    before = snapshot(paths)
    with pytest.raises(ValueError, match='provenance|URL'):
        repair.replace_chart(cache, proposal)
    assert snapshot(paths) == before


@pytest.mark.parametrize('times', [[18, 17], [-1, 18], [18, 40]])
def test_lyric_lines_must_be_in_order_and_in_recording(world, times):
    cache, proposal, _ = world
    first = proposal['replacement']['lyrics']['lines'][0]
    first['time'] = times[0]
    proposal['replacement']['lyrics']['lines'].append({'time': times[1], 'text': 'Another line'})
    with pytest.raises(ValueError, match='ordered and within'):
        repair.replace_chart(cache, proposal)


def test_uncertain_word_evidence_is_preserved_as_estimated(world):
    _, proposal, paths = world
    words = proposal['replacement']['lyrics']['lines'][0]['words']
    words[2]['end'] = 45
    before = copy.deepcopy(words)
    apply(world)
    stored = json.loads(paths[0].read_bytes())['lyrics']['lines'][0]['words']
    assert stored[2] == {**before[2], 'estimated': True}
    assert [(w['time'], w['end'], w['text']) for w in stored] == [(w['time'], w['end'], w['text']) for w in before]


@pytest.mark.parametrize('change', [None, 'url', 'audio', 'text'])
def test_reviewed_artist_text_is_bound_to_complete_text_and_recording(world, change):
    cache, proposal, paths = world
    candidate = proposal['replacement']
    source = {'provider': 'bandcamp', 'url': candidate['audio_source']['url'],
              'audio_sha256': candidate['audio_sha256'],
              'text_sha256': lyric_text_sha256(candidate['lyrics']['lines'])}
    candidate['lyrics']['text_source'] = source
    if change == 'url':
        source['url'] = 'https://other.bandcamp.com/track/another-song'
    elif change == 'audio':
        source['audio_sha256'] = 'a' * 64
    elif change == 'text':
        candidate['lyrics']['lines'][0]['text'] += ' Unreviewed addition'
    if change:
        before = snapshot(paths)
        with pytest.raises(ValueError, match='lyric text provenance'):
            repair.replace_chart(cache, proposal)
        assert snapshot(paths) == before
    else:
        apply(world)
        stored = json.loads(paths[0].read_bytes())
        assert stored['lyrics']['text_source'] == source
        assert reviewed_lyric_catalog(stored)['lines'][0]['text'] == candidate['lyrics']['lines'][0]['text']
