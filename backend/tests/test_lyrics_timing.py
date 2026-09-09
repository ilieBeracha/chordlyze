"""Acoustic recovery is bounded, evidence-gated, and leaves healthy data alone."""
import copy
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import wave

import pytest

from chordlyze_backend import lyrics_align, lyrics_timing
from scripts import repair_lyrics_from_audio


def damaged_words(offset=0, segment=0):
    texts = ['We', 'can', 'walk', 'beside', 'the', 'shore']
    times = [0, 3.36, 20.14, 20.98, 23.32, 23.86, 25.68]
    return [{'start': offset + a, 'end': offset + b, 'text': text, 'segment': segment}
            for a, b, text in zip(times, times[1:], texts)]


def recovered_words():
    # Clip begins at 12.14; these are measured timestamps relative to it.
    times = [6.4, 7.7, 8.0, 8.84, 11.18, 11.72, 13.54]
    return [{'start': a, 'end': b, 'text': text, 'p': .9}
            for a, b, text in zip(times, times[1:], ['We', 'can', 'walk', 'beside', 'the', 'shore.'])]


@pytest.fixture
def crop_calls(monkeypatch):
    calls = []
    def crop(audio, target, start, end):
        calls.append((audio, target, start, end))
        target.write_bytes(b'crop')
    monkeypatch.setattr(lyrics_timing, '_crop', crop)
    return calls


def test_bad_phrase_recovers_only_with_matching_words_and_surrounding_times(crop_calls):
    original = damaged_words() + [{'start': 30, 'end': 31, 'text': 'Following', 'segment': 1}]
    snapshot = copy.deepcopy(original)
    stats = {}
    fixed = lyrics_timing.repair_word_spans(Path('audio.wav'), original, lambda p, l: recovered_words(), 'en', stats=stats)
    assert stats == {'attempted_crops': 1, 'repaired_phrases': 1}
    assert fixed[0]['start'] == 18.54 and fixed[1]['end'] == 20.14
    assert fixed[2:] == original[2:], 'healthy anchors and later phrases retain their exact stamps'
    assert [w['text'] for w in fixed] == [w['text'] for w in original]
    assert original == snapshot
    assert crop_calls[0][2:] == (12.14, 26.68)
    assert not crop_calls[0][1].exists(), 'temporary audio is removed'
    assert lyrics_timing.repair_word_spans(Path('audio.wav'), fixed, lambda p, l: pytest.fail('no further retry')) == fixed


@pytest.mark.parametrize('kind', ['missing', 'different', 'duplicate', 'drift', 'confidence',
                                  'boundary', 'reversed', 'long', 'nan', 'outside',
                                  'estimated_evidence', 'uncertain_prefix', 'missing_prefix_confidence'])
def test_conflicting_or_unreliable_retranscriptions_cannot_change_timestamps(crop_calls, kind):
    candidate = recovered_words()
    if kind == 'missing': candidate.pop(0)
    if kind == 'different': candidate[1]['text'] = 'different'
    if kind == 'duplicate': candidate *= 2
    if kind == 'drift':
        for w in candidate: w.update(start=w['start'] + 1.5, end=w['end'] + 1.5)
    if kind == 'confidence':
        for w in candidate: w['p'] = .2
    if kind == 'estimated_evidence': candidate[0]['estimated'] = True
    if kind == 'uncertain_prefix': candidate[0]['p'] = .16
    if kind == 'missing_prefix_confidence': candidate[0].pop('p')
    if kind == 'boundary': candidate[0]['start'] = 0
    if kind == 'reversed': candidate[2]['start'] = candidate[1]['start']
    if kind == 'long': candidate[0].update(start=0, end=9)
    if kind == 'nan': candidate[2]['start'] = float('nan')
    if kind == 'outside': candidate[-1]['end'] = 15
    original = damaged_words()
    assert lyrics_timing.repair_word_spans(Path('audio.wav'), original, lambda p, l: candidate) == original


@pytest.mark.parametrize('exception', [RuntimeError('unavailable'), OSError('missing'), subprocess.TimeoutExpired('worker', 120)])
def test_optional_retry_failure_keeps_chart_and_cleans_crop(crop_calls, exception):
    def unavailable(p, l): raise exception
    original = damaged_words()
    assert lyrics_timing.repair_word_spans(Path('audio.wav'), original, unavailable) == original
    assert not crop_calls[0][1].exists()


def test_healthy_rests_and_sustained_words_do_not_trigger_extra_work(crop_calls):
    words = [{'start': 1, 'end': 8.9, 'text': 'Held', 'segment': 0},
             {'start': 40, 'end': 41, 'text': 'after', 'segment': 0}]
    assert lyrics_timing.repair_word_spans(Path('missing.wav'), words, lambda p, l: pytest.fail('no transcription')) == words
    assert not crop_calls


def test_retry_count_is_bounded_even_when_every_candidate_is_rejected(crop_calls):
    words = [w for i in range(5) for w in damaged_words(i * 40, i)]
    stats = {}
    assert lyrics_timing.repair_word_spans(Path('audio.wav'), words, lambda p, l: [], stats=stats) == words
    assert len(crop_calls) == lyrics_timing.MAX_REPAIR_CROPS == stats['attempted_crops']


def test_missing_anchors_do_not_invent_a_recovery(crop_calls):
    words = damaged_words()[:3]
    assert lyrics_timing.repair_word_spans(Path('missing.wav'), words, lambda p, l: pytest.fail('no retry')) == words
    assert not crop_calls


@pytest.mark.parametrize('provider', ['groq', 'local'])
def test_both_transcription_paths_use_bounded_local_recovery(monkeypatch, crop_calls, provider):
    monkeypatch.setattr(lyrics_align, 'TRANSCRIBER', provider)
    calls = []
    def local(path, language, **kwargs):
        calls.append((path, language, kwargs))
        return recovered_words() if kwargs else damaged_words()
    monkeypatch.setattr(lyrics_align, 'transcribe_words_groq', lambda p, l: damaged_words())
    monkeypatch.setattr(lyrics_align, 'transcribe_words_local', local)
    result = lyrics_align.transcribe_words(Path('whole.wav'), 'en')
    assert result[0]['start'] == 18.54
    assert calls[-1][1:] == ('en', {'timeout': 120})
    assert len(calls) == (1 if provider == 'groq' else 2)


def cached_chart(tmp_path, monkeypatch):
    audio = tmp_path / 'source.wav'
    pcm = b'\0\0' * (22050 * 60)
    with wave.open(str(audio), 'wb') as handle:
        handle.setparams((1, 2, 22050, 0, 'NONE', 'not compressed'))
        handle.writeframes(pcm)
    from chordlyze_backend.analysis import engine
    monkeypatch.setattr(engine, '_decode_to_wav', shutil.copyfile)
    words = [{k: v for k, v in w.items() if k != 'segment'} for w in damaged_words()]
    for w in words: w['time'] = w.pop('start')
    entry = {'track_id': 'song', 'isrc': 'TEST123', 'audio_sha256': hashlib.sha256(pcm).hexdigest(),
             'chart_revision': 'stable', 'chords': [{'start': 0, 'end': 60, 'label': 'C:maj'}],
             'tempo': {'beats': [1, 2, 3]}, 'lyrics': {'matched': 'transcribed', 'lines': [
                 {'time': 0, 'text': 'We can walk beside the shore', 'words': words},
                 {'time': 30, 'text': 'Next phrase', 'words': [
                     {'time': 30, 'end': 31, 'text': 'Next'}, {'time': 31, 'end': 32, 'text': 'phrase'}]}]}}
    for name in ['track-song.json', 'isrc-TEST123.json']:
        (tmp_path / name).write_text(json.dumps(entry))
    return entry, audio


def test_cached_audio_repair_dry_run_apply_backup_alias_and_idempotence(tmp_path, monkeypatch, crop_calls):
    entry, audio = cached_chart(tmp_path, monkeypatch)
    original = (tmp_path / 'track-song.json').read_bytes()
    call = lambda **kwargs: repair_lyrics_from_audio.repair(tmp_path, 'song', audio,
        transcribe=lambda p, l: recovered_words(), **kwargs)
    dry = call()
    assert dry['changed'] and not dry['applied'] and dry['changed_lines'] == 1
    assert (tmp_path / 'track-song.json').read_bytes() == original
    done = call(apply=True)
    assert done['applied']
    result = json.loads((tmp_path / 'track-song.json').read_text())
    assert result['lyrics']['lines'][0]['time'] == 18.54
    assert result['lyrics']['lines'][1:] == entry['lyrics']['lines'][1:]
    assert {k: v for k, v in result.items() if k != 'lyrics'} == {k: v for k, v in entry.items() if k != 'lyrics'}
    assert json.loads((tmp_path / 'isrc-TEST123.json').read_text()) == result
    assert (Path(done['backup']) / 'track-song.json').read_bytes() == original
    assert not call(apply=True)['changed']


def test_wrong_recording_is_rejected_before_transcription_or_writes(tmp_path, monkeypatch, crop_calls):
    entry, audio = cached_chart(tmp_path, monkeypatch)
    entry['audio_sha256'] = '0' * 64
    (tmp_path / 'track-song.json').write_text(json.dumps(entry))
    with pytest.raises(ValueError, match='Recording identity'):
        repair_lyrics_from_audio.repair(tmp_path, 'song', audio, apply=True,
            transcribe=lambda p, l: pytest.fail('must not transcribe'))
    assert not crop_calls and not list(tmp_path.glob('lyrics-audio-backup-*'))


def test_concurrent_chart_change_is_not_overwritten(tmp_path, monkeypatch, crop_calls):
    entry, audio = cached_chart(tmp_path, monkeypatch)
    def changed(p, l):
        entry['chart_revision'] = 'newer'
        (tmp_path / 'track-song.json').write_text(json.dumps(entry))
        return recovered_words()
    with pytest.raises(ValueError, match='chart changed'):
        repair_lyrics_from_audio.repair(tmp_path, 'song', audio, apply=True, transcribe=changed)
    assert json.loads((tmp_path / 'track-song.json').read_text()) == entry
    assert not list(tmp_path.glob('lyrics-audio-backup-*'))


@pytest.mark.parametrize('difference', ['audio_sha256', 'lyrics'])
def test_different_alias_is_not_overwritten(tmp_path, monkeypatch, crop_calls, difference):
    entry, audio = cached_chart(tmp_path, monkeypatch)
    alias = copy.deepcopy(entry)
    alias[difference] = 'different' if difference == 'audio_sha256' else {'lines': []}
    (tmp_path / 'isrc-TEST123.json').write_text(json.dumps(alias))
    repair_lyrics_from_audio.repair(tmp_path, 'song', audio, apply=True, transcribe=lambda p, l: recovered_words())
    assert json.loads((tmp_path / 'isrc-TEST123.json').read_text()) == alias
