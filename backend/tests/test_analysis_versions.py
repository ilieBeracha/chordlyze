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


def version_two_chart(cache):
    submit_analysis(submission(analysis_version=2, source="youtube", isrc="ILTEST000001"))
    path = main._track_cache_path("song")
    entry = json.loads(path.read_text())
    entry["lyrics"] = {"lines": [{"time": 0, "text": "Existing words"}], "synced": True}
    main._write_analysis(path, entry)
    main._write_analysis(main._isrc_cache_path("ILTEST000001"), entry)
    return entry


def test_rhythm_upgrade_keeps_existing_chart_lyrics_and_calibration_visible(cache):
    from chordlyze_backend.users import UserLibrary
    entry = version_two_chart(cache)
    mine = UserLibrary(cache, "tester")
    mine.add("song")
    mine.set_timing("song", {"offset": 1, "scale": 1})
    status = main.song_status("song", user="tester")
    assert status["job"]["state"] == "ready"
    assert status["analysis"]["chords"] == entry["chords"]
    assert status["analysis"]["analysis_stale"] is True
    assert status["lyrics"] == entry["lyrics"]
    assert status["saved"] is True and status["timing"]["offset"] == 1
    assert not list(cache.glob("job-*.json"))  # Reading never downloads/reanalyzes.
    assert main.library(user="tester")["items"][0]["chord_count"] == 1
    alias = main._song_status("alias", "ILTEST000001", "tester")
    assert alias["analysis"]["chords"] == entry["chords"]


def test_song_http_response_exposes_version_two_chords_to_existing_clients(cache, monkeypatch):
    from fastapi.testclient import TestClient
    entry = version_two_chart(cache)
    monkeypatch.setitem(main.app.dependency_overrides, main.current_user, lambda: "tester")
    response = TestClient(main.app).get("/song/song")
    assert response.status_code == 200
    assert response.json()["analysis"]["chords"] == entry["chords"]
    assert response.json()["job"]["state"] == "ready"


@pytest.mark.parametrize("state", ["queued", "processing", "failed", "unavailable", "ready"])
def test_old_chart_remains_visible_during_and_after_upgrade_failures(cache, state):
    from chordlyze_backend.song_jobs import SongJobs, write_json
    entry = version_two_chart(cache)
    jobs = SongJobs(cache)
    job = jobs.request({"track_id": "song", "title": "Song", "duration": 4})
    job["state"] = state
    write_json(jobs.path("song"), job)
    status = main.song_status("song", user="tester")
    assert status["job"]["state"] == "ready"
    assert status["analysis"]["chords"] == entry["chords"]


def test_explicit_upgrade_replaces_finished_job_without_hiding_old_chart(cache):
    from chordlyze_backend.song_jobs import SongJobs, write_json
    entry = version_two_chart(cache)
    jobs = SongJobs(cache)
    old = jobs.request({"track_id": "song", "title": "Song", "duration": 4})
    old["state"] = "ready"
    write_json(jobs.path("song"), old)
    request = main.SongRequest(track_id="song", title="Song", duration=4)
    result = main.request_song(request, user="tester")
    new = jobs.get("song")
    assert new["id"] != old["id"] and new["state"] == "queued"
    assert result["analysis"]["chords"] == entry["chords"]
    main.request_song(request, user="tester")
    assert jobs.get("song")["id"] == new["id"]
    submit_analysis(submission())
    assert main.song_status("song", user="tester")["analysis"]["analysis_stale"] is False


@pytest.mark.parametrize("fields", [
    {"source": "itunes_preview"}, {"model_revision": "different-weights"},
    {"analysis_version": 0}, {"model": "madmom"},
])
def test_timing_compatibility_does_not_enable_unsupported_charts(cache, fields):
    entry = version_two_chart(cache)
    main._write_analysis(main._track_cache_path("song"), {**entry, **fields})
    assert main.song_status("song", user="tester")["analysis"] is None
