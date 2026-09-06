"""Genre from iTunes: exact ISRC first, then a confident title/artist match."""
from chordlyze_backend import main
from chordlyze_backend.analysis.provenance import model_metadata
from chordlyze_backend.genre import lookup_genre
from chordlyze_backend.main import SubmittedAnalysis, SubmittedSegment


def _fetch(routes):
    calls = []

    def fetch(url):
        calls.append(url)
        for needle, results in routes.items():
            if needle in url:
                return results
        return []
    fetch.calls = calls
    return fetch


def test_isrc_lookup_is_exact():
    fetch = _fetch({"lookup?isrc=ABC": [{"kind": "song", "primaryGenreName": "Indie Rock", "trackName": "Other"}]})
    assert lookup_genre("Song", "Band", 200, "ABC", fetch=fetch) == "Indie Rock"
    assert len(fetch.calls) == 1


def test_search_needs_a_confident_match():
    fetch = _fetch({"search?": [
        {"trackName": "Song", "artistName": "Band", "trackTimeMillis": 200000, "primaryGenreName": "Pop"},
        {"trackName": "Song (Karaoke)", "artistName": "Nobody", "trackTimeMillis": 90000, "primaryGenreName": "Karaoke"},
    ]})
    assert lookup_genre("Song", "Band", 200, None, fetch=fetch) == "Pop"
    assert lookup_genre("Completely different", "Someone", 30, None, fetch=fetch) is None
    assert lookup_genre("Song", "Band", 200, "MISSING", fetch=_fetch({"search?": []})) is None


def test_submission_stores_genre_and_catalog_exposes_browse_fields(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "CACHE_DIR", tmp_path)
    segs = [SubmittedSegment(start=0, end=4, label="C:maj"), SubmittedSegment(start=4, end=8, label="G:maj"),
            SubmittedSegment(start=8, end=10, label="N"), SubmittedSegment(start=10, end=12, label="C:maj")]
    main.submit_analysis(SubmittedAnalysis(track_id="t1", segments=segs, title="Song", artist="Band", genre="Folk",
                                           tempo={"bpm": 98.0, "beats": [0.5]}, audio_duration=12, audio_sha256="a" * 64,
                                           source="youtube", **model_metadata("ismir2019")))
    item = main.catalog(user="tester")["items"][0]
    assert item["genre"] == "Folk" and item["tempo_bpm"] == 98.0 and item["chord_count"] == 2
    assert main.library(user="tester")["items"] == []
