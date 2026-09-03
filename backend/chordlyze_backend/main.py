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
import sys
import tempfile
import threading
import time
import urllib.error
import uuid
import urllib.parse
import urllib.request
from pathlib import Path

import anyio.to_thread
from fastapi import BackgroundTasks, FastAPI, Form, HTTPException, UploadFile

from .analysis.beats import track_beats
from .analysis.engine import AudioDecodeError, recognize_chords
from .analysis.keyfinder import analyze
from .fulltrack import fetch_full_track

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
    """Chords (model-locked) plus beat times for the same audio."""
    with _MODEL_LOCK:
        segments = recognize_chords(path)
    return segments, track_beats(path)


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
                isrc: str | None = None, artwork: str | None = None) -> None:
    entry = dict(result)
    entry["track_id"] = track_id
    if title:
        entry["title"] = title
    if artist:
        entry["artist"] = artist
    if artwork:
        entry["artwork"] = artwork
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


def _align_digest(title: str, artist: str) -> str:
    return hashlib.sha256(f"{title}|{artist}".lower().encode()).hexdigest()[:24]


def _fetch_lyric_texts(title: str, artist: str) -> list[str]:
    data = _lrclib_get({"track_name": title, "artist_name": artist})
    if data is None or not (data.get("syncedLyrics") or data.get("plainLyrics")):
        data = _search_lrclib(title, artist, None)
    if data is None:
        return []
    if data.get("syncedLyrics"):
        return [ln["text"] for ln in parse_synced_lyrics(data["syncedLyrics"])]
    return [ln.strip() for ln in (data.get("plainLyrics") or "").splitlines()
            if ln.strip()]


def _align_task(audio_path: str, title: str, artist: str) -> None:
    """Background: real lyric line times from the captured audio (whisper)."""
    from .alignment import align
    try:
        out = _align_cache_path(title, artist)
        if out.exists():
            return
        texts = _fetch_lyric_texts(title, artist)
        if not texts:
            return
        aligned = align(audio_path, texts)
        if aligned:
            out.write_text(json.dumps({"duration": None, "lines": aligned,
                                       "synced": True, "matched": "aligned"}))
    finally:
        Path(audio_path).unlink(missing_ok=True)


def _align_cache_path(title: str, artist: str) -> Path:
    return CACHE_DIR / f"align-{_align_digest(title, artist)}.json"


@app.post("/analyze")
async def analyze_upload(
    background: BackgroundTasks,
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
        segments, tempo = await anyio.to_thread.run_sync(_recognize_locked, tmp_path)
    except AudioDecodeError as exc:
        raise HTTPException(422, str(exc)) from exc
    finally:
        tmp_path.unlink(missing_ok=True)

    result = analyze(segments)
    result["tempo"] = tempo
    result["id"] = digest
    cached.write_text(json.dumps(result))
    if track_id:
        _save_track(track_id, result, title, artist)
    if title and not _align_cache_path(title, artist or "").exists():
        # Full-song audio in hand: align real lyric times in the background.
        keep = CACHE_DIR / f"align-src-{digest}{suffix}"
        keep.write_bytes(data)
        background.add_task(_align_task, str(keep), title, artist or "")
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


def _full_track_analysis(title: str, artist: str, duration: float):
    """Whole-song chords+tempo from a matching YouTube upload; None when no
    upload matches or YouTube refuses (logged so a block is visible)."""
    from yt_dlp.utils import DownloadError
    try:
        full = fetch_full_track(title, artist, duration)
    except DownloadError as exc:
        print(f"[fulltrack] youtube refused {title!r}: {exc}", file=sys.stderr)
        return None
    if full is None:
        return None
    try:
        return _recognize_locked(full)
    finally:
        full.unlink(missing_ok=True)


@app.post("/analyze_track")
async def analyze_track(
    track_id: str = Form(...),
    isrc: str | None = Form(default=None),
    title: str | None = Form(default=None),
    artist: str | None = Form(default=None),
    duration: float | None = Form(default=None),
) -> dict:
    """Analyze the whole song from a matching YouTube upload; fall back to the
    30 s iTunes preview. No client audio needed. `duration` (seconds) picks
    the right upload; iTunes' track length is used when it's absent."""
    cached = _track_cache_path(track_id)
    if cached.exists():
        return json.loads(cached.read_text())
    if hit := _cached_by_isrc(track_id, isrc, title, artist):
        return hit

    def fetch_and_recognize():
        song = _itunes_lookup(isrc, title, artist) or {}
        name = title or song.get("trackName")
        who = artist or song.get("artistName") or ""
        length = duration or (song.get("trackTimeMillis") or 0) / 1000
        if name and length:
            if full := _full_track_analysis(name, who, length):
                return song, "youtube", full
        if not song:
            raise HTTPException(404, "song not found on iTunes or YouTube")
        with tempfile.NamedTemporaryFile(suffix=".m4a", delete=False) as tmp:
            with urllib.request.urlopen(song["previewUrl"], timeout=30) as resp:
                tmp.write(resp.read())
            tmp_path = Path(tmp.name)
        try:
            return song, "itunes_preview", _recognize_locked(tmp_path)
        finally:
            tmp_path.unlink(missing_ok=True)

    try:
        song, source, (segments, tempo) = await anyio.to_thread.run_sync(fetch_and_recognize)
    except AudioDecodeError as exc:
        raise HTTPException(422, str(exc)) from exc

    result = analyze(segments)
    result["tempo"] = tempo
    result["source"] = source
    _save_track(track_id, result,
                title or song.get("trackName"), artist or song.get("artistName"),
                isrc, artwork=song.get("artworkUrl100"))
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


def _lrclib(endpoint: str, params: dict):
    q = urllib.parse.urlencode(params)
    req = urllib.request.Request(f"https://lrclib.net/api/{endpoint}?{q}",
                                 headers={"User-Agent": "Chordlyze/0.1"})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None
        raise


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
    # Audio-aligned times (from a full-song capture) beat every other source.
    aligned = _align_cache_path(title, artist)
    if aligned.exists():
        return json.loads(aligned.read_text())

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
        })
    return {"items": items}


@app.post("/library/backfill_difficulty")
def backfill_difficulty() -> dict:
    """Compute difficulty for analyses saved before the field existed."""
    from .analysis.difficulty import difficulty
    updated = 0
    for path in CACHE_DIR.glob("track-*.json"):
        data = json.loads(path.read_text())
        if data.get("difficulty") is not None or not data.get("chords"):
            continue
        data["difficulty"] = difficulty(data["chords"])
        path.write_text(json.dumps(data))
        updated += 1
    return {"updated": updated}


_FULL_BACKFILL_RUNNING = False


def _backfill_full() -> None:
    """Re-analyze preview-based library entries from whole-song audio so
    their chords sit on the real timeline instead of a looped guess."""
    global _FULL_BACKFILL_RUNNING
    _FULL_BACKFILL_RUNNING = True
    try:
        for path in CACHE_DIR.glob("track-*.json"):
            data = json.loads(path.read_text())
            if data.get("source") != "itunes_preview" or not data.get("title"):
                continue
            track_id = data.get("track_id", path.stem.removeprefix("track-"))
            try:
                song = _itunes_lookup(None, data["title"], data.get("artist")) or {}
                length = (song.get("trackTimeMillis") or 0) / 1000
                full = (_full_track_analysis(data["title"], data.get("artist") or "", length)
                        if length else None)
            except Exception as exc:
                print(f"[fulltrack] backfill {data['title']!r} failed: {exc}", file=sys.stderr)
                full = None
            if full is None:
                time.sleep(3)  # iTunes search rate limit (~20/min)
                continue
            segments, tempo = full
            result = analyze(segments)
            result["tempo"] = tempo
            result["source"] = "youtube"
            _save_track(track_id, result, data["title"], data.get("artist"),
                        artwork=data.get("artwork"))
            print(f"[fulltrack] backfilled {data['title']!r}", file=sys.stderr)
    finally:
        _FULL_BACKFILL_RUNNING = False


@app.post("/library/backfill_full")
def backfill_full(background: BackgroundTasks) -> dict:
    """Queue full-song re-analysis of every preview-based entry (slow: one to
    two minutes per song). Reports how many remain; no-op while one runs."""
    remaining = sum(1 for p in CACHE_DIR.glob("track-*.json")
                    if json.loads(p.read_text()).get("source") == "itunes_preview")
    if not _FULL_BACKFILL_RUNNING:
        background.add_task(_backfill_full)
    return {"remaining": remaining, "running": _FULL_BACKFILL_RUNNING}


def _backfill_tempo() -> None:
    """Beat-track saved preview analyses that predate the tempo field. Only
    iTunes-preview analyses can be redone: uploaded audio isn't kept."""
    for path in CACHE_DIR.glob("track-*.json"):
        data = json.loads(path.read_text())
        if "tempo" in data or data.get("source") != "itunes_preview" or not data.get("title"):
            continue
        try:
            song = _itunes_lookup(None, data["title"], data.get("artist"))
            if song is None:
                continue
            with tempfile.NamedTemporaryFile(suffix=".m4a", delete=False) as tmp:
                with urllib.request.urlopen(song["previewUrl"], timeout=30) as resp:
                    tmp.write(resp.read())
                tmp_path = Path(tmp.name)
            try:
                data["tempo"] = track_beats(tmp_path)
            finally:
                tmp_path.unlink(missing_ok=True)
        except Exception:
            continue
        path.write_text(json.dumps(data))
        time.sleep(3)  # iTunes search rate limit (~20/min)


@app.post("/library/backfill_tempo")
def backfill_tempo(background: BackgroundTasks) -> dict:
    missing = sum(1 for p in CACHE_DIR.glob("track-*.json")
                  if "tempo" not in (d := json.loads(p.read_text()))
                  and d.get("source") == "itunes_preview")
    background.add_task(_backfill_tempo)
    return {"queued": missing}


def _backfill_artwork() -> None:
    """Fill missing artwork on saved analyses via iTunes search (rate-limited)."""
    for path in CACHE_DIR.glob("track-*.json"):
        data = json.loads(path.read_text())
        if data.get("artwork") or not data.get("title"):
            continue
        try:
            song = _itunes_lookup(None, data["title"], data.get("artist"))
        except Exception:
            continue
        if song and song.get("artworkUrl100"):
            data["artwork"] = song["artworkUrl100"]
            path.write_text(json.dumps(data))
        time.sleep(3)  # iTunes search rate limit (~20/min)


@app.post("/library/backfill_artwork")
def backfill_artwork(background: BackgroundTasks) -> dict:
    missing = sum(1 for p in CACHE_DIR.glob("track-*.json")
                  if not json.loads(p.read_text()).get("artwork"))
    background.add_task(_backfill_artwork)
    return {"queued": missing}


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
        segments = await anyio.to_thread.run_sync(_recognize_locked, tmp_path)
    except AudioDecodeError as exc:
        raise HTTPException(422, str(exc)) from exc
    finally:
        tmp_path.unlink(missing_ok=True)

    from .practice import score_take
    report = score_take(reference.get("chords", []),
                        [s.to_dict() for s in segments], offset)
    if "error" in report:
        raise HTTPException(422, report["error"])
    take_id = uuid.uuid4().hex[:12]
    entry = {"take_id": take_id, "track_id": track_id, "at": time.time(), **report}
    (CACHE_DIR / f"take-{take_id}.json").write_text(json.dumps(entry))
    return entry


@app.get("/practice/history/{track_id}")
def practice_history(track_id: str) -> dict:
    takes = []
    for path in CACHE_DIR.glob("take-*.json"):
        data = json.loads(path.read_text())
        if data.get("track_id") == track_id:
            takes.append(data)
    takes.sort(key=lambda t: t.get("at", 0), reverse=True)
    return {"takes": takes}


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
