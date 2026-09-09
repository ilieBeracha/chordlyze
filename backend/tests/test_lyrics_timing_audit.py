import hashlib
import json
from pathlib import Path
import subprocess
import sys

from scripts.audit_lyrics_timing import audit, has_invalid, inspect_timing


def write_chart(cache, name, entry):
    path = cache / f'track-{name}.json'
    path.write_text(json.dumps(entry))
    return path


def test_audit_distinguishes_repaired_estimates_from_unresolved_transcriptions(tmp_path):
    estimated = {'title': 'Private title', 'song_duration': 30, 'lyrics': {'matched': 'aligned', 'lines': [
        {'time': 1, 'text': 'Private sample', 'words': [
            {'time': 1, 'end': 2, 'text': 'Private'}, {'time': 5, 'text': 'sample'}]}]}}
    damaged = {'song_duration': 30, 'lyrics': {'matched': 'transcribed', 'lines': [
        {'time': 0, 'text': 'Damaged phrase', 'words': [
            {'time': 0, 'end': 20, 'text': 'Damaged'}, {'time': 20, 'end': 21, 'text': 'phrase'}]}]}}
    paths = [write_chart(tmp_path, 'estimated', estimated), write_chart(tmp_path, 'damaged', damaged)]
    original = {p: p.read_bytes() for p in paths}
    report = audit(tmp_path)
    assert report['totals']['tracks_scanned'] == 2
    assert report['totals']['read_repair_changed_tracks'] == 2
    assert report['before']['unmarked_estimated_words'] == 1
    assert report['after_read_repair']['unmarked_estimated_words'] == 0
    assert report['totals']['remaining_invalid_tracks'] == 1
    assert report['after_read_repair']['estimated_words'] == 2, 'flagging a failed stamp does not count as repairing it'
    assert report['totals']['transcribed_tracks_requiring_audio_review'] == 1
    assert has_invalid(report)
    assert all(p.read_bytes() == data for p, data in original.items())
    assert 'Private' not in json.dumps(report) and 'Damaged' not in json.dumps(report)


def test_catalog_repair_is_counted_without_claiming_word_precision(tmp_path):
    entry = {'title': 'Song', 'artist': 'Artist', 'song_duration': 30,
             'lyrics': {'matched': 'aligned', 'lines': [
                 {'time': 0, 'text': 'Sample phrase', 'words': [
                     {'time': 0, 'end': 20, 'text': 'Sample'}, {'time': 20, 'end': 21, 'text': 'phrase'}]}]}}
    write_chart(tmp_path, 'catalog', entry)
    key = hashlib.sha256(b'song|artist||30').hexdigest()[:24]
    (tmp_path / f'lyrics5-{key}.json').write_text(json.dumps({'synced': True, 'lines': [{'time': 19, 'text': 'Sample phrase'}]}))
    report = audit(tmp_path)
    assert report['totals']['initially_invalid_tracks'] == 1
    assert report['totals']['remaining_invalid_tracks'] == 1
    assert report['after_read_repair']['word_timed_lines'] == 1
    assert report['after_read_repair']['estimated_words'] == 1
    assert has_invalid(report), 'a coarse catalog onset cannot count as a word timing repair'


def test_partial_and_crossing_word_arrays_are_reported():
    entry = {'song_duration': 20, 'lyrics': {'lines': [
        {'time': 2, 'text': 'Every word survives', 'words': [{'time': 1, 'text': 'Every'}]},
        {'time': 8, 'text': 'Last', 'words': [{'time': 20, 'text': 'Last'}]}]}}
    counts = inspect_timing(entry)
    assert counts['incomplete_word_lines'] == 1
    assert counts['out_of_line_word_lines'] == 2


def test_unreadable_chart_cannot_silently_pass(tmp_path):
    (tmp_path / 'track-broken.json').write_text('{broken')
    report = audit(tmp_path)
    assert report['totals']['unreadable_or_invalid_charts'] == 1
    assert has_invalid(report)


def test_empty_cache_cannot_be_reported_as_verified(tmp_path):
    assert has_invalid(audit(tmp_path))


def test_release_check_exits_nonzero_for_unresolved_timing(tmp_path):
    write_chart(tmp_path, 'invalid', {'song_duration': 30, 'lyrics': {'matched': 'transcribed', 'lines': [
        {'time': 0, 'text': 'Sustained', 'words': [{'time': 0, 'end': 20, 'text': 'Sustained'}]}]}})
    script = Path(__file__).parents[1] / 'scripts/audit_lyrics_timing.py'
    result = subprocess.run([sys.executable, str(script), '--cache', str(tmp_path), '--fail-on-invalid'],
                            capture_output=True, text=True)
    assert result.returncode == 1
    report = json.loads(result.stdout)
    assert report['remaining_by_source'] == {'transcribed': 1}
    assert report['totals']['remaining_invalid_tracks'] == 1


def test_line_only_and_genuine_measured_rests_are_not_invalid(tmp_path):
    write_chart(tmp_path, 'healthy', {'song_duration': 50, 'lyrics': {'matched': 'aligned', 'lines': [
        {'time': 1, 'text': 'Measured pause', 'words': [
            {'time': 1, 'end': 2, 'text': 'Measured'}, {'time': 15, 'end': 16, 'text': 'pause'}]},
        {'time': 20, 'text': ''}, {'time': 30, 'text': 'Line timing only'}]}})
    report = audit(tmp_path)
    assert not has_invalid(report)
    assert report['after_read_repair']['line_only_lines'] == 1
    assert report['after_read_repair']['blank_lines'] == 1
