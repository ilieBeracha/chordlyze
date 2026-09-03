"""Full-song audio for whole-track chord analysis.

The iTunes preview is a 30 s slice at an unknown offset, so chords from it
can't be placed on the song timeline. A YouTube upload whose length matches
the track gives the whole song from 0:00. Matching is by duration (the
album version is the same length everywhere) with a title filter against
live/cover/remix variants.
"""
from __future__ import annotations

import re
import tempfile
from pathlib import Path

_VARIANT = re.compile(
    r"\b(live|session|cover|remix|karaoke|instrumental|acoustic|reaction|tutorial|"
    r"lesson|slowed|sped up|nightcore|8d|extended|edit)\b", re.I)


def pick_candidate(entries: list[dict], title: str, artist: str, duration: float) -> dict | None:
    """Best search result for `title` lasting `duration` seconds, or None.
    Tolerance ±2 % (at least 3 s); variant words in a result title disqualify
    it unless the requested title carries the same word."""
    tol = max(3.0, duration * 0.02)

    def usable(e: dict) -> bool:
        d = e.get("duration")
        if not d or abs(d - duration) > tol:
            return False
        hit = _VARIANT.search(e.get("title") or "")
        return not hit or bool(re.search(rf"\b{re.escape(hit.group(0))}\b", title, re.I))

    good = [e for e in entries if usable(e)]
    if not good:
        return None

    def score(e: dict) -> float:
        channel = (e.get("channel") or e.get("uploader") or "").lower()
        name = (e.get("title") or "").lower()
        s = 0.0
        if channel.endswith(" - topic"):
            s += 3          # auto-generated album audio: exact studio version
        if artist and artist.lower() in channel:
            s += 2
        if title.lower() in name:
            s += 1
        s -= abs((e.get("duration") or 0) - duration) / tol
        return s

    return max(good, key=score)


def fetch_full_track(title: str, artist: str, duration: float) -> Path | None:
    """Download the matching upload's audio to a temp file; None when no
    result matches. Raises yt_dlp.utils.DownloadError when YouTube refuses."""
    import yt_dlp

    search = {"quiet": True, "no_warnings": True, "extract_flat": "in_playlist",
              "skip_download": True, "socket_timeout": 20}
    with yt_dlp.YoutubeDL(search) as ydl:
        info = ydl.extract_info(f"ytsearch6:{artist} {title}".strip(), download=False)
    chosen = pick_candidate(info.get("entries") or [], title, artist, duration)
    if chosen is None:
        return None

    outtmpl = str(Path(tempfile.gettempdir()) / "chordlyze-yt-%(id)s.%(ext)s")
    download = {"quiet": True, "no_warnings": True, "format": "bestaudio/best",
                "noplaylist": True, "socket_timeout": 20, "outtmpl": outtmpl}
    with yt_dlp.YoutubeDL(download) as ydl:
        result = ydl.extract_info(f"https://www.youtube.com/watch?v={chosen['id']}", download=True)
        return Path(ydl.prepare_filename(result))
