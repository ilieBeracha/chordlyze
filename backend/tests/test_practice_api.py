"""Endpoint regressions: decoder choice, recording span, errors and provenance."""
import asyncio
import io
import json

import pytest
from fastapi import HTTPException, UploadFile

from chordlyze_backend import main
from chordlyze_backend.analysis.engine import ChordSegment, Recognition
from chordlyze_backend.analysis.ismir import RecognitionUnavailable
from chordlyze_backend.analysis.provenance import ANALYSIS_VERSION, MODEL_REVISIONS


@pytest.fixture(autouse=True)
def cache(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "CACHE_DIR", tmp_path)
    return tmp_path


def reference(cache, *, model="ismir2019", source="youtube", label="C:maj7"):
    (cache / "track-song.json").write_text(json.dumps({
        "source": source, "model": model, "analysis_version": ANALYSIS_VERSION,
        "model_revision": MODEL_REVISIONS[model],
        "chords": [{"start": 0, "end": 8, "label": label}],
    }))


def call(*, content=b"recording", offset=0):
    return asyncio.run(main.practice_take(
        file=UploadFile(io.BytesIO(content), filename="take.wav"), track_id="song", offset=offset))


def test_practice_uses_rich_recognizer_duration_and_metadata(cache, monkeypatch):
    reference(cache)
    seen = []

    def recognize(path, model, max_duration):
        assert model == "ismir2019" and max_duration == 600
        assert path.read_bytes() == b"recording"
        seen.append(path)
        return Recognition([ChordSegment(0, 4, "C:maj7")], 4, "a" * 64, model)

    monkeypatch.setattr(main, "recognize_audio", recognize)
    monkeypatch.setattr(main, "track_beats", lambda _: pytest.fail("practice does not need beat tracking"))
    out = call(offset=2)
    assert out["accuracy"] == 1.0
    assert (out["covered_start"], out["covered_end"]) == (2, 6)
    assert out["model"] == "ismir2019" and out["analysis_version"] == ANALYSIS_VERSION
    assert out["model_revision"] == MODEL_REVISIONS["ismir2019"]
    assert out["scoring_version"] == 2 and out["comparison"] == "root_quality"
    assert out["audio_duration"] == 4 and out["audio_sha256"] == "a" * 64
    assert all(not path.exists() for path in seen)


def test_legacy_reference_declares_limited_grading_resolution(cache, monkeypatch):
    reference(cache, model="madmom", label="C:maj")
    monkeypatch.setattr(main, "recognize_audio", lambda *a, **k:
                        Recognition([ChordSegment(0, 4, "C:maj7")], 4, "a" * 64, "ismir2019"))
    out = call()
    assert out["accuracy"] == 1.0
    assert out["comparison"] == "major_minor"


def test_unavailable_model_returns_retryable_error_and_removes_upload(cache, monkeypatch):
    reference(cache)
    seen = []

    def unavailable(path, **kwargs):
        seen.append(path)
        raise RecognitionUnavailable("missing weights")

    monkeypatch.setattr(main, "recognize_audio", unavailable)
    with pytest.raises(HTTPException) as exc:
        call()
    assert exc.value.status_code == 503
    assert all(not path.exists() for path in seen)


def test_preview_cannot_be_used_as_a_song_timeline(cache, monkeypatch):
    reference(cache, source="itunes_preview")
    monkeypatch.setattr(main, "recognize_audio", lambda *a, **k: pytest.fail("must reject before recognition"))
    with pytest.raises(HTTPException) as exc:
        call()
    assert exc.value.status_code == 409


def test_empty_upload_is_rejected(cache):
    reference(cache)
    with pytest.raises(HTTPException) as exc:
        call(content=b"")
    assert exc.value.status_code == 400


def test_unrepresentable_quality_is_not_reported_as_bad_playing(cache, monkeypatch):
    reference(cache, label="C:maj6")
    monkeypatch.setattr(main, "recognize_audio", lambda *a, **k:
                        Recognition([ChordSegment(0, 4, "C:maj")], 4, "a" * 64, "ismir2019"))
    with pytest.raises(HTTPException) as exc:
        call()
    assert exc.value.status_code == 422
    assert "unsupported" in exc.value.detail
