"""Objective end-to-end test: synthesize audio with a known chord progression,
run the real recognition pipeline, assert the recognized chords match ground truth.
"""
from __future__ import annotations

import numpy as np
import pytest
import soundfile as sf

from chordlyze_backend.analysis.engine import recognize_chords
from chordlyze_backend.analysis.keyfinder import analyze

SR = 44100
NOTE_FREQS = {  # octave 3/4 roots
    "C": 130.81, "C#": 138.59, "D": 146.83, "D#": 155.56, "E": 164.81,
    "F": 174.61, "F#": 185.00, "G": 196.00, "G#": 207.65, "A": 220.00,
    "A#": 233.08, "B": 246.94,
}
SEMITONE = 2 ** (1 / 12)


def _tone(freq: float, dur: float) -> np.ndarray:
    t = np.linspace(0, dur, int(SR * dur), endpoint=False)
    sig = np.zeros_like(t)
    for h in range(1, 7):  # harmonic-rich, piano-ish
        sig += (1.0 / h) * np.sin(2 * np.pi * freq * h * t)
    env = np.exp(-1.5 * t)  # decay
    return sig * env


def _chord(label: str, dur: float) -> np.ndarray:
    root, _, quality = label.partition(":")
    f0 = NOTE_FREQS[root]
    intervals = [0, 4, 7] if quality in ("", "maj") else [0, 3, 7]
    sig = _tone(f0 / 2, dur)  # bass note an octave down
    for iv in intervals:
        sig += _tone(f0 * SEMITONE ** iv, dur)
        sig += _tone(2 * f0 * SEMITONE ** iv, dur) * 0.5  # octave doubling
    return sig


def synth_progression(labels: list[str], chord_dur: float, path: str,
                      strikes_per_chord: int = 4) -> None:
    parts = []
    strike = chord_dur / strikes_per_chord
    for lbl in labels:
        for _ in range(strikes_per_chord):
            parts.append(_chord(lbl, strike))
    audio = np.concatenate(parts)
    audio /= np.max(np.abs(audio))
    sf.write(path, (audio * 0.8).astype(np.float32), SR)


def dominant_label(segments, start: float, end: float) -> str:
    """Label covering the most time within [start, end)."""
    cover: dict[str, float] = {}
    for seg in segments:
        overlap = min(seg.end, end) - max(seg.start, start)
        if overlap > 0:
            cover[seg.label] = cover.get(seg.label, 0.0) + overlap
    return max(cover.items(), key=lambda kv: kv[1])[0]


CASES = [
    ("major_key", ["C:maj", "F:maj", "G:maj", "C:maj"], "C major"),
    ("pop_loop", ["A:min", "F:maj", "C:maj", "G:maj"], "C major"),
    ("natural_minor", ["A:min", "G:maj", "F:maj", "A:min"], "A minor"),
]


@pytest.mark.parametrize("name,progression,expected_key", CASES, ids=[c[0] for c in CASES])
def test_recognizes_known_progression(tmp_path, name, progression, expected_key):
    chord_dur = 2.0
    wav = tmp_path / f"{name}.wav"
    synth_progression(progression, chord_dur, str(wav))

    segments = recognize_chords(wav)
    assert segments, "no chords recognized"

    for i, expected in enumerate(progression):
        # Ignore 0.25s boundary slack at each edge of the chord window.
        got = dominant_label(segments, i * chord_dur + 0.25, (i + 1) * chord_dur - 0.25)
        assert got == expected, f"chord {i}: expected {expected}, got {got} (all: {[s.label for s in segments]})"

    result = analyze(segments)
    assert result["key"] == expected_key
    romans = [c["roman"] for c in result["chords"] if c["roman"]]
    assert romans, "no roman numerals produced"
