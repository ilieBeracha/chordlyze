"""Who is calling: the app sends its Spotify access token, and the backend
asks Spotify whose it is. Nothing here trusts a user id the client claims.

Verified ids are cached per token for a few minutes, so the app's polling
does not turn into a Spotify request per poll. Tokens are stored only as a
digest.
"""
from __future__ import annotations

import hashlib
import json
import os
import time
import urllib.error
import urllib.request

from fastapi import Header, HTTPException

SPOTIFY_ME_URL = os.environ.get("CHORDLYZE_SPOTIFY_ME_URL", "https://api.spotify.com/v1/me")
CACHE_TTL = 600.0
_cache: dict[str, tuple[str, float]] = {}


def lookup(token: str) -> str:
    """Spotify user id for an access token. 401 when Spotify rejects it,
    503 when Spotify cannot be reached."""
    request = urllib.request.Request(SPOTIFY_ME_URL, headers={"Authorization": "Bearer " + token})
    try:
        with urllib.request.urlopen(request, timeout=8) as response:
            data = json.load(response)
    except urllib.error.HTTPError as exc:
        if exc.code in (401, 403):
            raise HTTPException(401, "the Spotify session is no longer valid; sign in again") from exc
        raise HTTPException(503, f"Spotify could not verify the session ({exc.code})") from exc
    except (OSError, ValueError) as exc:
        raise HTTPException(503, "Spotify could not be reached to verify the session") from exc
    user_id = data.get("id") if isinstance(data, dict) else None
    if not isinstance(user_id, str) or not user_id:
        raise HTTPException(401, "Spotify did not identify the session")
    return user_id


def current_user(authorization: str | None = Header(default=None)) -> str:
    """FastAPI dependency: the verified Spotify user id of the caller."""
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "sign in with Spotify to use Chordlyze")
    token = authorization[len("Bearer "):].strip()
    if not token:
        raise HTTPException(401, "sign in with Spotify to use Chordlyze")
    digest = hashlib.sha256(token.encode()).hexdigest()
    now = time.monotonic()
    cached = _cache.get(digest)
    if cached and cached[1] > now:
        return cached[0]
    user_id = lookup(token)
    if len(_cache) >= 2000:
        for key in [k for k, (_, expires) in _cache.items() if expires <= now]:
            del _cache[key]
    _cache[digest] = (user_id, now + CACHE_TTL)
    return user_id


def forget_all() -> None:
    _cache.clear()
