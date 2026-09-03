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



def test_normalize_title():
    from chordlyze_backend.main import normalize_title
    assert normalize_title("Song (feat. Foo)") == "Song"
    assert normalize_title("Song - Remastered 2011") == "Song"
    assert normalize_title("Song [Live]") == "Song"
    assert normalize_title("Plain") == "Plain"


def test_score_candidate():
    from chordlyze_backend.main import score_candidate
    good = {"trackName": "Song", "artistName": "Artist", "duration": 200}
    assert score_candidate(good, "Song (feat. X)", "Artist", 202) > 0.7
    wrong = {"trackName": "Other Tune", "artistName": "Nobody", "duration": 200}
    assert score_candidate(wrong, "Song", "Artist", 200) == 0.0
    off_duration = {"trackName": "Song", "artistName": "Artist", "duration": 260}
    assert score_candidate(off_duration, "Song", "Artist", 200) == 0.0


def test_synthesize_lines():
    from chordlyze_backend.main import synthesize_lines
    lines = synthesize_lines("one\n\ntwo\nthree", 100.0)
    assert [l["text"] for l in lines] == ["one", "two", "three"]
    assert lines[0]["time"] == 5.0            # 5% in
    assert lines[-1]["time"] < 93.0           # ends before 93%
    assert lines[0]["time"] < lines[1]["time"] < lines[2]["time"]
    assert synthesize_lines("", 100.0) == []
