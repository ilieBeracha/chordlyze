"""Parsing of plain and enhanced (word-timestamped) LRC lyrics."""
from chordlyze_backend.main import parse_synced_lyrics

PLAIN = """[00:12.34] Hello world
[00:15.00] Second line

[00:18.50]
[00:20.00] Third line
"""

ENHANCED = """[00:12.00] <00:12.00> Never <00:12.40> gonna <00:12.80> give
[00:14.00] <00:14.10> you <00:14.50> up
"""


def test_plain_lines():
    lines = parse_synced_lyrics(PLAIN)
    assert [l["text"] for l in lines] == ["Hello world", "Second line", "Third line"]
    assert lines[0]["time"] == 12.34
    assert all("words" not in l for l in lines)


def test_enhanced_words():
    lines = parse_synced_lyrics(ENHANCED)
    assert len(lines) == 2
    first = lines[0]
    assert first["text"] == "Never gonna give"
    assert [w["text"] for w in first["words"]] == ["Never", "gonna", "give"]
    assert [w["time"] for w in first["words"]] == [12.0, 12.4, 12.8]
    assert lines[1]["words"][1] == {"time": 14.5, "text": "up"}


def test_enhanced_line_time_kept():
    lines = parse_synced_lyrics(ENHANCED)
    assert lines[0]["time"] == 12.0
    assert lines[1]["time"] == 14.0


def test_derive_isrc():
    from chordlyze_backend.main import _derive_isrc
    assert _derive_isrc("shazam-USUM71703861", None) == "USUM71703861"
    assert _derive_isrc("shazam-1234", None) is None          # shazamID fallback key
    assert _derive_isrc("5AQuUEnrfiGM3dfUBTIutY", None) is None  # spotify id
    assert _derive_isrc("anything", "GBAYE0601498") == "GBAYE0601498"
