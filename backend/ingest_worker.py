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
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
from pathlib import Path

from chordlyze_backend.analysis.beats import track_beats
from chordlyze_backend.fulltrack import fetch_full_track

BASE = "https://chordlyze-api.fly.dev"
ITUNES_SLEEP = 3  # iTunes search rate limit (~20/min)
ISMIR_DIR = Path(os.environ.get("CHORDLYZE_ISMIR_DIR", "~/.chordlyze/ismir2019")).expanduser()
ISMIR_MODEL = "ismir2019"


def ismir_available() -> bool:
    return (ISMIR_DIR / "chord_recognition.py").exists() and (ISMIR_DIR / ".venv/bin/python").exists()


def itunes_duration(title: str, artist: str | None) -> float | None:
    term = urllib.parse.quote(f"{title} {artist or ''}".strip())
    url = f"https://itunes.apple.com/search?term={term}&entity=song&limit=1"
    with urllib.request.urlopen(url, timeout=15) as resp:
        results = json.loads(resp.read()).get("results", [])
    ms = results[0].get("trackTimeMillis") if results else None
    return ms / 1000 if ms else None


def _post_json(path: str, payload: dict, timeout: int = 120) -> dict:
    req = urllib.request.Request(f"{BASE}{path}", data=json.dumps(payload).encode(),
                                 method="POST", headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


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
    """Run the ISMIR2019 model on `audio` (any ffmpeg-readable format)."""
    with tempfile.TemporaryDirectory() as tmp:
        wav = Path(tmp) / "audio.wav"
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(audio),
                        "-ac", "1", "-ar", "44100", str(wav)], check=True)
        lab = Path(tmp) / "chords.lab"
        proc = subprocess.run([str(ISMIR_DIR / ".venv/bin/python"), "chord_recognition.py",
                               str(wav), str(lab)], cwd=ISMIR_DIR, capture_output=True, text=True)
        if proc.returncode != 0:
            raise RuntimeError(f"ISMIR2019 failed: {proc.stderr.strip().splitlines()[-1]}")
        return parse_lab(lab.read_text())


def submit(audio: Path, item: dict) -> dict:
    """Recognize here and hand the server the chords, not the audio."""
    payload = {"track_id": item["track_id"], "model": ISMIR_MODEL, "source": "youtube",
               "title": item["title"], "artist": item.get("artist"),
               "artwork": item.get("artwork"), "isrc": item.get("isrc"),
               "segments": recognize_ismir(audio),
               "tempo": track_beats(audio)}
    return _post_json("/analysis/submit", payload)


def pending() -> list[dict]:
    """Library entries this worker can improve: previews first, then whole
    songs still charted by the maj/min recognizer."""
    with urllib.request.urlopen(f"{BASE}/library", timeout=30) as resp:
        library = json.loads(resp.read())["items"]
    previews, upgrades = [], []
    for entry in library:
        if not entry.get("title"):
            continue
        if entry.get("source") == "itunes_preview":
            previews.append(entry)
        elif entry.get("model", "madmom") != ISMIR_MODEL:
            upgrades.append(entry)
    return previews + upgrades


def run_once(items: list[dict] | None = None) -> int:
    if items is None:
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
                result = submit(audio, item)
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
    parser.add_argument("--manifest", type=Path,
                        help="JSON list of {track_id,title,artist,artwork,isrc} to ingest")
    args = parser.parse_args()
    if not ismir_available():
        sys.exit(f"ISMIR2019 model not installed under {ISMIR_DIR}; run scripts/setup_ismir.sh")
    if args.manifest:
        run_once(json.loads(args.manifest.read_text()))
        return
    while True:
        run_once()
        if not args.watch:
            break
        time.sleep(300)


if __name__ == "__main__":
    main()
