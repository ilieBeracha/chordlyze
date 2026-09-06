"""Fill in `genre` on charts published before genres were recorded.

    python scripts/backfill_genres.py [--force] [--from genres.json]

Charts already checked (genre present, or `genre_checked` set with no match)
are skipped unless --force. Network failures leave the chart untouched.
iTunes allows roughly 20 lookups a minute per address and answers 429 (or
403 for a while) past that, so lookups pause three seconds apart and back
off for a minute on a limit. `--from` applies a {track_id: genre} file made
elsewhere instead of asking iTunes from this machine.
"""
import json
import os
import sys
import time
import urllib.error
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from chordlyze_backend.genre import lookup_genre  # noqa: E402
from chordlyze_backend.song_jobs import library_lock  # noqa: E402


def _lookup_with_backoff(data: dict) -> str | None:
    for attempt in range(4):
        try:
            return lookup_genre(data.get("title"), data.get("artist"),
                                data.get("song_duration") or data.get("audio_duration"), data.get("isrc"))
        except urllib.error.HTTPError as exc:
            if exc.code not in (429, 403) or attempt == 3:
                raise
            print(f"iTunes limit ({exc.code}); waiting a minute", flush=True)
            time.sleep(60)
    raise RuntimeError("unreachable")


def main() -> None:
    force = "--force" in sys.argv
    prepared: dict[str, str | None] | None = None
    if "--from" in sys.argv:
        prepared = json.loads(Path(sys.argv[sys.argv.index("--from") + 1]).read_text())
    cache = Path(os.environ.get("CHORDLYZE_CACHE",
                                str(Path(__file__).resolve().parents[1] / "analysis_cache")))
    found = skipped = failed = unknown = 0
    for path in sorted(cache.glob("track-*.json")):
        data = json.loads(path.read_text())
        track_id = data.get("track_id", path.stem.removeprefix("track-"))
        if not force and (data.get("genre") or data.get("genre_checked")):
            skipped += 1
            continue
        if prepared is not None:
            if track_id not in prepared:
                skipped += 1
                continue
            genre = prepared[track_id]
        else:
            try:
                genre = _lookup_with_backoff(data)
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
        if prepared is None:
            time.sleep(3)  # stay under iTunes' limit of about 20 lookups a minute
    print(f"genre found {found}, unknown {unknown}, skipped {skipped}, failed {failed}")


if __name__ == "__main__":
    main()
