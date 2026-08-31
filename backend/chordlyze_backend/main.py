"""Chordlyze backend API.

POST /analyze        — multipart audio upload, returns chords + key + roman numerals.
GET  /analysis/{id}  — fetch a cached analysis by content hash.
GET  /health         — liveness.

Results are cached on disk keyed by SHA-256 of the audio bytes, so re-analyzing
the same track is instant.
"""
from __future__ import annotations

import hashlib
import json
import re
import tempfile
import threading
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

import anyio.to_thread
from fastapi import FastAPI, Form, HTTPException, UploadFile

from .analysis.engine import AudioDecodeError, recognize_chords
from .analysis.keyfinder import analyze

import os

CACHE_DIR = Path(os.environ.get("CHORDLYZE_CACHE",
                                str(Path(__file__).resolve().parent.parent / "analysis_cache")))
CACHE_DIR.mkdir(parents=True, exist_ok=True)

app = FastAPI(title="Chordlyze", version="0.1.0")


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


_MODEL_LOCK = threading.Lock()


def _recognize_locked(path: Path):
    with _MODEL_LOCK:
        return recognize_chords(path)


def _track_cache_path(track_id: str) -> Path:
    safe = "".join(c for c in track_id if c.isalnum())
    return CACHE_DIR / f"track-{safe}.json"


def _save_track(track_id: str, result: dict, title: str | None, artist: str | None) -> None:
    entry = dict(result)
    entry["track_id"] = track_id
    if title:
        entry["title"] = title
    if artist:
        entry["artist"] = artist
    _track_cache_path(track_id).write_text(json.dumps(entry))


@app.post("/analyze")
async def analyze_upload(
    file: UploadFile,
    track_id: str | None = Form(default=None),
    title: str | None = Form(default=None),
    artist: str | None = Form(default=None),
) -> dict:
    data = await file.read()
    if not data:
        raise HTTPException(400, "empty upload")
    digest = hashlib.sha256(data).hexdigest()
    cached = CACHE_DIR / f"{digest}.json"
    if cached.exists():
        result = json.loads(cached.read_text())
        if track_id:
            _save_track(track_id, result, title, artist)
        return result

    suffix = Path(file.filename or "audio").suffix or ".bin"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
        tmp.write(data)
        tmp_path = Path(tmp.name)
    try:
        # Off the event loop so uploads/health stay responsive; the lock keeps
        # the (non-thread-safe) madmom model to one inference at a time.
        segments = await anyio.to_thread.run_sync(_recognize_locked, tmp_path)
    except AudioDecodeError as exc:
        raise HTTPException(422, str(exc)) from exc
    finally:
        tmp_path.unlink(missing_ok=True)

    result = analyze(segments)
    result["id"] = digest
    cached.write_text(json.dumps(result))
    if track_id:
        _save_track(track_id, result, title, artist)
    return result


def _itunes_query(url: str) -> list[dict]:
    with urllib.request.urlopen(url, timeout=15) as resp:
        results = json.loads(resp.read()).get("results", [])
    return [r for r in results if r.get("previewUrl")]


def _itunes_lookup(isrc: str | None, title: str | None, artist: str | None) -> dict | None:
    """Find a song on iTunes; returns the first result dict or None.

    The public lookup-by-ISRC rarely resolves, so title+artist search is the
    reliable path; ISRC is tried first as a free shot.
    """
    if isrc:
        songs = _itunes_query(
            f"https://itunes.apple.com/lookup?isrc={urllib.parse.quote(isrc)}&entity=song")
        if songs:
            return songs[0]
    if title:
        term = urllib.parse.quote(f"{title} {artist or ''}".strip())
        songs = _itunes_query(
            f"https://itunes.apple.com/search?term={term}&entity=song&limit=1")
        if songs:
            return songs[0]
    return None


@app.post("/analyze_track")
async def analyze_track(
    track_id: str = Form(...),
    isrc: str | None = Form(default=None),
    title: str | None = Form(default=None),
    artist: str | None = Form(default=None),
) -> dict:
    """Fetch the song's public iTunes preview and analyze it — no client audio needed."""
    cached = _track_cache_path(track_id)
    if cached.exists():
        return json.loads(cached.read_text())

    def fetch_and_recognize():
        song = _itunes_lookup(isrc, title, artist)
        if song is None:
            raise HTTPException(404, "song not found on iTunes")
        with tempfile.NamedTemporaryFile(suffix=".m4a", delete=False) as tmp:
            with urllib.request.urlopen(song["previewUrl"], timeout=30) as resp:
                tmp.write(resp.read())
            tmp_path = Path(tmp.name)
        try:
            with _MODEL_LOCK:
                return song, recognize_chords(tmp_path)
        finally:
            tmp_path.unlink(missing_ok=True)

    try:
        song, segments = await anyio.to_thread.run_sync(fetch_and_recognize)
    except AudioDecodeError as exc:
        raise HTTPException(422, str(exc)) from exc

    result = analyze(segments)
    result["source"] = "itunes_preview"
    _save_track(track_id, result,
                title or song.get("trackName"), artist or song.get("artistName"))
    return json.loads(cached.read_text())


_LRC_LINE = re.compile(r"\[(\d+):(\d+(?:\.\d+)?)\]\s?(.*)")


@app.get("/lyrics")
def lyrics(title: str, artist: str = "") -> dict:
    """Time-synced lyrics from LRCLIB, cached on disk."""
    digest = hashlib.sha256(f"{title}|{artist}".lower().encode()).hexdigest()[:24]
    cached = CACHE_DIR / f"lyrics-{digest}.json"
    if cached.exists():
        return json.loads(cached.read_text())

    q = urllib.parse.urlencode({"track_name": title, "artist_name": artist})
    req = urllib.request.Request(f"https://lrclib.net/api/get?{q}",
                                 headers={"User-Agent": "Chordlyze/0.1"})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            raise HTTPException(404, "lyrics not found") from exc
        raise

    lines = []
    for raw in (data.get("syncedLyrics") or "").splitlines():
        m = _LRC_LINE.match(raw.strip())
        if m and m.group(3).strip():
            lines.append({"time": int(m.group(1)) * 60 + float(m.group(2)),
                          "text": m.group(3).strip()})
    if not lines:
        raise HTTPException(404, "no synced lyrics for this song")
    result = {"duration": data.get("duration"), "lines": lines}
    cached.write_text(json.dumps(result))
    return result


@app.get("/library")
def library() -> dict:
    items = []
    for path in sorted(CACHE_DIR.glob("track-*.json"),
                       key=lambda p: p.stat().st_mtime, reverse=True):
        data = json.loads(path.read_text())
        items.append({
            "track_id": data.get("track_id", path.stem.removeprefix("track-")),
            "title": data.get("title"),
            "artist": data.get("artist"),
            "key": data.get("key"),
        })
    return {"items": items}


@app.get("/analysis/track/{track_id}")
def get_track_analysis(track_id: str) -> dict:
    cached = _track_cache_path(track_id)
    if not cached.exists():
        raise HTTPException(404, "no analysis for this track yet")
    return json.loads(cached.read_text())


@app.get("/analysis/{analysis_id}")
def get_analysis(analysis_id: str) -> dict:
    cached = CACHE_DIR / f"{analysis_id}.json"
    if not cached.exists():
        raise HTTPException(404, "analysis not found")
    return json.loads(cached.read_text())
