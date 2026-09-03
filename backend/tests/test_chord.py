"""Canonical chord parsing/formatting and its use in numerals and scoring."""
import pytest

from chordlyze_backend.analysis.chord import Chord, display, parse_display, parse_label
from chordlyze_backend.analysis.engine import ChordSegment
from chordlyze_backend.analysis.keyfinder import KeyEstimate, analyze, roman_numeral
from chordlyze_backend.practice import score_take


@pytest.mark.parametrize("label,expected", [
    ("C:maj", Chord(0, "maj")),
    ("A:min", Chord(9, "min")),
    ("Bb:7", Chord(10, "7")),
    ("F#:min7", Chord(6, "min7")),
    ("C:maj/3", Chord(0, "maj", bass=4)),
    ("C:maj/5", Chord(0, "maj", bass=7)),
    ("G:7/b7", Chord(7, "7", bass=5)),
    ("D", Chord(2, "maj")),
    ("D/5", Chord(2, "maj", bass=9)),
    ("E:min11", Chord(4, "min11")),
])
def test_parse_label(label, expected):
    assert parse_label(label) == expected


def test_no_chord_and_garbage():
    assert parse_label("N") is None
    assert parse_display("N.C.") is None
    with pytest.raises(ValueError):
        parse_label("H:maj")
    with pytest.raises(ValueError):
        parse_label("C:maj/8")


@pytest.mark.parametrize("label,name", [
    ("C:maj", "C"), ("A:min", "Am"), ("B:dim", "B°"), ("C:aug", "C+"),
    ("D:sus4", "Dsus4"), ("G:7", "G7"), ("F:maj7", "Fmaj7"), ("A:min7", "Am7"),
    ("B:hdim7", "Bø7"), ("C:maj/3", "C/E"), ("F#:min7/b7", "F#m7/E"),
    ("E:min11", "Emin11"), ("N", "N.C."),
])
def test_display_round_trips(label, name):
    assert display(label) == name
    if label != "N":
        assert parse_display(name) == parse_label(label)


def test_display_parses_flats_and_unicode():
    assert parse_display("Bb") == Chord(10, "maj")
    assert parse_display("E♭m") == Chord(3, "min")
    assert parse_display("C/E") == Chord(0, "maj", bass=4)


def test_transpose_moves_bass_too():
    assert Chord(0, "maj", bass=4).transposed(-2).display == "A#/D"
    assert Chord(0, "maj", bass=4).transposed(12) == Chord(0, "maj", bass=4)


def test_label_round_trip_keeps_bass_degree():
    for label in ["C:maj/3", "G:7/b7", "A:min", "E:min7/5"]:
        assert parse_label(label).label == label


def test_family_drives_key_and_numeral_case():
    key = KeyEstimate("C", "major", 1.0)
    assert roman_numeral("G:7", key) == "V7"
    assert roman_numeral("D:min7", key) == "ii7"
    assert roman_numeral("F:maj7", key) == "IVmaj7"
    assert roman_numeral("B:hdim7", key) == "viiø7"
    assert roman_numeral("A#:maj", key) == "bVII"
    assert roman_numeral("C:maj/3", key) == "I"


def test_analyze_reports_coverage_and_extended_key():
    segs = [ChordSegment(0, 4, "C:maj7"), ChordSegment(4, 8, "A:min7"),
            ChordSegment(8, 12, "F:maj7"), ChordSegment(12, 16, "G:7"),
            ChordSegment(16, 17.5, "N")]
    out = analyze(segs)
    assert out["key"] == "C major"
    assert out["analyzed_end"] == 17.5
    assert [c["roman"] for c in out["chords"]] == ["Imaj7", "vi7", "IVmaj7", "V7", None]


def test_analyze_empty_coverage():
    assert analyze([])["analyzed_end"] == 0.0


def test_practice_ignores_bass_but_not_quality():
    ref = [{"start": 0, "end": 4, "label": "C:maj/3"}, {"start": 4, "end": 8, "label": "A:min"}]
    played_root_position = [{"start": 0, "end": 4, "label": "C:maj"},
                            {"start": 4, "end": 8, "label": "A:min"}]
    assert score_take(ref, played_root_position)["accuracy"] == 1.0
    wrong_quality = [{"start": 0, "end": 4, "label": "C:min"},
                     {"start": 4, "end": 8, "label": "A:min"}]
    assert score_take(ref, wrong_quality)["accuracy"] == 0.5
