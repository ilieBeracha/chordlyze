"""Analysis upgrades must refresh old revisions without downgrading charts."""
import asyncio
import io
import json

import pytest
from fastapi import HTTPException

import ingest_worker
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
    assert main.get_track_analysis("song")["analysis_stale"] is True
    assert main.library()["items"][0]["analysis_stale"] is True


def test_current_revision_upgrades_old_and_rejects_old_worker(cache):
    submit_analysis(submission(versioned=False))
    out = submit_analysis(submission())
    assert is_current(out)
    assert out["analysis_stale"] is False
    with pytest.raises(HTTPException) as exc:
        submit_analysis(submission(versioned=False))
    assert exc.value.status_code == 409
    assert is_current(main.get_track_analysis("song"))


def test_current_revision_requires_verifiable_provenance(cache):
    with pytest.raises(HTTPException) as exc:
        submit_analysis(submission(audio_sha256=None))
    assert exc.value.status_code == 422
    with pytest.raises(HTTPException):
        submit_analysis(submission(model_revision="unrecognized-checkpoint"))


def test_current_metadata_survives_isrc_alias_and_library(cache):
    submit_analysis(submission(isrc="ILTEST000001"))
    alias = main.get_track_analysis("alias", isrc="ILTEST000001")
    assert alias["track_id"] == "alias" and is_current(alias)
    rows = main.library()["items"]
    assert len(rows) == 2
    assert all(is_current(row) and row["isrc"] == "ILTEST000001" for row in rows)


def test_worker_requeues_same_model_when_revision_is_outdated(monkeypatch):
    items = [{"track_id": "preview", "title": "P", "source": "itunes_preview"},
             {"track_id": "old", "title": "O", "model": "ismir2019"},
             {"track_id": "current", "title": "C", **model_metadata("ismir2019")},
             {"track_id": "old-version", "title": "V", **model_metadata("ismir2019"),
              "analysis_version": ANALYSIS_VERSION - 1}]
    monkeypatch.setattr(ingest_worker.urllib.request, "urlopen",
                        lambda *a, **k: io.BytesIO(json.dumps({"items": items}).encode()))
    assert [row["track_id"] for row in ingest_worker.pending()] == ["preview", "old", "old-version"]


def test_ingest_uses_shared_recognition_and_submits_full_provenance(monkeypatch, tmp_path):
    result = Recognition([ChordSegment(0, 4, "C:maj7")], 4, "b" * 64, "ismir2019")
    monkeypatch.setattr(ingest_worker, "recognize_audio", lambda *a, **k: result)
    monkeypatch.setattr(ingest_worker, "track_beats", lambda _: None)
    monkeypatch.setattr(ingest_worker, "_post_json", lambda path, payload: payload)
    payload = ingest_worker.submit(tmp_path / "audio.wav", {"track_id": "song", "title": "Song"})
    assert is_current(payload)
    assert payload["audio_sha256"] == "b" * 64 and payload["audio_duration"] == 4
    assert payload["segments"][0]["label"] == "C:maj7"


def test_stale_preview_refreshes_on_analysis_request(cache, monkeypatch):
    main._save_track("song", {"source": "itunes_preview", "model": "madmom", "chords": []}, "Song", "Band")
    monkeypatch.setattr(main, "_itunes_lookup", lambda *a: {"previewUrl": "https://example.test/audio"})
    monkeypatch.setattr(main.urllib.request, "urlopen", lambda *a, **k: io.BytesIO(b"audio"))
    monkeypatch.setattr(main, "_recognize_locked", lambda _: (
        Recognition([ChordSegment(0, 4, "C:maj")], 4, "c" * 64, "madmom"), None))
    result = asyncio.run(main.analyze_track(track_id="song", isrc=None, title="Song", artist="Band",
                                           duration=4, itunes_id=None))
    assert is_current(result) and result["source"] == "itunes_preview"


def test_atomic_write_preserves_previous_result_on_serialization_failure(cache):
    path = cache / "result.json"
    main._write_analysis(path, {"value": 1})
    with pytest.raises(ValueError):
        main._write_analysis(path, {"value": float("nan")})
    assert json.loads(path.read_text()) == {"value": 1}
    assert sorted(p.name for p in cache.iterdir()) == ["result.json"]
