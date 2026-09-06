"""Analysis upgrades must refresh old revisions without downgrading charts."""
import io
import json

import pytest
from fastapi import HTTPException

from chordlyze_backend import main
from chordlyze_backend.analysis.engine import ChordSegment, Recognition
from chordlyze_backend.analysis.provenance import ANALYSIS_VERSION, is_current, model_metadata
from chordlyze_backend.main import SubmittedAnalysis, SubmittedSegment, submit_analysis


@pytest.fixture(autouse=True)
def cache(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "CACHE_DIR", tmp_path)
    return tmp_path


def submission(*, versioned=True, **extra):
    fields = {"track_id": "song", "model": "ismir2019", "title": "Song",
              "segments": [SubmittedSegment(start=0, end=4, label="C:maj7")]}
    if versioned:
        fields.update(**model_metadata("ismir2019"), audio_duration=4, audio_sha256="a" * 64)
    fields.update(extra)
    return SubmittedAnalysis(**fields)


def test_legacy_stays_readable_but_is_marked_stale(cache):
    submit_analysis(submission(versioned=False))
    assert main.get_track_analysis("song", user="tester")["analysis_stale"] is True
    assert main.catalog(user="tester")["items"][0]["analysis_stale"] is True


def test_current_revision_upgrades_old_and_rejects_old_worker(cache):
    submit_analysis(submission(versioned=False))
    out = submit_analysis(submission())
    assert is_current(out)
    assert out["analysis_stale"] is False
    with pytest.raises(HTTPException) as exc:
        submit_analysis(submission(versioned=False))
    assert exc.value.status_code == 409
    assert is_current(main.get_track_analysis("song", user="tester"))


def test_current_revision_requires_verifiable_provenance(cache):
    with pytest.raises(HTTPException) as exc:
        submit_analysis(submission(audio_sha256=None))
    assert exc.value.status_code == 422
    with pytest.raises(HTTPException):
        submit_analysis(submission(model_revision="unrecognized-checkpoint"))


def test_current_metadata_survives_isrc_alias_and_library(cache):
    submit_analysis(submission(isrc="ILTEST000001"))
    alias = main.get_track_analysis("alias", isrc="ILTEST000001", user="tester")
    assert alias["track_id"] == "alias" and is_current(alias)
    rows = main.catalog(user="tester")["items"]
    assert len(rows) == 2
    assert all(is_current(row) and row["isrc"] == "ILTEST000001" for row in rows)


def test_atomic_write_preserves_previous_result_on_serialization_failure(cache):
    path = cache / "result.json"
    main._write_analysis(path, {"value": 1})
    with pytest.raises(ValueError):
        main._write_analysis(path, {"value": float("nan")})
    assert json.loads(path.read_text()) == {"value": 1}
    assert sorted(p.name for p in cache.iterdir()) == ["result.json"]
