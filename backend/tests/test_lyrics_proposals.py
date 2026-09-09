import copy
import json

import pytest

from scripts import apply_lyrics_proposals as batch


def fixture(cache, track='one'):
    before = {'track_id': track, 'audio_sha256': 'same-recording', 'isrc': 'ALIAS'+track,
              'chords': [{'start': 0, 'end': 30, 'label': 'C:maj'}],
              'lyrics': {'lines': [{'time': 0, 'text': 'Sample', 'words': [
                  {'time': 0, 'end': 20, 'text': 'Sample'}]}]}}
    after = copy.deepcopy(before)
    after['lyrics']['lines'][0].update(time=18, words=[{'time': 18, 'end': 20, 'text': 'Sample'}])
    for name in ('track-'+track, 'isrc-ALIAS'+track.upper()):
        (cache/(name+'.json')).write_text(json.dumps(before))
    return {'track_id': track, 'before': before, 'after': after}


def test_batch_is_dry_by_default_backs_up_alias_and_is_idempotent(tmp_path):
    proposal = fixture(tmp_path)
    original = (tmp_path/'track-one.json').read_bytes()
    dry = batch.apply_proposals(tmp_path, [proposal])
    assert not dry['applied'] and dry['changed_tracks'] == 1 and dry['files'] == 2
    assert (tmp_path/'track-one.json').read_bytes() == original
    result = batch.apply_proposals(tmp_path, [proposal], apply=True)
    assert result['applied']
    assert (tmp_path/result['backup']/'track-one.json').read_bytes() == original
    assert json.loads((tmp_path/'track-one.json').read_text()) == proposal['after']
    assert json.loads((tmp_path/'isrc-ALIASONE.json').read_text()) == proposal['after']
    again = batch.apply_proposals(tmp_path, [proposal], apply=True)
    assert again['changed_tracks'] == 0 and again['already_applied_tracks'] == 1


@pytest.mark.parametrize('fault', ['chords', 'text', 'words', 'identity', 'nan'])
def test_invalid_batch_is_rejected_before_any_chart_changes(tmp_path, fault):
    first, second = fixture(tmp_path), fixture(tmp_path, 'two')
    if fault == 'chords': second['after']['chords'] = []
    if fault == 'text': second['after']['lyrics']['lines'][0]['text'] = 'Different'
    if fault == 'words': second['after']['lyrics']['lines'][0].pop('words')
    if fault == 'identity': second['track_id'] = '../elsewhere'
    if fault == 'nan': second['after']['lyrics']['lines'][0]['time'] = float('nan')
    with pytest.raises(ValueError):
        batch.apply_proposals(tmp_path, [first, second], apply=True)
    assert json.loads((tmp_path/'track-one.json').read_text()) == first['before']
    assert not list(tmp_path.glob('lyrics-verified-backup-*'))


def test_stale_chart_blocks_whole_batch_without_touching_fresh_charts(tmp_path):
    first, second = fixture(tmp_path), fixture(tmp_path, 'two')
    changed = {**second['before'], 'chart_revision': 'newer'}
    (tmp_path/'track-two.json').write_text(json.dumps(changed))
    with pytest.raises(ValueError, match='changed after verification'):
        batch.apply_proposals(tmp_path, [first, second], apply=True)
    assert json.loads((tmp_path/'track-one.json').read_text()) == first['before']
    assert json.loads((tmp_path/'track-two.json').read_text()) == changed


def test_unrelated_alias_is_preserved(tmp_path):
    proposal = fixture(tmp_path)
    alias = {**proposal['before'], 'audio_sha256': 'different-recording'}
    (tmp_path/'isrc-ALIASONE.json').write_text(json.dumps(alias))
    batch.apply_proposals(tmp_path, [proposal], apply=True)
    assert json.loads((tmp_path/'isrc-ALIASONE.json').read_text()) == alias


def test_write_failure_restores_completed_files(tmp_path, monkeypatch):
    proposals = [fixture(tmp_path), fixture(tmp_path, 'two')]
    real = batch.atomic_write
    calls = 0
    def failing(path, payload):
        nonlocal calls
        calls += 1
        if calls == 2:
            raise OSError('simulated disk failure')
        real(path, payload)
    monkeypatch.setattr(batch, 'atomic_write', failing)
    with pytest.raises(OSError):
        batch.apply_proposals(tmp_path, proposals, apply=True)
    for proposal in proposals:
        assert json.loads((tmp_path/('track-'+proposal['track_id']+'.json')).read_text()) == proposal['before']
