"""Off-server whole-song ingest.

YouTube refuses downloads from Fly's datacenter IPs, so this runs on a
machine with a residential connection: it asks the backend which library
songs still lack a whole-song, large-vocabulary analysis, fetches the
matching upload's audio with yt-dlp, recognizes the chords here with the
ISMIR2019 model (sevenths, sus, dim, aug, inversions; see
scripts/setup_ismir.sh) and POSTs the result to /analysis/submit.

    python ingest_worker.py                    # one pass over pending songs
    python ingest_worker.py --watch            # repeat every 5 minutes
    python ingest_worker.py --manifest f.json  # ingest the tracks listed in a
                                               # file [{track_id,title,artist,
                                               # artwork,isrc}] (cache rebuild)

Environment: CHORDLYZE_ISMIR_DIR (default ~/.chordlyze/ismir2019).
"""
from __future__ import annotations

import argparse
from collections import Counter
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor, as_completed
from email.utils import parsedate_to_datetime
import json
import os
import sys
import time
import threading
import urllib.parse
import urllib.error
import urllib.request
from pathlib import Path

from chordlyze_backend.analysis.beats import track_beats
from chordlyze_backend.analysis.engine import recognize_audio
from chordlyze_backend.analysis.ismir import ismir_available, model_directory
from chordlyze_backend.analysis.provenance import is_current
from chordlyze_backend.fulltrack import fetch_full_track

BASE = os.environ.get("CHORDLYZE_API_URL", "https://chordlyze-api.fly.dev").rstrip("/")
ITUNES_SLEEP = 3  # iTunes search rate limit (~20/min)
ISMIR_DIR = model_directory()
ISMIR_MODEL = "ismir2019"


def itunes_duration(title: str, artist: str | None) -> float | None:
    term = urllib.parse.quote(f"{title} {artist or ''}".strip())
    url = f"https://itunes.apple.com/search?term={term}&entity=song&limit=1"
    results = _read_json(url, timeout=15, before_attempt=_LOOKUP_THROTTLE.wait).get("results", [])
    ms = results[0].get("trackTimeMillis") if results else None
    return ms / 1000 if ms else None


def _post_json(path: str, payload: dict, timeout: int = 120) -> dict:
    req = urllib.request.Request(f"{BASE}{path}", data=json.dumps(payload).encode(),
                                 method="POST", headers={"Content-Type": "application/json"})
    # Submitting the same track/revision/audio payload is an idempotent cache
    # replacement, so a lost response can be retried without duplicate charts.
    return _read_json(req, timeout=timeout)


def _read_json(request, *, timeout: int, before_attempt: Callable[[], None] | None = None) -> dict:
    for attempt in range(3):
        if before_attempt:
            before_attempt()
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return json.loads(response.read())
        except urllib.error.HTTPError as exc:
            if attempt == 2 or exc.code not in {408, 429, 500, 502, 503, 504}:
                raise
            delay = float(2 ** (attempt + 1))
            retry_after = (exc.headers or {}).get("Retry-After")
            if retry_after:
                try:
                    requested = float(retry_after)
                except ValueError:
                    try:
                        requested = parsedate_to_datetime(retry_after).timestamp() - time.time()
                    except (TypeError, ValueError, OverflowError):
                        requested = 0
                if requested > 30:
                    raise  # Leave this entry pending instead of retrying too early.
                delay = max(delay, requested)
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            if attempt == 2:
                raise
            delay = float(2 ** (attempt + 1))
        time.sleep(delay)
    raise RuntimeError("request retries exhausted")


def parse_lab(text: str) -> list[dict]:
    """'start\\tend\\tlabel' lines (the model's .lab output) -> segments."""
    segments = []
    for line in text.splitlines():
        parts = line.split()
        if len(parts) != 3:
            continue
        start, end, label = float(parts[0]), float(parts[1]), parts[2]
        if end > start:
            segments.append({"start": round(start, 3), "end": round(end, 3), "label": label})
    return segments


def recognize_ismir(audio: Path) -> list[dict]:
    """Compatibility entry point; API and ingest now share one implementation."""
    return [s.to_dict() for s in recognize_audio(audio, model=ISMIR_MODEL).segments]


def submit(audio: Path, item: dict) -> dict:
    """Recognize here and hand the server the chords, not the audio."""
    recognition = recognize_audio(audio, model=ISMIR_MODEL)
    payload = {"track_id": item["track_id"], **recognition.metadata(), "source": "youtube",
               "title": item["title"], "artist": item.get("artist"),
               "artwork": item.get("artwork"), "isrc": item.get("isrc"),
               "segments": [s.to_dict() for s in recognition.segments],
               "tempo": track_beats(audio)}
    return _post_json("/analysis/submit", payload)


def pending() -> list[dict]:
    """Previews first, then outdated models or analysis revisions."""
    library = _read_json(f"{BASE}/library", timeout=30)["items"]
    previews, upgrades = [], []
    for entry in library:
        if not entry.get("title"):
            continue
        if entry.get("source") == "itunes_preview":
            previews.append(entry)
        elif not is_current(entry, model=ISMIR_MODEL):
            upgrades.append(entry)
    return previews + upgrades


class LookupThrottle:
    """One iTunes request every three seconds, shared by all download workers."""
    def __init__(self, interval: float = ITUNES_SLEEP):
        self.interval = interval
        self.lock = threading.Lock()
        self.next_request = 0.0

    def wait(self) -> None:
        with self.lock:
            delay = max(0.0, self.next_request - time.monotonic())
            if delay:
                time.sleep(delay)
            self.next_request = time.monotonic() + self.interval


_LOOKUP_THROTTLE = LookupThrottle()


def run_once(items: list[dict] | None = None, *, jobs: int = 3) -> int:
    """Overlap bounded downloads; the shared recognizer serializes inference."""
    if not 1 <= jobs <= 4:
        raise ValueError("jobs must be between 1 and 4")
    if items is None:
        items = pending()
    print(f"{len(items)} pending", flush=True)

    def process(item: dict) -> str:
        title, artist = item["title"], item.get("artist")
        try:
            duration = itunes_duration(title, artist)
            if not duration:
                print(f"skip {title!r}: no iTunes length", flush=True)
                return "skipped"
            audio = fetch_full_track(title, artist or "", duration)
            if audio is None:
                print(f"skip {title!r}: no upload within duration tolerance", flush=True)
                return "skipped"
            try:
                t0 = time.time()
                result = submit(audio, item)
            finally:
                audio.unlink(missing_ok=True)
            span = result["chords"][-1]["end"] if result.get("chords") else 0
            print(f"ok   {title!r}: {len(result.get('chords', []))} segments over {span:.0f}s "
                  f"in {time.time() - t0:.0f}s", flush=True)
            return "updated"
        except Exception as exc:
            print(f"fail {title!r}: {exc}", file=sys.stderr, flush=True)
            return "failed"

    counts: Counter = Counter()
    pool = ThreadPoolExecutor(max_workers=jobs, thread_name_prefix="ingest")
    futures = [pool.submit(process, item) for item in items]
    try:
        for future in as_completed(futures):
            counts[future.result()] += 1
    finally:
        # On interruption, finish only running items; a new invocation queries
        # the server and automatically excludes successfully upgraded entries.
        pool.shutdown(wait=True, cancel_futures=True)
    print(f"Refresh finished: {counts['updated']} updated, {counts['skipped']} skipped, "
          f"{counts['failed']} failed, {len(items)} total", flush=True)
    return counts["updated"]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--watch", action="store_true", help="repeat every 5 minutes")
    parser.add_argument("--manifest", type=Path,
                        help="JSON list of {track_id,title,artist,artwork,isrc} to ingest")
    parser.add_argument("--jobs", type=int, choices=range(1, 5), default=3,
                        help="bounded concurrent downloads (default 3); model inference stays serialized")
    args = parser.parse_args()
    if not ismir_available():
        sys.exit(f"ISMIR2019 model not installed under {ISMIR_DIR}; run scripts/setup_ismir.sh")
    if args.manifest:
        run_once(json.loads(args.manifest.read_text()), jobs=args.jobs)
        return
    while True:
        run_once(jobs=args.jobs)
        if not args.watch:
            break
        time.sleep(300)


if __name__ == "__main__":
    main()
