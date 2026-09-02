"""Beat tracker on a synthetic click track with a known tempo."""
from __future__ import annotations

import numpy as np
import soundfile as sf

from chordlyze_backend.analysis.beats import track_beats

SR = 22050


def test_track_beats_finds_120_bpm(tmp_path):
    period = 0.5  # 120 BPM
    dur = 12.0
    t = np.arange(int(SR * dur)) / SR
    y = np.zeros_like(t)
    for k in range(int(dur / period)):
        start = int(k * period * SR)
        n = int(0.03 * SR)
        y[start:start + n] += np.sin(2 * np.pi * 1000 * t[:n]) * np.exp(-t[:n] * 150)
    wav = tmp_path / "clicks.wav"
    sf.write(wav, y, SR)

    tempo = track_beats(wav)
    assert tempo is not None
    assert abs(tempo["bpm"] - 120) < 3
    gaps = np.diff(tempo["beats"])
    assert abs(float(np.median(gaps)) - period) < 0.03
    assert all(0 <= b <= dur for b in tempo["beats"])


def test_track_beats_silence_is_none(tmp_path):
    wav = tmp_path / "silence.wav"
    sf.write(wav, np.zeros(SR * 3), SR)
    assert track_beats(wav) is None
