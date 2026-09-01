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


_ISRC_RE = re.compile(r"[A-Za-z]{2}[A-Za-z0-9]{3}\d{7}")


def _isrc_cache_path(isrc: str) -> Path:
    return CACHE_DIR / f"isrc-{isrc.upper()}.json"


def _derive_isrc(track_id: str, isrc: str | None) -> str | None:
    """Mic captures are keyed 'shazam-<isrc>' — recover the ISRC from the key
    so the same song analyzed via Spotify and via mic share one analysis."""
    if isrc:
        return isrc
    if track_id.startswith("shazam-") and _ISRC_RE.fullmatch(track_id[7:]):
        return track_id[7:]
    return None


def _save_track(track_id: str, result: dict, title: str | None, artist: str | None,
                isrc: str | None = None) -> None:
    entry = dict(result)
    entry["track_id"] = track_id
    if title:
        entry["title"] = title
    if artist:
        entry["artist"] = artist
    _track_cache_path(track_id).write_text(json.dumps(entry))
    if derived := _derive_isrc(track_id, isrc):
        path = _isrc_cache_path(derived)
        if path.exists():
            old = json.loads(path.read_text())
            # A full-song analysis is never downgraded to a preview excerpt.
            if old.get("source") != "itunes_preview" and entry.get("source") == "itunes_preview":
                return
        path.write_text(json.dumps(entry))


def _cached_by_isrc(track_id: str, isrc: str | None,
                    title: str | None, artist: str | None) -> dict | None:
    """Analysis saved under the same ISRC by the other source, if any;
    re-saves it under this track_id for future direct hits."""
    derived = _derive_isrc(track_id, isrc)
    if not derived:
        return None
    path = _isrc_cache_path(derived)
    if not path.exists():
        return None
    entry = json.loads(path.read_text())
    _save_track(track_id, entry, title or entry.get("title"),
                artist or entry.get("artist"), derived)
    return json.loads(_track_cache_path(track_id).read_text())


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
    if hit := _cached_by_isrc(track_id, isrc, title, artist):
        return hit

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
                title or song.get("trackName"), artist or song.get("artistName"),
                isrc)
    return json.loads(cached.read_text())


_LRC_LINE = re.compile(r"\[(\d+):(\d+(?:\.\d+)?)\]\s?(.*)")
# Enhanced LRC (A2) word timestamps inside a line: <mm:ss.xx>word
_LRC_WORD = re.compile(r"<(\d+):(\d+(?:\.\d+)?)>")


def parse_synced_lyrics(synced: str) -> list[dict]:
    """LRC -> [{time, text, words?}]. Word-level times included when the file
    uses enhanced LRC (<mm:ss.xx> tags); plain lines get just time+text."""
    lines = []
    for raw in synced.splitlines():
        m = _LRC_LINE.match(raw.strip())
        if not m:
            continue
        body = m.group(3).strip()
        words = []
        # Split "…<t1>w1 <t2>w2…" into (stamp, following-text) pairs.
        parts = _LRC_WORD.split(body)
        if len(parts) > 1:
            # parts = [prefix, min, sec, text, min, sec, text, ...]
            for i in range(1, len(parts) - 2, 3):
                t = int(parts[i]) * 60 + float(parts[i + 1])
                text = parts[i + 2].strip()
                if text:
                    words.append({"time": round(t, 3), "text": text})
        clean = " ".join(w["text"] for w in words) if words else body
        if not clean:
            continue
        line = {"time": int(m.group(1)) * 60 + float(m.group(2)), "text": clean}
        if words:
            line["words"] = words
        lines.append(line)
    return lines


def _lrclib_get(params: dict) -> dict | None:
    q = urllib.parse.urlencode(params)
    req = urllib.request.Request(f"https://lrclib.net/api/get?{q}",
                                 headers={"User-Agent": "Chordlyze/0.1"})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None
        raise


@app.get("/lyrics")
def lyrics(title: str, artist: str = "", duration: float | None = None,
           album: str | None = None) -> dict:
    """Time-synced lyrics from LRCLIB, cached on disk. Duration/album narrow
    the match to the right version (not a cover/remix) when provided."""
    digest = hashlib.sha256(
        f"{title}|{artist}|{album or ''}|{round(duration) if duration else ''}"
        .lower().encode()).hexdigest()[:24]
    # v2: includes word-level times when available.
    cached = CACHE_DIR / f"lyrics2-{digest}.json"
    if cached.exists():
        return json.loads(cached.read_text())

    params = {"track_name": title, "artist_name": artist}
    data = None
    if duration or album:
        exact = dict(params)
        if album:
            exact["album_name"] = album
        if duration:
            exact["duration"] = round(duration)
        data = _lrclib_get(exact)
    if data is None:
        data = _lrclib_get(params)  # relaxed fallback
    if data is None:
        raise HTTPException(404, "lyrics not found")

    lines = parse_synced_lyrics(data.get("syncedLyrics") or "")
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
def get_track_analysis(track_id: str, isrc: str | None = None) -> dict:
    cached = _track_cache_path(track_id)
    if cached.exists():
        return json.loads(cached.read_text())
    if hit := _cached_by_isrc(track_id, isrc, None, None):
        return hit
    raise HTTPException(404, "no analysis for this track yet")


@app.get("/analysis/{analysis_id}")
def get_analysis(analysis_id: str) -> dict:
    cached = CACHE_DIR / f"{analysis_id}.json"
    if not cached.exists():
        raise HTTPException(404, "analysis not found")
    return json.loads(cached.read_text())
