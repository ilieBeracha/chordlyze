"""Catalog disagreement triggers acoustic review, never a global timing offset."""
import copy
from pathlib import Path

import pytest

from chordlyze_backend import lyrics_timing


def fixture(offset=0):
    tokens = ['We hear the river calling', 'Follow the moon', 'Under quiet skies',
              'Hold the moment', 'Watch the stars', 'Stay beside me']
    times = [[30, 31.92, 38.36, 38.78, 39.1], [41, 41.6, 42.2],
             [45, 45.6, 46.2], [50, 50.6, 51.2], [55, 55.6, 56.2], [60, 60.6, 61.2]]
    lines = []
    for text, starts in zip(tokens, times):
        ends = starts[1:] + [starts[-1] + .4]
        lines.append({'time': starts[0] + offset, 'text': text, 'words': [
            {'time': a + offset, 'end': b + offset, 'text': word}
            for word, a, b in zip(text.split(), starts, ends)]})
    catalog = {'synced': True, 'lines': [{'text': text, 'time': start}
               for text, start in zip(tokens, [36, 41, 45, 50, 55, 60])]}
    return catalog, lines


def recognition(lines, first=36):
    result = []
    for i, line in enumerate(lines[:2]):
        for j, w in enumerate(line['words']):
            start, end = w['time'], w['end']
            if i == 0 and j == 0: start, end = first, first + .6
            if i == 0 and j == 1: start, end = first + .6, 38.36
            result.append({'text': w['text'], 'start': start, 'end': end, 'p': .95})
    return result


def test_valid_geometry_still_detects_early_prefix_and_allows_recording_offset():
    catalog, lines = fixture()
    assert lyrics_timing.catalog_onset_conflicts(catalog, lines) == {0: (36, {0, 1})}
    catalog, lines = fixture(offset=7)
    assert lyrics_timing.catalog_onset_conflicts(catalog, lines) == {0: (43, {0, 1})}


@pytest.mark.parametrize('kind', ['unsynced', 'insufficient', 'unmeasured', 'healthy', 'unrelated'])
def test_catalog_cannot_manufacture_a_conflict_without_corroboration(kind):
    catalog, lines = fixture()
    if kind == 'unsynced': catalog['synced'] = False
    if kind == 'insufficient': lines = lines[:3]
    if kind == 'unmeasured':
        for line in lines[1:]: line['words'][0]['estimated'] = True
    if kind == 'healthy':
        lines[0]['time'] = 36
        lines[0]['words'][0].update(time=36, end=36.6)
        lines[0]['words'][1]['time'] = 36.6
    if kind == 'unrelated':
        for line in catalog['lines']: line['text'] = 'Different words'
    assert not lyrics_timing.catalog_onset_conflicts(catalog, lines)


@pytest.fixture
def crop(tmp_path, monkeypatch):
    audio = tmp_path / 'audio.wav'
    audio.touch()
    calls = []
    def make(source, output, start, end):
        calls.append((start, end))
        output.touch()
    monkeypatch.setattr(lyrics_timing, '_crop', make)
    return audio, calls


def test_audio_recovers_only_conflicting_prefix_preserving_all_other_evidence(crop):
    audio, calls = crop
    catalog, original = fixture()
    snapshot = copy.deepcopy(original)
    stats = {}
    def transcribe(*args):
        return [{**w, 'start': w['start'] - calls[-1][0], 'end': w['end'] - calls[-1][0]}
                for w in recognition(original)]
    result = lyrics_timing.review_catalog_onsets(audio, catalog, original, 70, transcribe, stats=stats)
    assert result[0]['time'] == result[0]['words'][0]['time'] == 36
    assert result[0]['words'][1]['time'] == 36.6
    assert result[0]['words'][2:] == original[0]['words'][2:]
    assert result[1:] == original[1:]
    assert original == snapshot
    assert stats == {'onset_review_crops': 1, 'recovered_onsets': 1, 'unresolved_onsets': 0}


def test_wrong_catalog_cannot_overrule_acoustically_confirmed_sustained_word(crop):
    audio, calls = crop
    catalog, original = fixture()
    def transcribe(*args):
        return [{'text': w['text'], 'start': w['time'] - calls[-1][0],
                 'end': w['end'] - calls[-1][0], 'p': .95}
                for line in original[:2] for w in line['words']]
    assert lyrics_timing.review_catalog_onsets(audio, catalog, original, 70, transcribe) == original


@pytest.mark.parametrize('fault', ['missing', 'repeated', 'drift', 'low_confidence', 'unavailable',
                                  'uncertain_evidence', 'uncertain_first_word'])
def test_unresolved_conflict_retains_source_stamps_but_cannot_claim_measured_onsets(crop, fault):
    audio, calls = crop
    catalog, original = fixture()
    def transcribe(*args):
        if fault == 'unavailable': raise RuntimeError('offline')
        words = recognition(original)
        if fault == 'missing': words.pop(0)
        if fault == 'repeated': words += copy.deepcopy(words[:5])
        if fault == 'drift':
            for word in words: word.update(start=word['start'] + 1, end=word['end'] + 1)
        if fault == 'low_confidence':
            for word in words: word['p'] = .01
        if fault == 'uncertain_evidence':
            for word in words: word['estimated'] = True
        if fault == 'uncertain_first_word': words[0]['p'] = .16
        return [{**w, 'start': w['start'] - calls[-1][0], 'end': w['end'] - calls[-1][0]} for w in words]
    result = lyrics_timing.review_catalog_onsets(audio, catalog, original, 70, transcribe)
    assert result[0]['time'] == 36
    assert all(w['estimated'] for w in result[0]['words'][:2])
    assert [w['time'] for w in result[0]['words']] == [w['time'] for w in original[0]['words']]
    assert result[0]['words'][2:] == original[0]['words'][2:]
    assert result[1:] == original[1:]


def test_low_confidence_stamps_retain_evidence_but_never_become_measured_word_anchors():
    from chordlyze_backend.lyrics_align import time_lines, transcribed_lines
    heard = [{'start': i, 'end': i + .5, 'text': f'word{i}', 'p': .95, 'segment': 0} for i in range(12)]
    heard[0]['p'] = .04
    heard[1]['estimated'] = True
    text = ' '.join(w['text'] for w in heard)
    aligned, _, _ = time_lines([text], heard)
    transcribed = transcribed_lines(heard)
    for result in (aligned, transcribed):
        assert result[0]['words'][0] == {'time': 0, 'end': .5, 'text': 'word0', 'estimated': True}
        assert result[0]['words'][1]['estimated'] is True
        assert 'estimated' not in result[0]['words'][2]


def test_missing_audio_still_publishes_conflict_as_uncertain():
    catalog, original = fixture()
    result, review = lyrics_timing.finalize_line_timings(Path('/missing/audio.wav'), original, 70,
        lambda *args: pytest.fail('no audio available'), catalog=catalog)
    assert review['onset_conflicts'] == 1
    assert result[0]['words'][0]['estimated']
    assert result[0]['time'] == 36
