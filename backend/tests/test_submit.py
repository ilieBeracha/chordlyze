"""Off-server analysis submission and the never-downgrade rule."""
import json

import pytest
from fastapi import HTTPException

from chordlyze_backend import main
from chordlyze_backend.main import SubmittedAnalysis, SubmittedSegment, submit_analysis
from ingest_worker import parse_lab


@pytest.fixture(autouse=True)
def cache(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "CACHE_DIR", tmp_path)
    return tmp_path


def _submission(track="t1", model="ismir2019", labels=("C:maj7", "A:min7", "F:maj/3", "G:7"),
                **extra):
    segs = [SubmittedSegment(start=i * 2.0, end=(i + 1) * 2.0, label=l) for i, l in enumerate(labels)]
    return SubmittedAnalysis(track_id=track, model=model, segments=segs, title="Song",
                             artist="Band", **extra)


def test_submit_stores_scored_analysis(cache):
    out = submit_analysis(_submission(tempo={"bpm": 120.0, "beats": [0.5, 1.0]}))
    assert out["model"] == "ismir2019" and out["source"] == "youtube"
    assert out["key"] == "C major"
    assert [c["roman"] for c in out["chords"]] == ["Imaj7", "vi7", "IV", "V7"]
    assert out["analyzed_end"] == 8.0
    assert out["tempo"]["bpm"] == 120.0
    saved = json.loads((cache / "track-t1.json").read_text())
    assert saved["title"] == "Song" and saved["difficulty"] is not None


def test_submit_merges_touching_duplicates(cache):
    out = submit_analysis(_submission(labels=("C:maj", "C:maj", "G:maj")))
    assert [(c["start"], c["end"], c["label"]) for c in out["chords"]] == \
        [(0.0, 4.0, "C:maj"), (4.0, 6.0, "G:maj")]


@pytest.mark.parametrize("bad", [
    dict(labels=("C:maj", "H:maj")),
    dict(model="mystery"),
    dict(labels=()),
])
def test_submit_rejects_garbage(bad):
    with pytest.raises(HTTPException) as exc:
        submit_analysis(_submission(**bad))
    assert exc.value.status_code == 422


def test_submit_rejects_overlap():
    segs = [SubmittedSegment(start=0, end=3, label="C:maj"),
            SubmittedSegment(start=2, end=4, label="G:maj")]
    with pytest.raises(HTTPException) as exc:
        submit_analysis(SubmittedAnalysis(track_id="t", model="ismir2019", segments=segs))
    assert exc.value.status_code == 422


def test_large_vocabulary_result_is_never_downgraded(cache):
    submit_analysis(_submission(track="t2"))
    with pytest.raises(HTTPException) as exc:
        submit_analysis(_submission(track="t2", model="madmom", labels=("C:maj", "A:min")))
    assert exc.value.status_code == 409
    assert json.loads((cache / "track-t2.json").read_text())["model"] == "ismir2019"
    # A newer large-vocabulary result may replace it.
    out = submit_analysis(_submission(track="t2", labels=("D:maj", "B:min")))
    assert out["chords"][0]["label"] == "D:maj"


def test_preview_never_replaces_whole_song(cache):
    assert main._save_track("t3", {"chords": [], "source": "youtube", "model": "madmom"}, "S", "B")
    assert not main._save_track("t3", {"chords": [], "source": "itunes_preview", "model": "madmom"}, "S", "B")
    assert json.loads((cache / "track-t3.json").read_text())["source"] == "youtube"


def test_whole_song_madmom_upgrades_to_ismir_but_not_back(cache):
    assert main._save_track("t4", {"chords": [], "source": "youtube", "model": "madmom"}, "S", "B")
    assert main._save_track("t4", {"chords": [], "source": "youtube", "model": "ismir2019"}, "S", "B")
    assert not main._save_track("t4", {"chords": [], "source": "upload"}, "S", "B")  # legacy = madmom


def test_parse_lab():
    text = "0.0\t0.02\tN\n0.02\t1.99\tC:7\n1.99\t4.0\tAb:dim7\n4.0\t4.0\tG:maj\nbroken line\n"
    assert parse_lab(text) == [
        {"start": 0.0, "end": 0.02, "label": "N"},
        {"start": 0.02, "end": 1.99, "label": "C:7"},
        {"start": 1.99, "end": 4.0, "label": "Ab:dim7"},
    ]
