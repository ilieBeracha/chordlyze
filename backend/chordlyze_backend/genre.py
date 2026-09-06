"""Genre for a chart, from the iTunes catalog's primaryGenreName.

Charts carry no genre of their own: the recognizer hears chords, not styles.
iTunes is free, needs no key, and knows the same recordings the app searches.
An ISRC lookup is exact; otherwise the best title/artist/duration match is
used, with the same scoring as the app's song search.
"""
from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request

ITUNES = "https://itunes.apple.com"


def _fetch(url: str) -> list[dict]:
    with urllib.request.urlopen(url, timeout=15) as response:
        return json.load(response).get("results", [])


def lookup_genre(title: str | None, artist: str | None, duration: float | None,
                 isrc: str | None = None, fetch=_fetch) -> str | None:
    """None when iTunes has no confident match. Raises on network failure so
    callers can tell "unknown" from "could not ask"."""
    from .main import score_candidate

    candidates: list[dict] = []
    if isrc:
        candidates = fetch(f"{ITUNES}/lookup?isrc={urllib.parse.quote(isrc)}&entity=song")
        candidates = [c for c in candidates if c.get("kind") == "song" and c.get("primaryGenreName")]
        if len(candidates) == 1:
            return candidates[0]["primaryGenreName"]
    if not candidates and title:
        query = urllib.parse.urlencode({"term": f"{title} {artist or ''}".strip(), "entity": "song", "limit": 5})
        candidates = fetch(f"{ITUNES}/search?{query}")
    best: tuple[float, dict] | None = None
    for candidate in candidates:
        if not candidate.get("primaryGenreName"):
            continue
        comparable = {**candidate, "duration": (candidate.get("trackTimeMillis") or 0) / 1000}
        score = score_candidate(comparable, title or "", artist or "", duration)
        if score >= .75 and (best is None or score > best[0]):
            best = (score, candidate)
    return best[1]["primaryGenreName"] if best else None
