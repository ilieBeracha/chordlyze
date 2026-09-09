import hashlib
import importlib.util
import json
from pathlib import Path
import pytest

from chordlyze_backend.lyrics_repair import repaired_entry

spec = importlib.util.spec_from_file_location('repair_lyrics', Path(__file__).parents[1] / 'scripts/repair_lyrics.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def fixture(cache):
    catalog = {'synced': True, 'lines': [
        {'time': 17.45, 'text': 'Opening phrase'},
        {'time': 25.88, 'text': 'First surviving phrase'},
        {'time': 30.37, 'text': 'Following phrase'}]}
    entry = {'track_id': 'song', 'title': 'Song', 'artist': 'Artist', 'album': 'Album',
             'song_duration': 245, 'audio_sha256': 'a'*64, 'isrc': 'TEST123',
             'chords': [{'start': 0, 'end': 245, 'label': 'D:maj'}], 'chart_revision': 'unchanged',
             'lyrics': {'matched': 'aligned', 'synced': True, 'lines': [
                 {'time': 26.8, 'text': 'First surviving phrase'},
                 {'time': 31.88, 'text': 'Following phrase'}]}}
    digest = hashlib.sha256(b'song|artist|album|245').hexdigest()[:24]
    (cache / f'lyrics5-{digest}.json').write_text(json.dumps(catalog))
    (cache / 'track-song.json').write_text(json.dumps(entry))
    (cache / 'isrc-TEST123.json').write_text(json.dumps(entry))
    return entry


def test_dry_run_then_repair_backs_up_and_preserves_chart(tmp_path):
    entry = fixture(tmp_path)
    original = (tmp_path / 'track-song.json').read_bytes()
    dry = module.repair(tmp_path)
    assert not dry['applied'] and dry['changes'][0]['after'] == 3
    assert (tmp_path / 'track-song.json').read_bytes() == original
    done = module.repair(tmp_path, apply=True)
    repaired = json.loads((tmp_path / 'track-song.json').read_text())
    assert repaired['lyrics']['lines'][0]['time'] == 18.37
    assert repaired['lyrics']['timing_note']
    assert {k:v for k,v in repaired.items() if k != 'lyrics'} == {k:v for k,v in entry.items() if k != 'lyrics'}
    assert (Path(done['backup']) / 'track-song.json').read_bytes() == original
    assert json.loads((tmp_path / 'isrc-TEST123.json').read_text())['lyrics'] == repaired['lyrics']
    assert module.repair(tmp_path, apply=True)['changes'] == [], 'repair is idempotent'


def test_repair_does_not_touch_other_recording_alias_or_transcription(tmp_path):
    entry = fixture(tmp_path)
    alias = {**entry, 'audio_sha256': 'b'*64}
    (tmp_path / 'isrc-TEST123.json').write_text(json.dumps(alias))
    module.repair(tmp_path, apply=True)
    assert json.loads((tmp_path / 'isrc-TEST123.json').read_text()) == alias
    entry['lyrics']['matched'] = 'transcribed'
    assert repaired_entry(entry, tmp_path) is None


def test_missing_catalog_is_not_guessed(tmp_path):
    assert repaired_entry({'lyrics': {'matched': 'aligned', 'lines': []}}, tmp_path) is None


def test_song_read_repairs_old_intro_without_rewriting_chart(tmp_path, monkeypatch):
    from chordlyze_backend import main
    from chordlyze_backend.analysis.provenance import model_metadata
    monkeypatch.setattr(main, 'CACHE_DIR', tmp_path)
    entry = fixture(tmp_path)
    entry.update(model_metadata('ismir2019'))
    entry.update(source='youtube', audio_duration=245)
    entry['lyrics']['lines'].insert(0, {'time': 0, 'text': 'Opening phrase', 'words': [
        {'time': 0, 'end': 1, 'text': 'Opening'}, {'time': 1, 'end': 18, 'text': 'phrase'}]})
    path = tmp_path / 'track-song.json'
    path.write_text(json.dumps(entry))
    original = path.read_bytes()
    revision = main.corrections.revision(entry)
    result = main._song_status('song')
    assert result['lyrics']['lines'][0]['time'] == 17.45
    assert all(w['estimated'] for w in result['lyrics']['lines'][0]['words'])
    assert result['lyrics']['timing_review'] == {'lines': 1, 'words': 2}
    assert result['lyrics']['timing_note']
    assert result['analysis']['chords'] == entry['chords']
    assert result['analysis']['chart_revision'] == revision
    assert result['lyrics'] == main._song_status('song')['lyrics']
    assert result['lyrics'] == main.get_track_analysis('song', user='tester')['lyrics']
    assert path.read_bytes() == original, 'response repair must not mutate shared charts'


def test_unreadable_catalog_keeps_chart_available(tmp_path):
    entry = fixture(tmp_path)
    path = next(tmp_path.glob('lyrics5-*.json'))
    for invalid in ('{partial', 'null', '[]'):
        path.write_text(invalid)
        assert repaired_entry(entry, tmp_path) is None


@pytest.mark.parametrize('matched', ['aligned', 'transcribed'])
def test_old_chart_estimates_repaired_on_both_reads_without_catalog(tmp_path, monkeypatch, matched):
    from chordlyze_backend import main
    from chordlyze_backend.analysis.provenance import model_metadata
    monkeypatch.setattr(main, 'CACHE_DIR', tmp_path)
    entry = fixture(tmp_path)
    entry['lyrics']['matched'] = matched
    next(tmp_path.glob('lyrics5-*.json')).unlink()
    entry.update(model_metadata('ismir2019'))
    entry.update(source='youtube', audio_duration=245)
    entry['lyrics']['lines'] = [{'time': 2, 'text': 'Keep this phrase', 'words': [
        {'time': 2, 'end': 2.5, 'text': 'Keep'}, {'time': 6, 'text': 'this'},
        {'time': 10, 'end': 11, 'text': 'phrase'}]}]
    path = tmp_path / 'track-song.json'
    path.write_text(json.dumps(entry))
    original = path.read_bytes()
    revision = main.corrections.revision(entry)
    song = main._song_status('song')
    track = main.get_track_analysis('song', user='tester')
    assert song['lyrics'] == track['lyrics']
    assert song['lyrics']['lines'][0]['words'][1]['estimated'] is True
    assert song['lyrics']['completeness_version'] == 3
    assert song['analysis']['chords'] == entry['chords']
    assert song['analysis']['chart_revision'] == revision
    assert path.read_bytes() == original
    repaired = repaired_entry(entry, tmp_path)
    assert repaired_entry(repaired, tmp_path) is None
    assert {k: v for k, v in repaired.items() if k != 'lyrics'} == {k: v for k, v in entry.items() if k != 'lyrics'}
