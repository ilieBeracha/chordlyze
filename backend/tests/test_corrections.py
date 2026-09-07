"""Personal edits through HTTP, persistence, chart replacement and scoring."""
import json

import pytest
from fastapi.testclient import TestClient

from chordlyze_backend import auth, main
from chordlyze_backend.analysis.engine import ChordSegment, Recognition
from chordlyze_backend.analysis.provenance import model_metadata
from chordlyze_backend.users import UserLibrary


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "CACHE_DIR", tmp_path)
    monkeypatch.setattr(auth, "lookup", lambda token: token)
    auth.forget_all()
    chart = {**model_metadata("ismir2019"), "source": "youtube", "track_id": "song",
             "audio_sha256": "a" * 64, "audio_duration": 8, "key": "C major",
             "tempo": {"bpm": 120, "beats": [0, .5]},
             "lyrics": {"synced": True, "lines": [{"time": 0, "text": "Words"}]},
             "chords": [{"start": 0, "end": 4, "label": "C:maj"},
                        {"start": 4, "end": 8, "label": "C:maj"}]}
    (tmp_path / "track-song.json").write_text(json.dumps(chart))
    yield TestClient(main.app), tmp_path
    auth.forget_all()


def headers(user="alice"):
    return {"Authorization": f"Bearer {user}"}


def chart(client, user="alice"):
    return client.get("/song/song", headers=headers(user)).json()["analysis"]


def edit(client, name="Dm7", *, revision=None, start=0, end=4, user="alice"):
    return client.put("/library/song/chords", headers=headers(user), json={
        "chart_revision": revision or chart(client, user)["chart_revision"],
        "start": start, "end": end, "name": name})


def test_persist_isolate_restore_and_keep_timing(client):
    api, cache = client
    original_file = (cache / "track-song.json").read_bytes()
    before = chart(api)
    result = edit(api).json()
    updated = result["analysis"]
    assert result["saved"] is True
    assert [s["label"] for s in updated["chords"]] == ["D:min7", "C:maj"]
    assert updated["chords"][0]["original_label"] == "C:maj"
    assert updated["chart_revision"] != before["chart_revision"]
    assert updated["tempo"] == before["tempo"] and updated["lyrics"] == before["lyrics"]
    assert updated["difficulty"] and updated["chords"][0]["roman"]
    assert UserLibrary(cache, "alice").corrections("song")["segments"][0]["label"] == "D:min7"
    assert chart(api) == updated, "subsequent reads retain the edit"
    assert chart(api, "bob") == before
    assert api.get("/analysis/track/song", headers=headers()).json()["chords"] == updated["chords"]
    assert api.get("/library", headers=headers()).json()["items"][0]["chord_count"] == 2
    assert api.get("/catalog", headers=headers()).json()["items"][0]["chord_count"] == 1
    assert (cache / "track-song.json").read_bytes() == original_file
    restored = edit(api, None).json()["analysis"]
    assert restored["chart_revision"] == before["chart_revision"]
    assert "original_label" not in restored["chords"][0]


@pytest.mark.parametrize("name,label", [("Bb/D", "A#:maj/3"), ("N.C.", "N"), (" F#m7 ", "F#:min7"), ("C7sus4", "C:sus4(b7)")])
def test_supported_chords(client, name, label):
    api, _ = client
    response = edit(api, name)
    assert response.status_code == 200, response.text
    assert response.json()["analysis"]["chords"][0]["label"] == label


@pytest.mark.parametrize("name", ["", " ", "H", "Cgarbage", "C/", "C/D/E", "<script>", "C" * 41])
def test_validation_leaves_chart_unchanged(client, name):
    api, _ = client
    before = chart(api)
    assert edit(api, name).status_code == 422
    assert chart(api) == before


def test_auth_timing_and_concurrent_edits(client):
    api, _ = client
    before = chart(api)
    assert api.put("/library/song/chords", json={}).status_code == 401
    assert edit(api, start=1).status_code == 409
    assert edit(api).status_code == 200
    assert edit(api, "G", revision=before["chart_revision"]).status_code == 409
    assert chart(api)["chords"][0]["label"] == "D:min7"
    assert edit(api, "G", start=4, end=8).status_code == 200
    assert [s["label"] for s in chart(api)["chords"]] == ["D:min7", "G:maj"]


def test_new_recording_does_not_inherit_edits(client):
    api, cache = client
    edit(api)
    old = chart(api)
    path = cache / "track-song.json"
    replacement = json.loads(path.read_text())
    replacement["audio_sha256"] = "b" * 64
    path.write_text(json.dumps(replacement))
    current = chart(api)
    assert current["corrections_stale"] is True
    assert current["chords"][0]["label"] == "C:maj"
    assert edit(api, "F", revision=old["chart_revision"]).status_code == 409
    assert edit(api, "F").json()["analysis"]["corrections_stale"] is False


def test_scoring_uses_personal_chart_and_rejects_changed_take(client, monkeypatch):
    api, _ = client
    before = chart(api)
    edit(api, "Dm7")
    current = chart(api)
    calls = []
    def recognize(*args, **kwargs):
        calls.append(True)
        return Recognition([ChordSegment(0, 4, "D:min7")], 4, "b" * 64, "ismir2019")
    monkeypatch.setattr(main, "recognize_audio", recognize)
    def score(revision, user="alice"):
        return api.post("/practice_take", headers=headers(user),
                        data={"track_id": "song", "offset": "0", "chart_revision": revision},
                        files={"file": ("take.wav", b"recorded audio", "audio/wav")})
    mismatch = score(before["chart_revision"])
    assert mismatch.status_code == 409 and not calls
    report = score(current["chart_revision"])
    assert report.status_code == 200, report.text
    assert report.json()["accuracy"] == 1
    assert report.json()["reference_chart_revision"] == current["chart_revision"]
    assert score(before["chart_revision"], "bob").json()["accuracy"] == 0


def test_preview_cannot_be_edited(client):
    api, cache = client
    before = chart(api)
    path = cache / "track-song.json"
    data = json.loads(path.read_text())
    data["source"] = "itunes_preview"
    path.write_text(json.dumps(data))
    assert edit(api, revision=before["chart_revision"]).status_code == 409
