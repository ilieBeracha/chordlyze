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


# Pitch sets per quality, defined here independently of the app's chord table
# so the test cannot inherit a mistake from the code it checks.
INTERVALS = {
    "maj": [0, 4, 7], "min": [0, 3, 7], "dim": [0, 3, 6], "aug": [0, 4, 8],
    "sus2": [0, 2, 7], "sus4": [0, 5, 7],
    "7": [0, 4, 7, 10], "maj7": [0, 4, 7, 11], "min7": [0, 3, 7, 10],
    "dim7": [0, 3, 6, 9], "hdim7": [0, 3, 6, 10],
}
DEGREE_SEMITONES = {"3": 4, "b3": 3, "5": 7, "b7": 10, "7": 11}


def _chord(label: str, dur: float) -> np.ndarray:
    """Harte label -> audio. 'C:maj/3' puts the third in the bass."""
    root, _, rest = label.partition(":")
    quality, _, bass_degree = (rest or "maj").partition("/")
    f0 = NOTE_FREQS[root]
    bass = f0 * SEMITONE ** DEGREE_SEMITONES[bass_degree] if bass_degree else f0
    sig = _tone(bass / 2, dur)  # bass note an octave down
    for iv in INTERVALS[quality]:
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


# One madmom decoder frame plus float slack.
BOUNDARY_TOLERANCE = 0.11

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

    # Placement, separately from identity: every true chord change must have a
    # recognized change within one decoder frame (100 ms) of it. Measured on
    # this pipeline: median 0 ms, max 100 ms — a model swap that lags gets
    # caught here rather than on stage.
    starts = [s.start for s in segments[1:]]
    for i in range(1, len(progression)):
        truth = i * chord_dur
        nearest = min(starts, key=lambda s: abs(s - truth))
        assert abs(nearest - truth) <= BOUNDARY_TOLERANCE, \
            f"change {i}: expected at {truth}s, nearest recognized at {nearest}s"

    result = analyze(segments)
    assert result["key"] == expected_key
    romans = [c["roman"] for c in result["chords"] if c["roman"]]
    assert romans, "no roman numerals produced"


# Chords outside madmom's maj/min vocabulary. What it returns today, measured
# on this synth: sevenths, sus and inversions collapse to the triad on the
# same root; diminished chords get a wrong root or quality. The strict xfail
# flips to a failure the day a recognizer gets these right, so the swap is
# noticed rather than assumed.
RICH = ["C:7", "F:maj7", "D:min7", "B:hdim7", "G#:dim7",
        "C:sus4", "G:sus2", "B:dim", "E:aug",
        "C:maj/3", "A:min/b3", "G:7/b7"]


@pytest.fixture(scope="module")
def rich_segments(tmp_path_factory):
    wav = tmp_path_factory.mktemp("rich") / "rich.wav"
    synth_progression(RICH, 2.0, str(wav))
    return recognize_chords(wav)


@pytest.mark.parametrize("index,label", list(enumerate(RICH)), ids=RICH)
def test_rich_chord_root_survives(rich_segments, index, label):
    """Sevenths, sus, aug and inversions keep their root even when the
    quality is lost. Diminished is the documented exception."""
    got = dominant_label(rich_segments, index * 2.0 + 0.25, (index + 1) * 2.0 - 0.25)
    if "dim" in label:
        pytest.xfail("madmom has no dim label; the nearest triad may sit on another root")
    assert got.partition(":")[0] == label.partition(":")[0], f"{label} -> {got}"


@pytest.mark.xfail(reason="madmom maj/min vocabulary cannot name these", strict=True)
@pytest.mark.parametrize("index,label", list(enumerate(RICH)), ids=RICH)
def test_rich_chord_named_exactly(rich_segments, index, label):
    got = dominant_label(rich_segments, index * 2.0 + 0.25, (index + 1) * 2.0 - 0.25)
    assert got == label, f"{label} -> {got}"
