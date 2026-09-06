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


def test_capo_makes_sharp_keys_open():
    # F# B C#m D#m is E A Bm C#m... with a capo at 2 it is E A Bm C#m; at 4 it is D G Am Bm: open shapes.
    d = difficulty(_chart(["F#:maj", "B:maj", "G#:min", "D#:min"] * 8, 4.0))
    assert d["level"] == "easy", d


def test_passing_chords_do_not_inflate_vocabulary():
    # Four chords carry the song; eight different chords flash by for a beat each.
    labels = []
    for i in range(8):
        labels += ["C:maj", "G:maj", "A:min", "F:maj"]
    steady = difficulty(_chart(labels, 4.0))
    busy = _chart(labels, 4.0)
    passing = ["D:min7", "E:min7", "B:min7", "F#:min7", "C#:min7", "G#:min7", "D#:min7", "A#:min7"]
    for i, label in enumerate(passing):
        t = busy[i * 4]["end"]
        busy[i * 4]["end"] = t - 0.3
        busy.insert(i * 4 + 1, {"start": t - 0.3, "end": t, "label": label})
    assert difficulty(busy)["score"] - steady["score"] < 1.5


def test_empty_and_noise():
    assert difficulty([]) is None
    assert difficulty([{"start": 0, "end": 4, "label": "N"}]) is None


def test_score_bounds():
    d = difficulty(_chart(["C:maj"], 4.0))
    assert 1.0 <= d["score"] <= 10.0
