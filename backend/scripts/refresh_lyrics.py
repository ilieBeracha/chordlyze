"""Queue lyric-timing jobs for charts whose lyrics are not word-timed.

    python scripts/refresh_lyrics.py [--limit N] [--dry-run] [--retry-unaligned] [--realign] [--retime-all]

Charts analyzed before the worker transcribed recordings have only catalog
line times, or no timed lyrics at all. Each job re-fetches the recording
(every download is billed by the provider) and runs the same alignment new
charts get; the chart itself is untouched. Jobs queue behind analysis
requests and run at the worker's usual pace.

--retime-all queues every chart with word-timed lyrics, aligned or
transcribed, for when the stored word data itself changes (word end times).
--realign also queues charts whose lyrics are already catalog-aligned, for
use after the word matcher changes; transcribed and instrumental charts are
left alone since the matcher plays no part in them.

A chart whose last lyrics job ran but could not match the words is skipped:
the same transcription model gives the same answer, and the download would
be paid again for nothing. --retry-unaligned includes them, for use after
the transcription model changes.
"""
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from chordlyze_backend.song_jobs import SongJobs  # noqa: E402


def needs_timing(chart: dict, realign: bool = False, retime_all: bool = False) -> bool:
    lyrics = chart.get("lyrics")
    if not lyrics:
        return True
    if lyrics.get("instrumental"):
        return False
    if retime_all and lyrics.get("matched") in ("aligned", "transcribed"):
        return True
    if realign and lyrics.get("matched") == "aligned":
        return True
    return not any(line.get("words") for line in lyrics.get("lines", []))


def main() -> None:
    args = sys.argv[1:]
    limit = int(args[args.index("--limit") + 1]) if "--limit" in args else None
    dry = "--dry-run" in args
    retry_unaligned = "--retry-unaligned" in args
    realign = "--realign" in args
    retime_all = "--retime-all" in args
    cache = Path(os.environ.get("CHORDLYZE_CACHE",
                                str(Path(__file__).resolve().parents[1] / "analysis_cache")))
    jobs = SongJobs(cache)
    queued = skipped = 0
    for path in sorted(cache.glob("track-*.json"), key=lambda p: p.stat().st_mtime, reverse=True):
        chart = json.loads(path.read_text())
        if chart.get("source") == "itunes_preview" or not needs_timing(chart, realign, retime_all):
            skipped += 1
            continue
        track_id = chart.get("track_id", path.stem.removeprefix("track-"))
        last = jobs.get(track_id)
        if last and last.get("kind") == "lyrics" and last.get("state") in ("queued", "processing"):
            skipped += 1
            continue
        if (not retry_unaligned and last and last.get("kind") == "lyrics" and last.get("state") == "ready"
                and "unaligned" in (last.get("message") or "")):
            skipped += 1
            continue
        if limit is not None and queued >= limit:
            break
        song = {"track_id": track_id, "title": chart.get("title"),
                "artist": chart.get("artist"), "album": chart.get("album"), "isrc": chart.get("isrc"),
                "artwork": chart.get("artwork"),
                "duration": chart.get("song_duration") or chart.get("audio_duration")}
        if not song["title"] or not song["duration"]:
            skipped += 1
            continue
        if not dry:
            jobs.request(song, kind="lyrics")
        queued += 1
    print(f"{'would queue' if dry else 'queued'} {queued}, skipped {skipped}")


if __name__ == "__main__":
    main()
