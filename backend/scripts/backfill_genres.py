"""Fill in `genre` on charts published before genres were recorded.

    python scripts/backfill_genres.py [--force]

Charts already checked (genre present, or `genre_checked` set with no match)
are skipped unless --force. Network failures leave the chart untouched.
"""
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from chordlyze_backend.genre import lookup_genre  # noqa: E402
from chordlyze_backend.song_jobs import library_lock  # noqa: E402


def main() -> None:
    force = "--force" in sys.argv
    cache = Path(os.environ.get("CHORDLYZE_CACHE",
                                str(Path(__file__).resolve().parents[1] / "analysis_cache")))
    found = skipped = failed = unknown = 0
    for path in sorted(cache.glob("track-*.json")):
        data = json.loads(path.read_text())
        if not force and (data.get("genre") or data.get("genre_checked")):
            skipped += 1
            continue
        try:
            genre = lookup_genre(data.get("title"), data.get("artist"),
                                 data.get("song_duration") or data.get("audio_duration"), data.get("isrc"))
        except Exception as exc:  # noqa: BLE001 - report and move on
            failed += 1
            print(f"{path.name}: {exc}")
            continue
        with library_lock(cache):
            current = json.loads(path.read_text())
            current["genre_checked"] = True
            if genre:
                current["genre"] = genre
                found += 1
            else:
                current.pop("genre", None)
                unknown += 1
            tmp = path.with_suffix(".tmp")
            tmp.write_text(json.dumps(current, allow_nan=False))
            os.replace(tmp, path)
        time.sleep(0.25)  # iTunes rate limit is about 20 requests a minute
    print(f"genre found {found}, unknown {unknown}, skipped {skipped}, failed {failed}")


if __name__ == "__main__":
    main()
