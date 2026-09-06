"""Per-user libraries over a shared chart cache, and Spotify-token auth."""
import json

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

from chordlyze_backend import auth, main
from chordlyze_backend.auth import current_user
from chordlyze_backend.analysis.provenance import model_metadata
from chordlyze_backend.main import SubmittedAnalysis, SubmittedSegment, submit_analysis
from chordlyze_backend.users import UserLibrary


@pytest.fixture(autouse=True)
def cache(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "CACHE_DIR", tmp_path)
    auth.forget_all()
    return tmp_path


def _publish(track):
    segs = [SubmittedSegment(start=0, end=4, label="C:maj"), SubmittedSegment(start=4, end=8, label="G:maj")]
    submit_analysis(SubmittedAnalysis(track_id=track, segments=segs, title=track, artist="Band",
                                      audio_duration=8, audio_sha256="a" * 64, source="youtube",
                                      **model_metadata("ismir2019")))


def test_user_library_store(cache):
    lib = UserLibrary(cache, "spotify:user/ilie")
    assert lib.track_ids() == [] and not lib.contains("a")
    assert lib.add("a", now=1) and lib.add("b", now=2) and not lib.add("a", now=3)
    assert lib.track_ids() == ["b", "a"]
    assert lib.remove("a") and not lib.remove("a")
    assert lib.track_ids() == ["b"]
    assert lib.path.parent == cache / "users" and "/" not in lib.path.name.removeprefix("spotify_user_ilie")
    assert UserLibrary(cache, "other").track_ids() == []


def test_libraries_are_separate_and_charts_are_shared(cache):
    _publish("t1")
    _publish("t2")
    assert main.request_song(main.SongRequest(track_id="t1", title="t1"), user="alice")["saved"]
    assert [i["track_id"] for i in main.library(user="alice")["items"]] == ["t1"]
    assert main.library(user="bob")["items"] == []
    assert main.song_status("t1", user="bob")["analysis"] is not None, "charts are global"
    assert main.song_status("t1", user="bob")["saved"] is False
    assert main.save_song("t2", user="bob") == {"track_id": "t2", "saved": True}
    assert [i["track_id"] for i in main.library(user="bob")["items"]] == ["t2"]
    assert {i["track_id"] for i in main.catalog(user="bob")["items"]} == {"t1", "t2"}
    assert main.forget_song("t2", user="bob")["saved"] is False
    assert main.library(user="bob")["items"] == [] and (cache / "track-t2.json").exists()
    with pytest.raises(HTTPException) as missing:
        main.save_song("nope", user="bob")
    assert missing.value.status_code == 404


def test_requesting_a_pending_song_saves_it(cache):
    status = main.request_song(main.SongRequest(track_id="new", title="New"), user="alice")
    assert status["analysis"] is None and status["saved"] is True
    assert main.library(user="alice")["items"] == [], "no chart yet, so nothing to list"
    _publish("new")
    assert [i["track_id"] for i in main.library(user="alice")["items"]] == ["new"]


def test_auth_verifies_with_spotify_and_caches(monkeypatch):
    calls = []

    def lookup(token):
        calls.append(token)
        if token == "expired":
            raise HTTPException(401, "expired")
        return "user-" + token

    monkeypatch.setattr(auth, "lookup", lookup)
    assert current_user("Bearer abc") == "user-abc"
    assert current_user("Bearer abc") == "user-abc" and calls == ["abc"], "one Spotify call per token"
    for header in (None, "", "Basic abc", "Bearer "):
        with pytest.raises(HTTPException) as denied:
            current_user(header)
        assert denied.value.status_code == 401
    with pytest.raises(HTTPException) as expired:
        current_user("Bearer expired")
    assert expired.value.status_code == 401


def test_http_requires_a_token(cache, monkeypatch):
    monkeypatch.setattr(auth, "lookup", lambda token: token)
    client = TestClient(main.app)
    assert client.get("/health").status_code == 200
    assert client.get("/library").status_code == 401
    assert client.get("/catalog").status_code == 401
    assert client.get("/song/t1").status_code == 401
    assert client.post("/song/request", json={"track_id": "t1", "title": "T"}).status_code == 401
    _publish("t1")
    assert client.post("/library/t1", headers={"Authorization": "Bearer carol"}).json()["saved"] is True
    mine = client.get("/library", headers={"Authorization": "Bearer carol"}).json()["items"]
    assert [i["track_id"] for i in mine] == ["t1"]
    assert client.get("/library", headers={"Authorization": "Bearer dave"}).json()["items"] == []
    assert json.loads((cache / "users").glob("*.json").__next__().read_text())["user_id"] == "carol"


def test_lyrics_lookup_accepts_the_worker_token(monkeypatch):
    monkeypatch.setenv("CHORDLYZE_WORKER_TOKEN", "worker-secret")
    monkeypatch.setattr(auth, "lookup", lambda token: "user-" + token)
    assert main.user_or_worker("Bearer worker-secret") == "worker"
    assert main.user_or_worker("Bearer spotify-token") == "user-spotify-token"
    with pytest.raises(HTTPException) as denied:
        main.user_or_worker(None)
    assert denied.value.status_code == 401
    monkeypatch.delenv("CHORDLYZE_WORKER_TOKEN")
    auth.forget_all()
    assert main.user_or_worker("Bearer worker-secret") == "user-worker-secret", \
        "without a configured worker the token is treated as a Spotify token and verified"
