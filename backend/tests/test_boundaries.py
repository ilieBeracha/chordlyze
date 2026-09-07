"""Timing edits preserve interval invariants and personal history across reads."""
import asyncio
import io
import json

import pytest
from fastapi import UploadFile
from fastapi.testclient import TestClient

from chordlyze_backend import auth, main
from chordlyze_backend.analysis.engine import ChordSegment, Recognition
from chordlyze_backend.analysis.provenance import model_metadata
from chordlyze_backend.users import UserLibrary


@pytest.fixture
def api(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "CACHE_DIR", tmp_path)
    monkeypatch.setattr(auth, "lookup", lambda token: token)
    auth.forget_all()
    chart = {**model_metadata("ismir2019"), "source": "youtube", "audio_duration": 12,
             "audio_sha256": "a"*64, "tempo": {"bpm": 120, "beats": [0, .5, 1]},
             "chords": [{"start": 0, "end": 4, "label": "C:maj"},
                        {"start": 4, "end": 8, "label": "G:maj"},
                        {"start": 8, "end": 12, "label": "A:min"}]}
    (tmp_path / "track-song.json").write_text(json.dumps(chart))
    return TestClient(main.app), tmp_path


def current(client, user="alice"):
    return client.get("/song/song", headers={"Authorization": f"Bearer {user}"}).json()["analysis"]


def edit(client, operation, **kwargs):
    payload = {"chart_revision": current(client)["chart_revision"], "operation": operation, **kwargs}
    return client.patch("/library/song/chords/boundary", headers={"Authorization": "Bearer alice"}, json=payload)


def spans(chart):
    return [(s["start"], s["end"], s["label"]) for s in chart["chords"]]


def test_move_start_end_preserves_neighbors_and_undo(api):
    client, cache = api
    original = current(client)
    moved = edit(client, "move", start=0, end=4, at=5).json()["analysis"]
    assert spans(moved) == [(0, 5, "C:maj"), (5, 8, "G:maj"), (8, 12, "A:min")]
    assert moved["boundaries_edited"] and moved["can_undo"]
    assert moved["tempo"] == original["tempo"]
    assert current(client) == moved
    assert current(client, "bob") == original
    moved_again = edit(client, "move", start=5, end=8, edge="start", at=3).json()["analysis"]
    assert spans(moved_again)[0:2] == [(0, 3, "C:maj"), (3, 8, "G:maj")]
    assert UserLibrary(cache, "alice").corrections("song")["history"], "history lives on disk"
    assert spans(edit(client, "undo").json()["analysis"]) == spans(moved)
    restored = edit(client, "undo").json()["analysis"]
    assert restored["chart_revision"] == original["chart_revision"] and not restored["can_undo"]
    assert edit(client, "undo").status_code == 409


def test_split_rename_merge_restore_and_undo(api):
    client, _ = api
    original = current(client)
    split = edit(client, "split", start=0, end=4, at=2.5, name="Dm7").json()["analysis"]
    assert spans(split)[:2] == [(0, 2.5, "C:maj"), (2.5, 4, "D:min7")]
    # Existing chord-name editor continues to work on newly created intervals.
    renamed = client.put("/library/song/chords", headers={"Authorization": "Bearer alice"}, json={
        "chart_revision": split["chart_revision"], "start": 2.5, "end": 4, "name": "F/A"})
    assert renamed.status_code == 200
    merged = edit(client, "merge", start=0, end=2.5, name="Cmaj7").json()["analysis"]
    assert spans(merged)[0] == (0, 4, "C:maj7") and not merged["boundaries_edited"]
    assert spans(edit(client, "restore").json()["analysis"]) == spans(original)
    assert spans(edit(client, "undo").json()["analysis"]) == spans(merged)


@pytest.mark.parametrize("kwargs", [
    {"operation": "move", "start": 0, "end": 4, "at": 0},
    {"operation": "move", "start": 0, "end": 4, "at": 8},
    {"operation": "move", "start": 0, "end": 4, "edge": "start", "at": 1},
    {"operation": "merge", "start": 8, "end": 12},
    {"operation": "split", "start": 0, "end": 4, "at": 4, "name": "G"},
    {"operation": "split", "start": 0, "end": 4, "at": 2, "name": "nonsense"},
    {"operation": "split", "start": 0, "end": 4, "at": 2},
])
def test_invalid_edits_never_write(api, kwargs):
    client, cache = api
    original = current(client)
    assert edit(client, **kwargs).status_code == 422
    assert current(client) == original
    assert not UserLibrary(cache, "alice").contains("song")


def test_gaps_and_stale_edit_rejected(api):
    client, cache = api
    original = current(client)
    assert edit(client, "move", start=0, end=4, at=5).status_code == 200
    assert edit(client, "split", chart_revision=original["chart_revision"], start=0, end=4, at=2, name="G").status_code == 409
    path = cache / "track-song.json"
    replacement = json.loads(path.read_text())
    replacement["chords"][1]["start"] = 4.5
    path.write_text(json.dumps(replacement))
    assert current(client)["corrections_stale"] and not current(client)["can_undo"]
    assert edit(client, "merge", start=0, end=4).status_code == 422


def test_legacy_label_overlay_migrates_without_losing_corrections(api):
    client, cache = api
    original = json.loads((cache / "track-song.json").read_text())
    UserLibrary(cache, "alice").set_corrections("song", {
        "base_revision": main.corrections.revision(original), "labels": {"0": "D:min"}})
    assert spans(current(client))[0][2] == "D:min"
    moved = edit(client, "move", start=0, end=4, at=4.5).json()["analysis"]
    assert spans(moved)[0] == (0, 4.5, "D:min")
    assert spans(edit(client, "undo").json()["analysis"])[0] == (0, 4, "D:min")


def test_scoring_uses_corrected_boundary(api, monkeypatch):
    client, _ = api
    edit(client, "move", start=0, end=4, at=5)
    chart = current(client)
    monkeypatch.setattr(main, "recognize_audio", lambda *a, **k: Recognition([ChordSegment(0, 1, "C:maj")], 1, "b"*64, "ismir2019"))
    result = asyncio.run(main.practice_take(file=UploadFile(io.BytesIO(b"audio"), filename="take.wav"),
        track_id="song", offset=4, chart_revision=chart["chart_revision"], user="alice"))
    assert result["accuracy"] == 1, "seconds 4–5 now belong to C"
