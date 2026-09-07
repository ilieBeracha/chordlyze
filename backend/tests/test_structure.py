import copy
import numpy as np
import pytest
from fastapi import HTTPException
from chordlyze_backend.analysis.beats import complete_bars, validate_tempo
from chordlyze_backend.analysis.structure import segment_features
from chordlyze_backend.analysis.provenance import model_metadata
from chordlyze_backend import main


def rhythm():
    positions = [1, 2, 3]*5+[1]
    beats = [i*.5 for i in range(len(positions))]
    return dict(bpm=120, beats=beats, beat_positions=positions, bars=complete_bars(beats, positions, 8),
                rhythm_version=1, sections=[dict(start=0, end=7.5, start_bar=1, end_bar=5, label='A', occurrence=1)])


def test_triple_meter_pickup_and_partial_tail():
    bars = complete_bars([i*.5 for i in range(10)], [2, 3, 1, 2, 3, 1, 2, 3, 1, 2], 5)
    assert bars == [dict(start=1, end=2.5, beats=3), dict(start=2.5, end=4, beats=3)]


def test_variable_meter_cycles_and_tempo_changes():
    assert [b['beats'] for b in complete_bars([0, .5, 1, 1.5, 2.1, 2.7, 3.3, 3.9], [1, 2, 3, 1, 2, 3, 4, 1], 4)] == [3, 4]


def test_missing_beats_do_not_create_giant_bars():
    assert complete_bars([0, .5, 1, 8, 8.5], [1, 2, 3, 4, 1], 9) == []
    assert complete_bars([0, .5, 1, 1.5], [1, 2, 4, 1], 2) == []


@pytest.mark.parametrize('beats', [[0, 1, 1, 2], [0, 2, 1, 3], [0, 1, float('nan'), 3]])
def test_invalid_beat_times_rejected(beats):
    with pytest.raises(ValueError): complete_bars(beats, [1, 2, 3, 1], 4)


def test_repeated_acoustic_sections_and_constant_song():
    a, b = np.eye(2)
    features = np.vstack([np.tile(a, (8, 1)), np.tile(b, (8, 1)), np.tile(a, (8, 1))])
    assert segment_features(features) == [(0, 8, 'A'), (8, 16, 'B'), (16, 24, 'A')]
    assert segment_features(np.ones((32, 12))) == [(0, 32, 'A')]
    assert segment_features(np.ones((3, 12))) == [(0, 3, 'A')]
    assert segment_features(np.empty((0, 12))) == []


def test_repeated_four_chord_pattern_is_not_four_sections():
    assert segment_features(np.tile(np.eye(4), (8, 1))) == [(0, 32, 'A')]


def test_section_estimates_stable_under_small_noise():
    rng = np.random.default_rng(20260907)
    x = np.vstack([np.tile([1., 0], (8, 1)), np.tile([0, 1.], (8, 1)), np.tile([1., 0], (8, 1))])
    assert segment_features(x+rng.normal(0, .02, x.shape)) == [(0, 8, 'A'), (8, 16, 'B'), (16, 24, 'A')]


@pytest.mark.parametrize('mutation', [lambda t: t.update(beats=[0, float('inf')]),
    lambda t: t.update(beat_positions=[1]), lambda t: t['bars'][0].update(end=.8),
    lambda t: t['sections'][0].update(end_bar=99), lambda t: t['sections'][0].update(start_bar=0),
    lambda t: t['sections'][0].update(end=8), lambda t: t['sections'][0].update(occurrence=2),
    lambda t: t.update(rhythm_version=2)])
def test_malformed_worker_structure_is_rejected(mutation):
    t = rhythm(); mutation(t)
    with pytest.raises(ValueError): validate_tempo(t, 8)


def test_legacy_and_unmetered_do_not_invent_bars():
    assert validate_tempo({'bpm': 120, 'beats': [0, .5]}, 1) == {'bpm': 120, 'beats': [0, .5]}
    assert validate_tempo(None, 1) is None
    assert validate_tempo(rhythm(), 8) == rhythm()
    t = rhythm(); t.update(beat_positions=[], bars=[], sections=[])
    assert validate_tempo(t, 8)['bars'] == []


def test_publication_roundtrip_and_invalid_range(tmp_path, monkeypatch):
    monkeypatch.setattr(main, 'CACHE_DIR', tmp_path)
    fields = dict(track_id='rhythm', **model_metadata('ismir2019'), audio_sha256='a'*64,
                  audio_duration=8, tempo=rhythm(), segments=[dict(start=0, end=8, label='C:maj')])
    assert main.submit_analysis(main.SubmittedAnalysis(**fields))['tempo'] == rhythm()
    assert main.get_track_analysis('rhythm', user='test')['tempo'] == rhythm()
    broken = copy.deepcopy(fields); broken['tempo']['bars'][0]['end'] = 99
    with pytest.raises(HTTPException) as error: main.submit_analysis(main.SubmittedAnalysis(**broken))
    assert error.value.status_code == 422
    assert main.get_track_analysis('rhythm', user='test')['tempo'] == rhythm()


def test_audio_sections_repeat_at_known_boundaries():
    from chordlyze_backend.analysis.structure import analyze_sections
    sr = 22050
    bars = [dict(start=i*2, end=(i+1)*2, beats=4) for i in range(24)]
    y = np.zeros(sr*48)
    t = np.arange(sr*2)/sr
    for i in range(24):
        notes = [60, 64, 67] if i < 8 or i >= 16 else [61, 65, 68]
        for midi in notes:
            y[i*sr*2:(i+1)*sr*2] += .07*np.sin(2*np.pi*440*2**((midi-69)/12)*t)
    sections = analyze_sections(y, sr, bars)
    assert [(s['start'], s['end'], s['label'], s['occurrence']) for s in sections] == [
        (0, 16, 'A', 1), (16, 32, 'B', 1), (32, 48, 'A', 2)]


@pytest.mark.parametrize('meter', [2, 3, 4, 5, 7, 12])
def test_bar_contract_accepts_measured_cycle_lengths(meter):
    positions = list(range(1, meter+1))*3+[1]
    beats = [i*.5 for i in range(len(positions))]
    bars = complete_bars(beats, positions, beats[-1]+.5)
    assert len(bars) == 3 and all(bar['beats'] == meter for bar in bars)


def test_unknown_pickup_beats_do_not_establish_a_bar():
    assert complete_bars([0, .5, 1, 1.5, 2, 2.5], [0, 0, 1, 2, 3, 1], 3) == [dict(start=1, end=2.5, beats=3)]
