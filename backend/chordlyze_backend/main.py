"""Chordlyze backend API.

POST /song/request            — request or retrieve a complete song chart.
GET  /song/{id}               — song metadata, chart and processing status.
POST /analysis/submit         — authenticated, leased worker publication.
GET  /analysis/track/{id}     — saved analysis for a track (or its ISRC twin).
GET  /lyrics                  — time-synced lyrics from LRCLIB.
GET  /library                 — the caller's songs: requested, saved or practiced.
POST/DELETE /library/{id}     — save or remove one song from the caller's list.
PUT /library/{id}/chords      — correct or restore one personal chord occurrence.
GET  /catalog                 — every chart on the server (charts are global).
POST /practice_take           — score a practice recording against the chart.
GET  /health                  — liveness.

Every endpoint except /health and the worker's /internal routes needs the
caller's Spotify access token as a Bearer header; the backend verifies it
with Spotify (see auth.py). Charts are shared; song lists are per user.

Analyses are JSON files under CACHE_DIR: track-<id>.json, isrc-<ISRC>.json,
lyrics5-<digest>.json and leased job records.
"""
from __future__ import annotations

import hashlib
import json
import math
import logging
import hmac
import os
import re
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from contextlib import asynccontextmanager
from typing import Annotated, Literal

import anyio.to_thread
from fastapi import Depends, FastAPI, Form, Header, HTTPException, UploadFile, Request
from pydantic import BaseModel, Field

from .analysis.beats import track_beats, validate_tempo
from .analysis.rhythm import worker as rhythm_worker
from .analysis.difficulty import difficulty
from .analysis.chord import parse_label, parse_display
from . import corrections
from .synchronization import Sample as SyncSample, UncertainSync, align as align_samples
from .analysis.engine import AudioDecodeError, ChordSegment, merge_adjacent, recognize_audio
from .analysis.ismir import RecognitionUnavailable, close as close_recognizer
from .analysis.provenance import (ANALYSIS_VERSION, MODEL_QUALITIES, MODEL_RANK,
                                  MODEL_REVISIONS, is_current, quality)
from .analysis.keyfinder import analyze
from .auth import current_user
from .song_jobs import SongJobs, generation, library_lock
from .users import UserLibrary

CACHE_DIR = Path(os.environ.get("CHORDLYZE_CACHE",
                                str(Path(__file__).resolve().parent.parent / "analysis_cache")))
CACHE_DIR.mkdir(parents=True, exist_ok=True)

@asynccontextmanager
async def lifespan(_app):
    yield
    await anyio.to_thread.run_sync(close_recognizer)
    await anyio.to_thread.run_sync(rhythm_worker.close)


app = FastAPI(title="Chordlyze", version="0.5.1", lifespan=lifespan)
logger = logging.getLogger(__name__)


@app.get("/health")
def health() -> dict:
    return {"status": "ok", "api_version": app.version,
            "release": os.environ.get("CHORDLYZE_RELEASE", "development"),
            "analysis_version": ANALYSIS_VERSION, "library_generation": generation(CACHE_DIR),
            "song_worker_online": SongJobs(CACHE_DIR).worker_online()}




def _recognize_locked(path: Path):
    """Legacy preview recognizer (internally serialized) plus beat times."""
    result = recognize_audio(path, model="madmom")
    return result, track_beats(path)


# MARK: - Saved analyses

def _track_cache_path(track_id: str) -> Path:
    safe = "".join(c for c in track_id if c.isalnum())
    return CACHE_DIR / f"track-{safe}.json"


def _isrc_cache_path(isrc: str) -> Path:
    return CACHE_DIR / f"isrc-{isrc.upper()}.json"


# Recognizers by how much of the harmony they can name. Entries saved before
# the field existed are madmom's.
_MODEL_RANK = MODEL_RANK


_quality = quality


def _read_analysis(path: Path) -> dict:
    entry = json.loads(path.read_text())
    return {**entry, "analysis_stale": not is_current(entry)}


def _write_analysis(path: Path, entry: dict) -> None:
    """Readers see either complete revision, never a partially written file."""
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as tmp:
        pending = Path(tmp.name)
        try:
            json.dump(entry, tmp, allow_nan=False)
            tmp.flush()
            os.replace(pending, path)
        finally:
            pending.unlink(missing_ok=True)


def _save_track(track_id: str, result: dict, title: str | None, artist: str | None,
                isrc: str | None = None, artwork: str | None = None) -> bool:
    """Save under the track id (and its ISRC, when known). False when a better
    analysis is already stored: a preview never replaces a whole song, and a
    maj/min chart never replaces a large-vocabulary one."""
    with library_lock(CACHE_DIR):
        entry = dict(result)
        entry.pop("analysis_stale", None)
        entry["track_id"] = track_id
        for name, value in (("title", title), ("artist", artist), ("artwork", artwork), ("isrc", isrc)):
            if value:
                entry[name] = value
        track_path = _track_cache_path(track_id)
        if track_path.exists() and _quality(_read_analysis(track_path)) > _quality(entry):
            return False
        _write_analysis(track_path, entry)
        if isrc:
            path = _isrc_cache_path(isrc)
            if not path.exists() or _quality(_read_analysis(path)) <= _quality(entry):
                _write_analysis(path, entry)
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
    return _read_analysis(_track_cache_path(track_id))


# MARK: - iTunes preview analysis

# MARK: - Off-server submission

class SubmittedSegment(BaseModel):
    start: float = Field(ge=0, allow_inf_nan=False)
    end: float = Field(gt=0, allow_inf_nan=False)
    label: str


from .analysis.review import ChordReview, matching_review


class SubmittedAnalysis(BaseModel):
    """Chords recognized off-server (the ingest worker runs the
    large-vocabulary model on its own machine) for the server to key, score
    and store like any other analysis."""
    track_id: str
    model: str
    segments: list[SubmittedSegment]
    chord_review: list[ChordReview] | None = Field(default=None, max_length=20000)
    source: str = "youtube"
    title: str | None = None
    artist: str | None = None
    isrc: str | None = None
    artwork: str | None = None
    tempo: dict | None = None
    genre: str | None = Field(default=None, max_length=100)
    analysis_version: int = Field(default=0, ge=0, le=ANALYSIS_VERSION)
    model_revision: str | None = None
    audio_sha256: str | None = Field(default=None, pattern=r"^[0-9a-f]{64}$")
    audio_duration: float | None = Field(default=None, gt=0, allow_inf_nan=False)
    album: str | None = None
    song_duration: float | None = Field(default=None, gt=0, allow_inf_nan=False)
    audio_source: dict | None = None
    job_id: str | None = None
    lease: str | None = None
    library_generation: str | None = None


@app.post("/analysis/submit")
def submit_analysis(body: SubmittedAnalysis, authorization: str | None = Header(default=None)) -> dict:
    # Legacy direct submissions remain available in unconfigured development
    # environments. Production only accepts a current worker lease.
    if os.environ.get("CHORDLYZE_WORKER_TOKEN"):
        _worker_authorized(authorization)
        with library_lock(CACHE_DIR):
            return _submit_analysis(body, require_lease=True)
    return _submit_analysis(body)


def _submit_analysis(body: SubmittedAnalysis, require_lease: bool = False) -> dict:
    jobs = SongJobs(CACHE_DIR)
    if require_lease and not jobs.valid_lease(body.track_id, body.job_id or "", body.lease or "",
                                            body.library_generation or ""):
        raise HTTPException(409, "analysis job was reset, expired or replaced")
    if require_lease and jobs.get(body.track_id).get('kind', 'analysis') != 'analysis':
        raise HTTPException(409, "This job cannot publish a full-song chart.")
    if body.model not in _MODEL_RANK:
        raise HTTPException(422, f"unknown model {body.model!r}")
    if body.analysis_version == ANALYSIS_VERSION and (
            body.model_revision != MODEL_REVISIONS[body.model]
            or body.audio_sha256 is None or body.audio_duration is None):
        raise HTTPException(422, "current analyses require matching model revision, audio hash and duration")
    if not body.segments:
        raise HTTPException(422, "no segments")
    segments: list[ChordSegment] = []
    for seg in body.segments:
        if seg.end <= seg.start:
            raise HTTPException(422, f"empty segment at {seg.start}")
        if segments and seg.start < segments[-1].end - 1e-6:
            raise HTTPException(422, f"segments overlap or are unordered at {seg.start}")
        if body.audio_duration is not None and seg.end > body.audio_duration + 1e-6:
            raise HTTPException(422, "segment extends past the analyzed audio")
        try:
            chord = parse_label(seg.label)
        except ValueError as exc:
            raise HTTPException(422, str(exc)) from exc
        segments.append(ChordSegment(seg.start, seg.end, chord.label if chord else "N"))
    result = analyze(merge_adjacent(segments))
    if body.chord_review is not None:
        try:
            result['chord_review'] = matching_review([r.model_dump() for r in body.chord_review], result['chords'])
        except ValueError as error:
            raise HTTPException(422, str(error))
    try:
        result["tempo"] = validate_tempo(body.tempo, body.audio_duration or segments[-1].end)
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from exc
    if body.genre:
        result["genre"] = body.genre
    result["source"] = body.source
    result["model"] = body.model
    result.update(analysis_version=body.analysis_version, model_revision=body.model_revision,
                  audio_sha256=body.audio_sha256, audio_duration=body.audio_duration)
    result.update(album=body.album, song_duration=body.song_duration or body.audio_duration,
                  audio_source=body.audio_source, library_generation=generation(CACHE_DIR))
    if not _save_track(body.track_id, result, body.title, body.artist, body.isrc,
                       artwork=body.artwork):
        raise HTTPException(409, "a better analysis is already stored for this track")
    if require_lease:
        jobs.finish(body.track_id, body.job_id, body.lease, body.library_generation, "ready")
    return _read_analysis(_track_cache_path(body.track_id))


# MARK: - Complete song sheets and on-demand analysis

class SongRequest(BaseModel):
    track_id: str = Field(min_length=1, max_length=200)
    title: str = Field(min_length=1, max_length=500)
    artist: str = Field(default="", max_length=500)
    album: str | None = Field(default=None, max_length=500)
    duration: float | None = Field(default=None, gt=0, le=1200, allow_inf_nan=False)
    isrc: str | None = None
    artwork: str | None = None
    itunes_id: int | None = Field(default=None, gt=0)
    retry: bool = False


def _song_status(track_id: str, isrc: str | None = None, user: str | None = None) -> dict:
    jobs = SongJobs(CACHE_DIR)
    path = _track_cache_path(track_id)
    chart = _read_analysis(path) if path.exists() else _cached_by_isrc(track_id, isrc, None, None)
    # Version 3 adds optional rhythm metadata; version 2's identical chord
    # recognizer remains usable. Freshness must not erase a playable chart.
    ready = chart and chart.get("source") != "itunes_preview" and (
        is_current(chart, model="ismir2019") or (
            chart.get("analysis_version") == 2
            and chart.get("model") == "ismir2019"
            and chart.get("model_revision") == MODEL_REVISIONS["ismir2019"]))
    if ready:
        chart = {**chart, "difficulty": difficulty(chart.get("chords") or [])}
    job = jobs.get(track_id)
    song = job["song"] if job else None
    if ready:
        song = {"track_id": track_id, "title": chart.get("title"), "artist": chart.get("artist"),
                "album": chart.get("album"), "duration": chart.get("song_duration") or chart.get("audio_duration"),
                "isrc": chart.get("isrc"), "artwork": chart.get("artwork")}
    mine = UserLibrary(CACHE_DIR, user) if user else None
    if ready:
        chart = corrections.apply(chart, mine.corrections(track_id) if mine else None)
    return {"song": song, "analysis": chart if ready else None,
            "lyrics": chart.get("lyrics") if ready else None,
            "job": {"state": "ready", "worker_online": jobs.worker_online()} if ready else jobs.public(job),
            "library_generation": generation(CACHE_DIR),
            "saved": mine.contains(track_id) if mine else False,
            "timing": mine.timing(track_id) if mine else None,
            "timing_revision": _timing_revision(mine.timing(track_id) if mine else None)}


@app.post("/song/request")
def request_song(body: SongRequest, user: str = Depends(current_user)) -> dict:
    """Asking for a song puts it in the caller's library, ready or not."""
    with library_lock(CACHE_DIR):
        UserLibrary(CACHE_DIR, user).add(body.track_id)
        status = _song_status(body.track_id, body.isrc, user)
        if status["analysis"] is not None and not status["analysis"]["analysis_stale"]:
            return status
        # Only an explicit request upgrades a stale chart. Keep serving it
        # throughout the upgrade, including if a recording cannot be fetched.
        SongJobs(CACHE_DIR).request(body.model_dump(exclude={"retry"}),
                                   retry=body.retry or status["analysis"] is not None)
        return _song_status(body.track_id, user=user)


@app.get("/song/{track_id}")
def song_status(track_id: str, user: str = Depends(current_user)) -> dict:
    with library_lock(CACHE_DIR):
        return _song_status(track_id, user=user)


def _worker_authorized(authorization: str | None) -> None:
    token = os.environ.get("CHORDLYZE_WORKER_TOKEN")
    if not token:
        raise HTTPException(503, "song worker is not configured")
    if not isinstance(authorization, str) or not hmac.compare_digest(authorization, "Bearer " + token):
        raise HTTPException(401, "worker authorization required")


@app.post("/internal/jobs/claim")
def claim_song(authorization: str | None = Header(default=None)) -> dict:
    _worker_authorized(authorization)
    return {"job": SongJobs(CACHE_DIR).claim()}


class DownloadCandidate(BaseModel):
    id: str = Field(pattern=r'^[A-Za-z0-9_-]{11}$')
    title: str = Field(max_length=500)
    channel: str = Field(max_length=500)
    duration: float = Field(gt=0, le=1203, allow_inf_nan=False)


class DownloadCheckpoint(BaseModel):
    search_run_id: str | None = Field(default=None, pattern=r'^[A-Za-z0-9_-]{1,100}$')
    run_id: str | None = Field(default=None, pattern=r'^[A-Za-z0-9_-]{1,100}$')
    video_id: str | None = Field(default=None, pattern=r'^[A-Za-z0-9_-]{11}$')
    candidate: DownloadCandidate | None = None


class WorkerUpdate(BaseModel):
    track_id: str | None = None
    job_id: str | None = None
    lease: str | None = None
    library_generation: str | None = None
    stage: str | None = None
    state: str | None = None
    download_checkpoint: DownloadCheckpoint | None = None
    error_code: str | None = None
    message: str | None = Field(default=None, max_length=300)


@app.post("/internal/jobs/heartbeat")
def heartbeat_song(body: WorkerUpdate, authorization: str | None = Header(default=None)) -> dict:
    _worker_authorized(authorization)
    checkpoint = body.download_checkpoint.model_dump(exclude_none=True) if body.download_checkpoint else None
    if not SongJobs(CACHE_DIR).heartbeat(body.job_id, body.lease, body.stage, checkpoint):
        raise HTTPException(409, "job lease is no longer active")
    return {"ok": True}


@app.post("/internal/jobs/finish")
def finish_song(body: WorkerUpdate, authorization: str | None = Header(default=None)) -> dict:
    _worker_authorized(authorization)
    jobs = SongJobs(CACHE_DIR)
    current = jobs.get(body.track_id or "")
    # "queued" only hands a provider-limited job back to the queue; "ready" only
    # completes a lyrics job, since an analysis becomes ready by being published.
    allowed = {"failed", "unavailable"}
    if body.error_code == "provider_limit":
        allowed.add("queued")
    if current and current.get("kind") == "lyrics":
        allowed.add("ready")
    if body.state not in allowed:
        raise HTTPException(422, "invalid job result")
    message = ("A matching full recording could not be found. Try another edition of this song."
               if body.state == "unavailable" else "Could not finish analyzing this song. Retry to try again.")
    if body.state == "ready":
        message = body.message or "Lyrics timed."
    if body.error_code in ('provider_authentication', 'provider_configuration'):
        message = 'The recording service needs attention. Please try again later.'
    elif body.error_code == 'provider_limit':
        message = ('Waiting for the recording service; it has reached its usage limit.' if body.state == "queued"
                   else 'The recording service has reached its usage limit. Please try again later.')
    elif body.error_code == 'passage_recording_mismatch':
        message = 'The recording differs from the one used for this chart. No chords were changed.'
    elif body.error_code == 'provider_timeout':
        message = 'The recording download took too long. Retry this song.'
    if not jobs.finish(body.track_id or "", body.job_id or "", body.lease or "",
                                    body.library_generation or "", body.state, message):
        raise HTTPException(409, "job lease is no longer active")
    return {"ok": True}


class AlignedWord(BaseModel):
    time: float = Field(ge=0, allow_inf_nan=False)
    text: str = Field(min_length=1, max_length=200)
    # When the word stops sounding; absent for words the transcript did not hear.
    end: float | None = Field(default=None, ge=0, allow_inf_nan=False)


class AlignedLine(BaseModel):
    time: float = Field(ge=0, allow_inf_nan=False)
    text: str = Field(max_length=1000)
    words: list[AlignedWord] | None = Field(default=None, max_length=200)


class AlignedLyrics(BaseModel):
    track_id: str = Field(min_length=1, max_length=200)
    library_generation: str
    lines: list[AlignedLine] = Field(min_length=1, max_length=2000)
    aligner: str = Field(min_length=1, max_length=200)
    # catalog_aligned: catalog text timed to the recording; transcribed: the transcript itself.
    source: str = Field(default="catalog_aligned", pattern=r"^(catalog_aligned|transcribed)$")


@app.post("/internal/jobs/lyrics")
def attach_lyrics(body: AlignedLyrics, authorization: str | None = Header(default=None)) -> dict:
    """Word-timed lyrics the worker aligned to the analyzed recording. They
    belong to that chart: a reset or a replaced chart discards them."""
    _worker_authorized(authorization)
    times = [line.time for line in body.lines]
    if times != sorted(times):
        raise HTTPException(422, "lyric lines must be in time order")
    if not any(line.text for line in body.lines):
        raise HTTPException(422, "no lyric text")
    lines = [line.model_dump(exclude_none=True) for line in body.lines]
    with library_lock(CACHE_DIR):
        if body.library_generation != generation(CACHE_DIR):
            raise HTTPException(409, "library was reset")
        path = _track_cache_path(body.track_id)
        if not path.exists():
            raise HTTPException(404, "no chart for this track")
        entry = json.loads(path.read_text())
        if entry.get("source") == "itunes_preview" or not is_current(entry, model="ismir2019"):
            raise HTTPException(409, "lyrics can only be attached to a complete current chart")
        entry["lyrics"] = {"lines": lines, "synced": True,
                           "matched": "transcribed" if body.source == "transcribed" else "aligned",
                           "instrumental": False, "aligner": body.aligner}
        _write_analysis(path, entry)
        isrc = entry.get("isrc")
        if isrc:
            alias = _isrc_cache_path(isrc)
            if alias.exists() and json.loads(alias.read_text()).get("audio_sha256") == entry.get("audio_sha256"):
                _write_analysis(alias, entry)
    return {"ok": True, "lines": len(lines)}


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
        # A timestamp with no words marks a real instrumental break.
        line = {"time": int(m.group(1)) * 60 + float(m.group(2)), "text": clean}
        if words:
            line["words"] = words
        lines.append(line)
    by_time = {}
    for line in lines:
        old = by_time.get(line["time"])
        if old is None or line["text"]:
            by_time[line["time"]] = line
    return sorted(by_time.values(), key=lambda line: line["time"])


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


def user_or_worker(authorization: str | None = Header(default=None)) -> str:
    """The lyrics lookup serves both the app (Spotify token) and the worker
    (its own token), which asks it before timing a recording's lyrics."""
    token = os.environ.get("CHORDLYZE_WORKER_TOKEN")
    if token and isinstance(authorization, str) and hmac.compare_digest(authorization, "Bearer " + token):
        return "worker"
    return current_user(authorization)


@app.get("/lyrics")
def lyrics(title: str, artist: str = "", duration: float | None = None,
           album: str | None = None, user: str = Depends(user_or_worker)) -> dict:
    """Time-synced lyrics from LRCLIB, cached on disk. Duration/album narrow
    the match to the right version (not a cover/remix) when provided."""
    if duration is not None and (not math.isfinite(duration) or duration <= 0):
        raise HTTPException(422, "duration must be finite and positive")
    epoch = generation(CACHE_DIR)
    digest = hashlib.sha256(
        f"{title}|{artist}|{album or ''}|{round(duration) if duration else ''}"
        .lower().encode()).hexdigest()[:24]
    # v5: validate exact matches too; preserve instrumental timestamps.
    cached = CACHE_DIR / f"lyrics5-{digest}.json"
    with library_lock(CACHE_DIR):
        if cached.exists():
            return json.loads(cached.read_text())

    def save(result):
        with library_lock(CACHE_DIR):
            if generation(CACHE_DIR) == epoch:
                _write_analysis(cached, result)

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
    if data is not None and score_candidate(data, title, artist, duration) == 0:
        data = None
    if data is None:
        data = _lrclib_get(params)
        if data is not None and score_candidate(data, title, artist, duration) == 0:
            data = None
    if data is not None and data.get("instrumental"):
        result = {"duration": data.get("duration"), "lines": [], "synced": True,
                  "matched": matched, "instrumental": True}
        save(result)
        return result
    if data is None or not (data.get("syncedLyrics") or data.get("plainLyrics")):
        data = _search_lrclib(title, artist, duration)
        matched = "fuzzy"
    if data is None:
        raise HTTPException(404, "lyrics not found")

    synced = True
    lines = parse_synced_lyrics(data.get("syncedLyrics") or "")
    if not any(line["text"] for line in lines):
        lines = synthesize_lines(data.get("plainLyrics") or "",
                                 duration or data.get("duration"))
        synced = False
    if not any(line["text"] for line in lines):
        raise HTTPException(404, "no lyrics for this song")
    result = {"duration": data.get("duration"), "lines": lines,
              "synced": synced, "matched": matched, "instrumental": False}
    save(result)
    return result


# MARK: - Library

class ChordCorrection(BaseModel):
    chart_revision: str = Field(pattern=r"^[a-f0-9]{64}$")
    start: float = Field(ge=0, allow_inf_nan=False)
    end: float = Field(gt=0, allow_inf_nan=False)
    # Display spelling in the recording's original key; null restores analysis.
    name: str | None = Field(default=None, min_length=1, max_length=40)


def _editable_chart(track_id: str, user: str, expected: str):
    path = _track_cache_path(track_id)
    if not path.exists():
        raise HTTPException(404, "No chart to correct yet.")
    chart = _read_analysis(path)
    if chart.get("source") == "itunes_preview":
        raise HTTPException(409, "A full-song chart is required to correct chords.")
    mine = UserLibrary(CACHE_DIR, user)
    overlay = mine.corrections(track_id)
    current = corrections.apply(chart, overlay)
    if expected != current["chart_revision"]:
        raise HTTPException(409, "The chart changed. Reopen the chord and check it before saving again.")
    return mine, chart, overlay, current


def _correction_label(name: str) -> str:
    name = name.strip()
    try:
        parsed = parse_display(name)
        if (name != "N.C." and (parsed is None or parsed.intervals is None)) or name.endswith("/"):
            raise ValueError("unsupported chord")
        return parsed.label if parsed else "N"
    except (ValueError, IndexError):
        raise HTTPException(422, "Enter a chord such as C, F#m7, Bb/D or N.C.")


@app.put("/library/{track_id}/chords")
def correct_chord(track_id: str, body: ChordCorrection, user: str = Depends(current_user)) -> dict:
    with library_lock(CACHE_DIR):
        mine, chart, overlay, current = _editable_chart(track_id, user, body.chart_revision)
        segments = corrections.raw(current["chords"])
        index = next((i for i, s in enumerate(segments) if s["start"] == body.start and s["end"] == body.end), None)
        if index is None:
            raise HTTPException(409, "This chord's timing changed. Reopen the chord to edit it.")
        label = _correction_label(body.name) if body.name is not None else current["chords"][index].get("original_label", segments[index]["label"])
        segments[index]["label"] = label
        mine.set_corrections(track_id, corrections.commit(chart, current, overlay, segments))
        return _song_status(track_id, user=user)


class BoundaryEdit(BaseModel):
    chart_revision: str = Field(pattern=r"^[a-f0-9]{64}$")
    operation: Literal["move", "split", "merge", "undo", "restore"]
    start: float | None = Field(default=None, ge=0, allow_inf_nan=False)
    end: float | None = Field(default=None, gt=0, allow_inf_nan=False)
    at: float | None = Field(default=None, ge=0, allow_inf_nan=False)
    edge: Literal["start", "end"] = "end"
    name: str | None = Field(default=None, min_length=1, max_length=40)


@app.patch("/library/{track_id}/chords/boundary")
def edit_boundary(track_id: str, body: BoundaryEdit, user: str = Depends(current_user)) -> dict:
    with library_lock(CACHE_DIR):
        mine, chart, overlay, current = _editable_chart(track_id, user, body.chart_revision)
        if body.operation == "undo":
            if not current["can_undo"]:
                raise HTTPException(409, "There is no edit to undo on this chart.")
            history = overlay["history"]
            review_history = overlay.get("review_history", [None] * len(history))
            restored = {"base_revision": corrections.revision(chart), "segments": history[-1], "history": history[:-1],
                        "review_history": review_history[:-1]}
            if review_history and review_history[-1] is not None: restored["review"] = review_history[-1]
            mine.set_corrections(track_id, restored)
            return _song_status(track_id, user=user)
        segments = corrections.raw(current["chords"])
        if body.operation == "restore":
            segments = corrections.raw(chart["chords"])
        else:
            index = next((i for i, s in enumerate(segments) if s["start"] == body.start and s["end"] == body.end), None)
            if index is None:
                raise HTTPException(409, "This chord's timing changed. Reopen it before editing.")
            if body.operation == "split":
                segment = segments[index]
                if body.at is None or not segment["start"] + .1 <= body.at <= segment["end"] - .1 or body.name is None:
                    raise HTTPException(422, "Choose a split inside the chord, leaving at least 0.1 seconds on each side, and a second chord.")
                segments[index:index+1] = [{**segment, "end": body.at}, {"start": body.at, "end": segment["end"], "label": _correction_label(body.name)}]
            else:
                left_index = index - 1 if body.operation == "move" and body.edge == "start" else index
                if left_index < 0 or left_index + 1 >= len(segments):
                    raise HTTPException(422, "There is no neighboring chord at this boundary.")
                left, right = segments[left_index:left_index+2]
                if abs(left["end"] - right["start"]) > .000001:
                    raise HTTPException(422, "These chords have an unanalyzed gap between them.")
                if body.operation == "move":
                    if body.at is None or not left["start"] + .1 <= body.at <= right["end"] - .1:
                        raise HTTPException(422, "Leave at least 0.1 seconds for each neighboring chord.")
                    left["end"] = right["start"] = body.at
                else:
                    label = _correction_label(body.name) if body.name is not None else left["label"]
                    segments[left_index:left_index+2] = [{"start": left["start"], "end": right["end"], "label": label}]
        mine.set_corrections(track_id, corrections.commit(chart, current, overlay, segments))
        return _song_status(track_id, user=user)


@app.get("/library")
def library(user: str = Depends(current_user)) -> dict:
    """The caller's songs that have a chart, newest addition first."""
    with library_lock(CACHE_DIR):
        paths = [_track_cache_path(track) for track in UserLibrary(CACHE_DIR, user).track_ids()]
        return _library([path for path in paths if path.exists()], user=user)


@app.post("/library/{track_id}")
def save_song(track_id: str, user: str = Depends(current_user)) -> dict:
    """Keep a song whose chart already exists (analyzed by anyone)."""
    with library_lock(CACHE_DIR):
        if not _track_cache_path(track_id).exists() and SongJobs(CACHE_DIR).get(track_id) is None:
            raise HTTPException(404, "no chart or analysis request for this track")
        UserLibrary(CACHE_DIR, user).add(track_id)
        return {"track_id": track_id, "saved": True}


def _timing_revision(timing: dict | None) -> str:
    return hashlib.sha256(json.dumps(timing, sort_keys=True).encode()).hexdigest()


class TimingAnchor(BaseModel):
    chart: float = Field(ge=0, allow_inf_nan=False)
    spotify: float = Field(ge=0, allow_inf_nan=False)


class TimingCalibration(BaseModel):
    """spotifyTime = scale * chartTime + offset, fitted from listened anchors.
    The chart is identified by its audio hash and the Spotify recording by the
    id that actually played, so either changing marks the calibration stale."""
    offset: float = Field(ge=-30, le=30, allow_inf_nan=False)
    scale: float = Field(ge=0.9, le=1.1, allow_inf_nan=False)
    anchors: list[TimingAnchor] = Field(default_factory=list, max_length=8)
    verified_error: float | None = Field(default=None, ge=0, le=30, allow_inf_nan=False)
    chart_audio_sha256: str | None = Field(default=None, max_length=64)
    spotify_track_id: str | None = Field(default=None, max_length=200)
    chart_revision: str | None = Field(default=None, pattern=r"^[a-f0-9]{64}$")
    method: str | None = Field(default=None, pattern=r"^(automatic|manual)$")
    match_score: float | None = Field(default=None, ge=0, le=1, allow_inf_nan=False)
    match_margin: float | None = Field(default=None, ge=0, le=1, allow_inf_nan=False)
    drift_measured: bool | None = None


@app.put("/library/{track_id}/timing")
def set_timing(track_id: str, body: TimingCalibration, user: str = Depends(current_user)) -> dict:
    """Saves this account's calibration for the song; the song joins the library."""
    with library_lock(CACHE_DIR):
        if not _track_cache_path(track_id).exists():
            raise HTTPException(404, "no chart for this track")
        current = corrections.apply(_read_analysis(_track_cache_path(track_id)), UserLibrary(CACHE_DIR, user).corrections(track_id))
        if body.chart_revision is not None and current["chart_revision"] != body.chart_revision:
            raise HTTPException(409, "The chart changed. Synchronize again before saving timing.")
        UserLibrary(CACHE_DIR, user).set_timing(track_id, body.model_dump(exclude_none=True))
        return {"track_id": track_id, "timing": body.model_dump(exclude_none=True)}


@app.post("/library/{track_id}/synchronize")
async def synchronize_song(
    track_id: str, files: list[UploadFile], request: Request,
    positions: Annotated[str, Form(max_length=1000)],
    chart_revision: Annotated[str, Form(pattern=r"^[a-f0-9]{64}$")],
    timing_revision: Annotated[str, Form(pattern=r"^[a-f0-9]{64}$")],
    user: str = Depends(current_user),
) -> dict:
    try:
        starts = json.loads(positions)
        if not isinstance(starts, list) or len(starts) != 3 or any(
                isinstance(x, bool) or not isinstance(x, (int, float)) or not math.isfinite(x) or x < 0 for x in starts):
            raise ValueError()
    except (ValueError, TypeError):
        raise HTTPException(422, "Three valid playback positions are required.")
    if any(b - a < 8 for a, b in zip(sorted(starts), sorted(starts)[1:])):
        raise HTTPException(422, "Listen to three separated passages.")
    if len(files) != 3:
        raise HTTPException(422, "Three listening samples are required.")
    def read_current():
        path = _track_cache_path(track_id)
        if not path.exists():
            raise HTTPException(404, "No chart to synchronize yet.")
        mine = UserLibrary(CACHE_DIR, user)
        chart = corrections.apply(_read_analysis(path), mine.corrections(track_id))
        if chart["chart_revision"] != chart_revision or _timing_revision(mine.timing(track_id)) != timing_revision:
            raise HTTPException(409, "The chart or timing changed while listening. Your newer changes were kept; synchronize again.")
        if chart.get("source") == "itunes_preview":
            raise HTTPException(409, "A full-song chart is required to synchronize.")
        return mine, chart
    with library_lock(CACHE_DIR):
        _, reference = read_current()
    samples = []
    for upload, start in zip(files, starts):
        with tempfile.NamedTemporaryFile(suffix=Path(upload.filename or "sample.m4a").suffix, delete=False) as tmp:
            path = Path(tmp.name)
        try:
            size = 0
            with path.open("wb") as target:
                while chunk := await upload.read(1024 * 1024):
                    size += len(chunk)
                    if size > 8 * 1024 * 1024:
                        raise HTTPException(413, "Listening sample exceeds 8 MB.")
                    target.write(chunk)
            if size == 0:
                raise HTTPException(422, "The microphone sample is empty. Try again.")
            recognition = await anyio.to_thread.run_sync(lambda: recognize_audio(path, model="ismir2019", max_duration=30))
            samples.append(SyncSample(start, recognition.duration, [s.to_dict() for s in recognition.segments]))
        except AudioDecodeError as exc:
            raise HTTPException(422, str(exc)) from exc
        except RecognitionUnavailable as exc:
            raise HTTPException(503, "Synchronization is temporarily unavailable. Try again.") from exc
        finally:
            path.unlink(missing_ok=True)
            await upload.close()
    try:
        timing = await anyio.to_thread.run_sync(lambda: align_samples(reference["chords"], samples))
    except UncertainSync as exc:
        raise HTTPException(422, str(exc)) from exc
    timing.update(chart_audio_sha256=reference.get("audio_sha256"), spotify_track_id=track_id, chart_revision=chart_revision)
    if await request.is_disconnected():
        raise HTTPException(499, "Synchronization was canceled.")
    with library_lock(CACHE_DIR):
        mine, _ = read_current()
        mine.set_timing(track_id, timing)
        return _song_status(track_id, user=user)


@app.delete("/library/{track_id}/timing")
def clear_timing(track_id: str, user: str = Depends(current_user)) -> dict:
    with library_lock(CACHE_DIR):
        UserLibrary(CACHE_DIR, user).set_timing(track_id, None)
        return {"track_id": track_id, "timing": None}


@app.delete("/library/{track_id}")
def forget_song(track_id: str, user: str = Depends(current_user)) -> dict:
    """Removes the song from the caller's list; the chart stays for everyone."""
    with library_lock(CACHE_DIR):
        UserLibrary(CACHE_DIR, user).remove(track_id)
        return {"track_id": track_id, "saved": False}


@app.get("/catalog")
def catalog(user: str = Depends(current_user)) -> dict:
    """Every chart on the server, newest first. Charts carry no user data."""
    with library_lock(CACHE_DIR):
        return _library(sorted(CACHE_DIR.glob("track-*.json"),
                               key=lambda p: p.stat().st_mtime, reverse=True))


def _library(paths: list[Path], user: str | None = None) -> dict:
    items = []
    for path in paths:
        data = json.loads(path.read_text())
        if user:
            track_id = data.get("track_id", path.stem.removeprefix("track-"))
            data = corrections.apply(data, UserLibrary(CACHE_DIR, user).corrections(track_id))
        items.append({
            "track_id": data.get("track_id", path.stem.removeprefix("track-")),
            "title": data.get("title"),
            "artist": data.get("artist"),
            "key": data.get("key"),
            "artwork": data.get("artwork"),
            # Recomputed on read so the scale can change without re-analysis.
            "difficulty": difficulty(data.get("chords") or []),
            "genre": data.get("genre"),
            "tempo_bpm": (data.get("tempo") or {}).get("bpm"),
            "chord_count": len({c["label"] for c in data.get("chords") or [] if c.get("label") and c["label"] != "N"}),
            "source": data.get("source"),
            "model": data.get("model", "madmom"),
            "isrc": data.get("isrc"),
            "analysis_version": data.get("analysis_version", 0),
            "model_revision": data.get("model_revision"),
            "analysis_stale": not is_current(data),
            "album": data.get("album"),
            "duration": data.get("song_duration") or data.get("audio_duration"),
        })
    return {"items": items, "library_generation": generation(CACHE_DIR)}


@app.get("/analysis/track/{track_id}")
def get_track_analysis(track_id: str, isrc: str | None = None, user: str = Depends(current_user)) -> dict:
    with library_lock(CACHE_DIR):
        cached = _track_cache_path(track_id)
        if cached.exists():
            return corrections.apply(_read_analysis(cached), UserLibrary(CACHE_DIR, user).corrections(track_id))
        if hit := _cached_by_isrc(track_id, isrc, None, None):
            return corrections.apply(hit, UserLibrary(CACHE_DIR, user).corrections(track_id))
        raise HTTPException(404, "no analysis for this track yet")


# MARK: - Practice

@app.post("/practice_take")
async def practice_take(
    file: UploadFile,
    track_id: str = Form(...),
    offset: float = Form(default=0.0, allow_inf_nan=False),
    transpose: Annotated[int, Form(ge=-12, le=12)] = 0,
    playback_rate: Annotated[float, Form(ge=0.5, le=1, allow_inf_nan=False)] = 1.0,
    timing_scale: Annotated[float, Form(ge=0.9, le=1.1, allow_inf_nan=False)] = 1.0,
    chart_revision: Annotated[str | None, Form(pattern=r"^[a-f0-9]{64}$")] = None,
    user: str = Depends(current_user),
) -> dict:
    """Score a practice recording (instrument only, song in headphones)
    against the track's reference chart. A practiced song joins the
    caller's library."""
    ref_path = _track_cache_path(track_id)
    if not ref_path.exists():
        raise HTTPException(404, "no analysis for this track yet")
    with library_lock(CACHE_DIR):
        UserLibrary(CACHE_DIR, user).add(track_id)
        reference = corrections.apply(json.loads(ref_path.read_text()), UserLibrary(CACHE_DIR, user).corrections(track_id))
        if chart_revision is not None and chart_revision != reference["chart_revision"]:
            raise HTTPException(409, "The chart changed after this take started. Your audio is saved; start a new take with the current chords.")
    if reference.get("source") == "itunes_preview":
        raise HTTPException(409, "a full-song chart is required to score a recording")
    suffix = Path(file.filename or "take.m4a").suffix or ".m4a"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
        tmp_path = Path(tmp.name)
    try:
        size = 0
        with tmp_path.open("wb") as target:
            while chunk := await file.read(1024 * 1024):
                size += len(chunk)
                if size > 64 * 1024 * 1024:
                    raise HTTPException(413, "recording exceeds 64 MB")
                target.write(chunk)
        if size == 0:
            raise HTTPException(400, "empty upload")
        recognition = await anyio.to_thread.run_sync(
            lambda: recognize_audio(tmp_path, model="ismir2019", max_duration=600))
    except AudioDecodeError as exc:
        raise HTTPException(422, str(exc)) from exc
    except RecognitionUnavailable as exc:
        logger.warning("Practice recognition unavailable: %s", exc)
        raise HTTPException(503, "chord recognition is temporarily unavailable; please retry") from exc
    finally:
        tmp_path.unlink(missing_ok=True)

    from .practice import score_take
    comparison = "major_minor" if reference.get("model", "madmom") == "madmom" else "root_quality"
    try:
        report = score_take(reference.get("chords", []),
                            [s.to_dict() for s in recognition.segments], offset,
                            take_duration=recognition.duration, comparison=comparison,
                            supported_qualities=MODEL_QUALITIES[recognition.model],
                            transpose=transpose, playback_rate=playback_rate, timing_scale=timing_scale)
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from exc
    if "error" in report:
        raise HTTPException(422, report["error"])
    return {"take_id": uuid.uuid4().hex[:12], "track_id": track_id, **report,
            **recognition.metadata(), "reference_analysis_version": reference.get("analysis_version", 0),
            "reference_model_revision": reference.get("model_revision"),
            "reference_chart_revision": reference["chart_revision"]}


from .passages import router as passage_router
app.include_router(passage_router(lambda: CACHE_DIR, _editable_chart, _song_status, _worker_authorized))
