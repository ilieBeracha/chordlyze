"""Chordlyze backend API.

POST /analyze_track           — chords for a song, no client audio: the saved
                                analysis, else a fresh one from the 30 s iTunes
                                preview (later upgraded by the ingest worker).
POST /analysis/submit         — whole-song chords recognized off-server.
GET  /analysis/track/{id}     — saved analysis for a track (or its ISRC twin).
GET  /lyrics                  — time-synced lyrics from LRCLIB.
GET  /library                 — every saved analysis.
POST /practice_take           — score a practice recording against the chart.
GET  /health                  — liveness.

Analyses are JSON files under CACHE_DIR: track-<id>.json, isrc-<ISRC>.json,
lyrics4-<digest>.json.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import tempfile
import threading
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

import anyio.to_thread
from fastapi import FastAPI, Form, HTTPException, UploadFile
from pydantic import BaseModel

from .analysis.beats import track_beats
from .analysis.chord import parse_label
from .analysis.engine import AudioDecodeError, ChordSegment, merge_adjacent, recognize_chords
from .analysis.keyfinder import analyze

CACHE_DIR = Path(os.environ.get("CHORDLYZE_CACHE",
                                str(Path(__file__).resolve().parent.parent / "analysis_cache")))
CACHE_DIR.mkdir(parents=True, exist_ok=True)

app = FastAPI(title="Chordlyze", version="0.2.0")


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


_MODEL_LOCK = threading.Lock()


def _recognize_locked(path: Path):
    """Chords (model-locked: madmom is not thread-safe) plus beat times."""
    with _MODEL_LOCK:
        segments = recognize_chords(path)
    return segments, track_beats(path)


# MARK: - Saved analyses

def _track_cache_path(track_id: str) -> Path:
    safe = "".join(c for c in track_id if c.isalnum())
    return CACHE_DIR / f"track-{safe}.json"


def _isrc_cache_path(isrc: str) -> Path:
    return CACHE_DIR / f"isrc-{isrc.upper()}.json"


# Recognizers by how much of the harmony they can name. Entries saved before
# the field existed are madmom's.
_MODEL_RANK = {"madmom": 0, "ismir2019": 1}


def _quality(entry: dict) -> tuple[int, int]:
    """(whole song?, recognizer rank): a saved analysis is only ever replaced
    by one at least this good."""
    return (0 if entry.get("source") == "itunes_preview" else 1,
            _MODEL_RANK.get(entry.get("model", "madmom"), 0))


def _save_track(track_id: str, result: dict, title: str | None, artist: str | None,
                isrc: str | None = None, artwork: str | None = None) -> bool:
    """Save under the track id (and its ISRC, when known). False when a better
    analysis is already stored: a preview never replaces a whole song, and a
    maj/min chart never replaces a large-vocabulary one."""
    entry = dict(result)
    entry["track_id"] = track_id
    if title:
        entry["title"] = title
    if artist:
        entry["artist"] = artist
    if artwork:
        entry["artwork"] = artwork
    track_path = _track_cache_path(track_id)
    if track_path.exists() and _quality(json.loads(track_path.read_text())) > _quality(entry):
        return False
    track_path.write_text(json.dumps(entry))
    if isrc:
        path = _isrc_cache_path(isrc)
        if path.exists() and _quality(json.loads(path.read_text())) > _quality(entry):
            return True
        path.write_text(json.dumps(entry))
    return True


def _cached_by_isrc(track_id: str, isrc: str | None,
                    title: str | None, artist: str | None) -> dict | None:
    """Analysis saved under the same ISRC by another track id, if any;
    re-saves it under this track_id for future direct hits."""
    if not isrc:
        return None
    path = _isrc_cache_path(isrc)
    if not path.exists():
        return None
    entry = json.loads(path.read_text())
    _save_track(track_id, entry, title or entry.get("title"),
                artist or entry.get("artist"), isrc)
    return json.loads(_track_cache_path(track_id).read_text())


# MARK: - iTunes preview analysis

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
    duration: float | None = Form(default=None),
) -> dict:
    """The saved analysis when there is one, else chords from the 30 s iTunes
    preview so the song has something right away. Whole-song recognition
    happens off-server (ingest_worker.py) and replaces the preview through
    /analysis/submit. 404 when the song is not on iTunes either."""
    cached = _track_cache_path(track_id)
    if cached.exists():
        return json.loads(cached.read_text())
    if hit := _cached_by_isrc(track_id, isrc, title, artist):
        return hit

    def fetch_and_recognize():
        song = _itunes_lookup(isrc, title, artist)
        if not song:
            raise HTTPException(404, "song not found on iTunes")
        with tempfile.NamedTemporaryFile(suffix=".m4a", delete=False) as tmp:
            with urllib.request.urlopen(song["previewUrl"], timeout=30) as resp:
                tmp.write(resp.read())
            tmp_path = Path(tmp.name)
        try:
            return song, _recognize_locked(tmp_path)
        finally:
            tmp_path.unlink(missing_ok=True)

    try:
        song, (segments, tempo) = await anyio.to_thread.run_sync(fetch_and_recognize)
    except AudioDecodeError as exc:
        raise HTTPException(422, str(exc)) from exc
    except (urllib.error.URLError, TimeoutError) as exc:
        raise HTTPException(503, f"iTunes unavailable: {exc}") from exc

    result = analyze(segments)
    result["tempo"] = tempo
    result["source"] = "itunes_preview"
    result["model"] = "madmom"
    _save_track(track_id, result,
                title or song.get("trackName"), artist or song.get("artistName"),
                isrc, artwork=song.get("artworkUrl100"))
    return json.loads(cached.read_text())


# MARK: - Off-server submission

class SubmittedSegment(BaseModel):
    start: float
    end: float
    label: str


class SubmittedAnalysis(BaseModel):
    """Chords recognized off-server (the ingest worker runs the
    large-vocabulary model on its own machine) for the server to key, score
    and store like any other analysis."""
    track_id: str
    model: str
    segments: list[SubmittedSegment]
    source: str = "youtube"
    title: str | None = None
    artist: str | None = None
    isrc: str | None = None
    artwork: str | None = None
    tempo: dict | None = None


@app.post("/analysis/submit")
def submit_analysis(body: SubmittedAnalysis) -> dict:
    if body.model not in _MODEL_RANK:
        raise HTTPException(422, f"unknown model {body.model!r}")
    if not body.segments:
        raise HTTPException(422, "no segments")
    segments: list[ChordSegment] = []
    for seg in body.segments:
        if seg.end <= seg.start:
            raise HTTPException(422, f"empty segment at {seg.start}")
        if segments and seg.start < segments[-1].end - 1e-6:
            raise HTTPException(422, f"segments overlap or are unordered at {seg.start}")
        try:
            parse_label(seg.label)
        except ValueError as exc:
            raise HTTPException(422, str(exc)) from exc
        segments.append(ChordSegment(seg.start, seg.end, seg.label))
    result = analyze(merge_adjacent(segments))
    result["tempo"] = body.tempo
    result["source"] = body.source
    result["model"] = body.model
    if not _save_track(body.track_id, result, body.title, body.artist, body.isrc,
                       artwork=body.artwork):
        raise HTTPException(409, "a better analysis is already stored for this track")
    return json.loads(_track_cache_path(body.track_id).read_text())


# MARK: - Lyrics

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


def _lrclib(endpoint: str, params: dict):
    """One LRCLIB call. None on 404; 503 to the client when LRCLIB itself is
    down or unreachable, so an outage reads as "try again", never as "no
    lyrics for this song"."""
    q = urllib.parse.urlencode(params)
    req = urllib.request.Request(f"https://lrclib.net/api/{endpoint}?{q}",
                                 headers={"User-Agent": "Chordlyze/0.2"})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None
        raise HTTPException(503, f"lyrics service returned {exc.code}") from exc
    except (urllib.error.URLError, TimeoutError) as exc:
        raise HTTPException(503, f"lyrics service unreachable: {exc}") from exc


def _lrclib_get(params: dict) -> dict | None:
    return _lrclib("get", params)


_TITLE_NOISE = re.compile(
    r"\s*[\(\[][^\)\]]*[\)\]]|\s+-\s+.*$", re.IGNORECASE)


def normalize_title(title: str) -> str:
    """Strip '(feat. X)', '[Remix]', '- Remastered 2011' style noise."""
    cleaned = _TITLE_NOISE.sub("", title).strip()
    return cleaned or title


def score_candidate(cand: dict, title: str, artist: str,
                    duration: float | None) -> float:
    """0..1 match quality for an LRCLIB search result; 0 = reject."""
    from difflib import SequenceMatcher

    def sim(a: str, b: str) -> float:
        return SequenceMatcher(None, a.lower().strip(), b.lower().strip()).ratio()

    title_score = max(sim(cand.get("trackName") or "", title),
                      sim(cand.get("trackName") or "", normalize_title(title)))
    artist_score = sim(cand.get("artistName") or "", artist) if artist else 0.7
    if title_score < 0.55 or artist_score < 0.45:
        return 0.0
    score = 0.55 * title_score + 0.35 * artist_score
    if duration and cand.get("duration"):
        diff = abs(float(cand["duration"]) - duration)
        # A different edit shifts every timestamp — keep the gate tight.
        if diff > 5:
            return 0.0
        score += 0.10 * max(0.0, 1 - diff / 5)
    elif duration is None:
        # No duration to verify against: only accept near-certain matches.
        if score < 0.75:
            return 0.0
    return score


def _search_lrclib(title: str, artist: str, duration: float | None) -> dict | None:
    """Fuzzy fallback: best-scoring search result that carries lyrics."""
    results = _lrclib("search", {"track_name": normalize_title(title),
                                 "artist_name": artist}) or []
    scored = [(score_candidate(c, title, artist, duration), c)
              for c in results if c.get("syncedLyrics") or c.get("plainLyrics")]
    # Synced beats plain at equal score.
    scored.sort(key=lambda t: (t[0], bool(t[1].get("syncedLyrics"))), reverse=True)
    if scored and scored[0][0] > 0:
        return scored[0][1]
    return None


def synthesize_lines(plain: str, duration: float | None) -> list[dict]:
    """Rough line times for unsynced lyrics: char-weighted spread over the song."""
    texts = [ln.strip() for ln in plain.splitlines() if ln.strip()]
    if not texts:
        return []
    if not duration or duration <= 0:
        return [{"time": round(4.0 * i, 2), "text": t} for i, t in enumerate(texts)]
    start, end = duration * 0.05, duration * 0.93
    weights = [max(len(t), 8) for t in texts]
    total = sum(weights)
    lines, at = [], start
    for text, w in zip(texts, weights):
        lines.append({"time": round(at, 2), "text": text})
        at += (end - start) * w / total
    return lines


@app.get("/lyrics")
def lyrics(title: str, artist: str = "", duration: float | None = None,
           album: str | None = None) -> dict:
    """Time-synced lyrics from LRCLIB, cached on disk. Duration/album narrow
    the match to the right version (not a cover/remix) when provided."""
    digest = hashlib.sha256(
        f"{title}|{artist}|{album or ''}|{round(duration) if duration else ''}"
        .lower().encode()).hexdigest()[:24]
    # v4: tighter fuzzy gate (±5s, high bar without duration).
    cached = CACHE_DIR / f"lyrics4-{digest}.json"
    if cached.exists():
        return json.loads(cached.read_text())

    params = {"track_name": title, "artist_name": artist}
    matched = "exact"
    data = None
    if duration or album:
        exact = dict(params)
        if album:
            exact["album_name"] = album
        if duration:
            exact["duration"] = round(duration)
        data = _lrclib_get(exact)
    if data is None:
        data = _lrclib_get(params)
    if data is None or not (data.get("syncedLyrics") or data.get("plainLyrics")):
        data = _search_lrclib(title, artist, duration)
        matched = "fuzzy"
    if data is None:
        raise HTTPException(404, "lyrics not found")

    synced = True
    lines = parse_synced_lyrics(data.get("syncedLyrics") or "")
    if not lines:
        lines = synthesize_lines(data.get("plainLyrics") or "",
                                 duration or data.get("duration"))
        synced = False
    if not lines:
        raise HTTPException(404, "no lyrics for this song")
    result = {"duration": data.get("duration"), "lines": lines,
              "synced": synced, "matched": matched}
    cached.write_text(json.dumps(result))
    return result


# MARK: - Library

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
            "artwork": data.get("artwork"),
            "difficulty": data.get("difficulty"),
            "source": data.get("source"),
            "model": data.get("model", "madmom"),
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


# MARK: - Practice

@app.post("/practice_take")
async def practice_take(
    file: UploadFile,
    track_id: str = Form(...),
    offset: float = Form(default=0.0),
) -> dict:
    """Score a practice recording (instrument only, song in headphones)
    against the track's reference chart."""
    ref_path = _track_cache_path(track_id)
    if not ref_path.exists():
        raise HTTPException(404, "no analysis for this track yet")
    reference = json.loads(ref_path.read_text())

    data = await file.read()
    if not data:
        raise HTTPException(400, "empty upload")
    suffix = Path(file.filename or "take.m4a").suffix or ".m4a"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
        tmp.write(data)
        tmp_path = Path(tmp.name)
    try:
        segments, _tempo = await anyio.to_thread.run_sync(_recognize_locked, tmp_path)
    except AudioDecodeError as exc:
        raise HTTPException(422, str(exc)) from exc
    finally:
        tmp_path.unlink(missing_ok=True)

    from .practice import score_take
    report = score_take(reference.get("chords", []),
                        [s.to_dict() for s in segments], offset)
    if "error" in report:
        raise HTTPException(422, report["error"])
    return {"take_id": uuid.uuid4().hex[:12], "track_id": track_id, **report}
