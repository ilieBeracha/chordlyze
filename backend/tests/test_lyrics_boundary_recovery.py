"""Recovery of reversed and adjoining words needs independent acoustic evidence."""
import copy
import hashlib
from pathlib import Path
import shutil
import urllib.error
import wave

import pytest

from chordlyze_backend import lyrics_timing


def line(start, tokens, times, ends=None):
    ends = ends or [time + .3 for time in times]
    return {'time': start, 'text': ' '.join(tokens), 'words': [
        {'time': time, 'end': end, 'text': token}
        for token, time, end in zip(tokens, times, ends)]}


def example():
    return [line(1, ['We', 'remember'], [1, 2]),
            line(4, ['every', 'quiet', 'river', 'bend'], [4, 6, 5, 8]),
            line(10, ['Under', 'moonlight'], [10, 11])]


def heard():
    return [{'start': time, 'end': time + .3, 'text': token, 'p': .9}
            for token, time in zip('We remember every quiet river bend Under moonlight'.split(),
                                   [1, 2, 4, 5, 6, 8, 10, 11])]


def test_reversed_words_recover_without_moving_healthy_words_or_neighbors():
    original = example()
    snapshot = copy.deepcopy(original)
    fixed = lyrics_timing.accept_line_recovery(original, 1, 15, heard())
    assert fixed[1]['words'][1]['time'] == 5
    assert fixed[1]['words'][2]['time'] == 6
    assert fixed[0] == original[0] and fixed[2] == original[2]
    assert fixed[1]['words'][0] == original[1]['words'][0]
    assert fixed[1]['words'][3] == original[1]['words'][3]
    assert original == snapshot


def test_single_stretched_word_can_use_following_phrase_as_evidence():
    original = [line(1, ['Remain'], [1], [20]), line(22, ['beside', 'me'], [22, 23])]
    candidate = [{'start': t, 'end': t + .3, 'text': word, 'p': .9}
                 for word, t in [('Remain', 18), ('beside', 22), ('me', 23)]]
    fixed = lyrics_timing.accept_line_recovery(original, 0, 30, candidate)
    assert fixed[0]['time'] == 18 and fixed[0]['words'][0]['end'] == 18.3
    assert fixed[1] == original[1]


def test_word_crossing_next_line_recovers_without_shortening_neighbor():
    original = example()
    original[1]['words'][3]['time'] = 10.02
    original[1]['words'][3]['end'] = 10.3
    fixed = lyrics_timing.accept_line_recovery(original, 1, 15, heard())
    assert fixed[1]['words'][3]['time'] == 8
    assert fixed[2] == original[2]


@pytest.mark.parametrize('fault', ['missing', 'duplicate', 'low_confidence', 'missing_confidence',
                                  'wrong_occurrence', 'past_audio', 'zero_span', 'neighbor_damage'])
def test_insufficient_or_conflicting_evidence_keeps_original(fault):
    original, candidate = example(), heard()
    if fault == 'missing': candidate.pop(3)
    if fault == 'duplicate': candidate.extend(copy.deepcopy(candidate[2:6]))
    if fault == 'low_confidence': candidate[3]['p'] = .01
    if fault == 'missing_confidence': candidate[3].pop('p')
    if fault == 'wrong_occurrence':
        for word in candidate: word.update(start=word['start'] + 30, end=word['end'] + 30)
    if fault == 'past_audio': candidate[4].update(start=15.1, end=15.4)
    if fault == 'zero_span': candidate[3]['end'] = candidate[3]['start']
    if fault == 'neighbor_damage':
        original[1]['words'][0].update(time=4, end=20)
        candidate[2].update(start=1.5, end=1.8)
    assert lyrics_timing.accept_line_recovery(original, 1, 15, candidate) is None


def test_retry_is_bounded_and_healthy_data_never_transcribes(tmp_path, monkeypatch):
    calls = []
    def crop(audio, output, start, end):
        calls.append((start, end))
        output.write_bytes(b'clip')
    monkeypatch.setattr(lyrics_timing, '_crop', crop)
    original = example()
    healthy = copy.deepcopy(original)
    healthy[1]['words'][1]['time'] = 5
    healthy[1]['words'][1]['end'] = 5.3
    healthy[1]['words'][2]['time'] = 6
    healthy[1]['words'][2]['end'] = 6.3
    assert lyrics_timing.repair_line_timings(Path('recording.wav'), healthy, 15,
               lambda p, l: pytest.fail('healthy song does not retry')) == healthy
    stats = {}
    assert lyrics_timing.repair_line_timings(Path('recording.wav'), original, 15,
               lambda p, l: [], max_crops=1, stats=stats) == original
    assert len(calls) == stats['attempted_crops'] == 1
    assert stats['repaired_phrases'] == 0


@pytest.mark.parametrize('source', ['aligned', 'transcribed'])
def test_worker_marks_failed_geometry_on_both_first_publication_paths(tmp_path, source):
    import song_worker
    original = example()
    class Client:
        payload = None
        def get(self, path, params):
            if source == 'transcribed':
                raise urllib.error.HTTPError('lyrics', 404, 'unavailable', {}, None)
            return {'synced': True, 'lines': [{'time': x['time'], 'text': x['text']} for x in original]}
        def post(self, path, payload):
            self.payload = payload
    client = Client()
    result = song_worker.attach_lyrics(client, {'track_id': 'test', 'title': 'Authored fixture', 'duration': 15},
        tmp_path / 'missing.wav', 'generation', align=lambda *args, **kwargs: original,
        transcribe=lambda *args: original)
    assert result == source
    assert client.payload['timing_note']
    changed = client.payload['lines'][1]['words']
    assert changed[1]['estimated'] and changed[2]['estimated']
    assert changed[0] == original[1]['words'][0]
    assert changed[3] == original[1]['words'][3]
    assert client.payload['lines'][0] == original[0]
    assert client.payload['lines'][2] == original[2]


def test_existing_chart_boundary_repair_requires_same_recording_and_preserves_non_lyrics(tmp_path, monkeypatch):
    from chordlyze_backend.analysis import engine
    monkeypatch.setattr(engine, '_decode_to_wav', shutil.copyfile)
    audio = tmp_path / 'source.wav'
    data = b'\0\0' * (100 * 15)
    with wave.open(str(audio), 'wb') as handle:
        handle.setparams((1, 2, 100, 0, 'NONE', 'not compressed'))
        handle.writeframes(data)
    entry = {'audio_duration': 15, 'audio_sha256': hashlib.sha256(data).hexdigest(),
             'chords': [{'start': 0, 'end': 15, 'label': 'C:maj'}], 'chart_revision': 'keep',
             'lyrics': {'matched': 'transcribed', 'lines': example()}}
    starts = []
    def crop(audio, target, start, end):
        starts.append(start)
        target.write_bytes(b'crop')
    monkeypatch.setattr(lyrics_timing, '_crop', crop)
    def recognize(*args):
        return [{**word, 'start': word['start'] - starts[-1], 'end': word['end'] - starts[-1]} for word in heard()]
    stats = {}
    repaired = lyrics_timing.repair_entry_from_audio(entry, audio, recognize, stats=stats)
    assert repaired['lyrics']['lines'][1]['words'][1]['time'] == 5
    assert repaired['lyrics']['lines'][0] == entry['lyrics']['lines'][0]
    assert repaired['lyrics']['lines'][2] == entry['lyrics']['lines'][2]
    assert {k: v for k, v in repaired.items() if k != 'lyrics'} == {k: v for k, v in entry.items() if k != 'lyrics'}
    assert stats == {'attempted_crops': 1, 'repaired_phrases': 1}
    assert lyrics_timing.repair_entry_from_audio(repaired, audio, lambda *a: pytest.fail('already repaired')) is None


def test_crop_cannot_follow_a_bad_word_into_a_different_chorus():
    lines = [line(126, ['Near', 'the', 'river'], [126, 127, 173]),
             line(131, ['We', 'wait'], [131, 132])]
    start, end = lyrics_timing.recovery_window(lines, 0, 200)
    assert start == 124 and end < 140
    candidate = [{'start': t, 'end': t + .3, 'text': word, 'p': .95}
                 for word, t in [('Near', 170), ('the', 171), ('river', 173), ('We', 131), ('wait', 132)]]
    assert lyrics_timing.accept_line_recovery(lines, 0, 200, candidate) is None


def test_wholly_uncertain_text_cannot_verify_itself():
    lines = [line(0, ['Wait'], [0], [20])]
    assert lyrics_timing.accept_line_recovery(lines, 0, 30,
        [{'start': 18, 'end': 19, 'text': 'Wait', 'p': .99}]) is None


def test_missing_healthy_word_does_not_block_uniquely_bracketed_damaged_words():
    original = example()
    candidate = heard()
    candidate.pop(2)  # The recognizer omitted a healthy word, not a damaged one.
    fixed = lyrics_timing.accept_line_recovery(original, 1, 15, candidate)
    assert fixed[1]['words'][0] == original[1]['words'][0]
    assert fixed[1]['words'][1]['time'] == 5 and fixed[1]['words'][2]['time'] == 6
    assert fixed[1]['words'][3] == original[1]['words'][3]


def test_partial_phrase_cannot_choose_between_repeated_damaged_words():
    candidate = heard()
    candidate.pop(2)
    candidate.insert(2, {'start': 4.5, 'end': 4.8, 'text': 'quiet', 'p': .95})
    assert lyrics_timing.accept_line_recovery(example(), 1, 15, candidate) is None


def test_crossing_boundary_words_can_be_recovered_together():
    original = example()
    original[1]['words'][1].update(time=5, end=5.3)
    original[1]['words'][2].update(time=6, end=6.3)
    original[1]['words'][3].update(time=10.02, end=10.32)
    candidate = heard()
    candidate[5].update(start=10.12, end=10.42)
    candidate[6].update(start=10.5, end=10.8)
    candidate[7].update(start=11.4, end=11.7)
    assert lyrics_timing.accept_line_recovery(original, 1, 15, candidate) is None
    fixed = lyrics_timing.accept_phrase_recovery(original, 1, 15, candidate)
    assert fixed[1]['words'][3]['time'] == 10.12
    assert fixed[2]['time'] == fixed[2]['words'][0]['time'] == 10.5
    assert fixed[1]['words'][:3] == original[1]['words'][:3]
    assert fixed[2]['words'][1] == original[2]['words'][1]
    assert fixed[0] == original[0]


def test_a_far_away_bad_word_cannot_reclassify_the_next_phrase_as_damaged():
    original = example()
    original[1]['words'][3].update(time=40, end=40.3)
    candidate = heard()
    candidate[5].update(start=10.12, end=10.42)
    candidate[6].update(start=10.5, end=10.8)
    assert lyrics_timing.accept_phrase_recovery(original, 1, 45, candidate) is None
