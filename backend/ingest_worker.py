"""Off-server full-song ingest.

YouTube refuses downloads from Fly's datacenter IPs, so this runs on a
machine with a residential connection: it asks the backend which library
songs are still analyzed from a 30 s preview, fetches the matching upload's
audio with yt-dlp, and uploads it to POST /analyze so the server stores a
whole-song analysis under the same track id.

    python ingest_worker.py            # one pass over pending songs
    python ingest_worker.py --watch    # repeat every 5 minutes
"""
from __future__ import annotations

import argparse
import sys
import time
import urllib.parse
import urllib.request
import json
import mimetypes
import uuid
from pathlib import Path

from chordlyze_backend.fulltrack import fetch_full_track

BASE = "https://chordlyze-api.fly.dev"
ITUNES_SLEEP = 3  # iTunes search rate limit (~20/min)


def itunes_duration(title: str, artist: str | None) -> float | None:
    term = urllib.parse.quote(f"{title} {artist or ''}".strip())
    url = f"https://itunes.apple.com/search?term={term}&entity=song&limit=1"
    with urllib.request.urlopen(url, timeout=15) as resp:
        results = json.loads(resp.read()).get("results", [])
    ms = results[0].get("trackTimeMillis") if results else None
    return ms / 1000 if ms else None


def upload(path: Path, track_id: str, title: str, artist: str | None) -> dict:
    boundary = f"chordlyze-{uuid.uuid4()}"
    body = bytearray()
    # No whisper alignment: synced lyrics already exist, and it overlapping
    # the next chord analysis has crashed the server.
    fields = {"track_id": track_id, "title": title, "align": "false"}
    if artist:
        fields["artist"] = artist
    for name, value in fields.items():
        body += f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n".encode()
    ctype = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
    body += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; "
             f"filename=\"{path.name}\"\r\nContent-Type: {ctype}\r\n\r\n").encode()
    body += path.read_bytes()
    body += f"\r\n--{boundary}--\r\n".encode()
    req = urllib.request.Request(f"{BASE}/analyze", data=bytes(body), method="POST",
                                 headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    with urllib.request.urlopen(req, timeout=900) as resp:
        return json.loads(resp.read())


def pending() -> list[dict]:
    """Library entries still analyzed from a 30 s iTunes preview."""
    with urllib.request.urlopen(f"{BASE}/library", timeout=30) as resp:
        library = json.loads(resp.read())["items"]
    items = []
    for entry in library:
        if not entry.get("title"):
            continue
        with urllib.request.urlopen(f"{BASE}/analysis/track/{entry['track_id']}", timeout=30) as resp:
            if json.loads(resp.read()).get("source") == "itunes_preview":
                items.append(entry)
    return items


def run_once() -> int:
    items = pending()
    print(f"{len(items)} pending", flush=True)
    done = 0
    for item in items:
        title, artist = item["title"], item.get("artist")
        try:
            duration = itunes_duration(title, artist)
            if not duration:
                print(f"skip {title!r}: no iTunes length", flush=True)
                continue
            audio = fetch_full_track(title, artist or "", duration)
            if audio is None:
                print(f"skip {title!r}: no upload within duration tolerance", flush=True)
                continue
            try:
                t0 = time.time()
                result = upload(audio, item["track_id"], title, artist)
            finally:
                audio.unlink(missing_ok=True)
            span = result["chords"][-1]["end"] if result.get("chords") else 0
            print(f"ok   {title!r}: {len(result.get('chords', []))} segments over {span:.0f}s "
                  f"in {time.time() - t0:.0f}s", flush=True)
            done += 1
        except Exception as exc:
            print(f"fail {title!r}: {exc}", file=sys.stderr, flush=True)
        finally:
            time.sleep(ITUNES_SLEEP)
    return done


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--watch", action="store_true", help="repeat every 5 minutes")
    args = parser.parse_args()
    while True:
        run_once()
        if not args.watch:
            break
        time.sleep(300)


if __name__ == "__main__":
    main()
