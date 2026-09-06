"""Per-user song lists. Charts are global, one per track, because a song's
chords are the same for everyone; which songs a person has analyzed, saved
or practiced is theirs alone.

Each user is one JSON file under CACHE_DIR/users, written atomically. Callers
hold the library lock.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import tempfile
import time
from pathlib import Path


class UserLibrary:
    def __init__(self, cache_dir: Path, user_id: str):
        if not user_id:
            raise ValueError("user id required")
        self.user_id = user_id
        safe = re.sub(r"[^A-Za-z0-9_-]", "_", user_id)[:64]
        digest = hashlib.sha256(user_id.encode()).hexdigest()[:10]
        self.path = cache_dir / "users" / f"{safe}-{digest}.json"

    def _read(self) -> dict:
        if not self.path.exists():
            return {"user_id": self.user_id, "songs": {}}
        return json.loads(self.path.read_text())

    def _write(self, data: dict) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(mode="w", dir=self.path.parent, delete=False) as tmp:
            pending = Path(tmp.name)
            try:
                json.dump(data, tmp)
                tmp.flush()
                os.replace(pending, self.path)
            finally:
                pending.unlink(missing_ok=True)

    def track_ids(self) -> list[str]:
        """Newest addition first."""
        songs = self._read()["songs"]
        return sorted(songs, key=lambda track: songs[track]["added_at"], reverse=True)

    def contains(self, track_id: str) -> bool:
        return track_id in self._read()["songs"]

    def add(self, track_id: str, now: float | None = None) -> bool:
        """True when the song was not there before."""
        data = self._read()
        if track_id in data["songs"]:
            return False
        data["songs"][track_id] = {"added_at": now if now is not None else time.time()}
        self._write(data)
        return True

    def remove(self, track_id: str) -> bool:
        data = self._read()
        if data["songs"].pop(track_id, None) is None:
            return False
        self._write(data)
        return True
