import hashlib
import importlib.util
import json
from pathlib import Path

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
