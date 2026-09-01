"""Difficulty scoring from chord charts."""
from chordlyze_backend.analysis.difficulty import difficulty


def _chart(labels, seconds_each=4.0):
    return [{"start": i * seconds_each, "end": (i + 1) * seconds_each, "label": l}
            for i, l in enumerate(labels)]


def test_easy_song():
    # Four open chords, slow changes.
    d = difficulty(_chart(["G:maj", "D:maj", "E:min", "C:maj"] * 8, 6.0))
    assert d["level"] == "easy"
    assert d["score"] <= 3.5


def test_hard_song():
    # Wide vocabulary, fast changes, barre-heavy.
    labels = ["F:maj", "A#:maj", "C#:min", "G#:maj", "D#:min", "F#:maj",
              "B:min", "C:min"] * 6
    d = difficulty(_chart(labels, 1.5))
    assert d["level"] == "hard"
    assert d["score"] >= 7


def test_empty_and_noise():
    assert difficulty([]) is None
    assert difficulty([{"start": 0, "end": 4, "label": "N"}]) is None


def test_score_bounds():
    d = difficulty(_chart(["C:maj"], 4.0))
    assert 1.0 <= d["score"] <= 10.0
