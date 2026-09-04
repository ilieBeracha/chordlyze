#!/usr/bin/env python3
"""Compare the production Swift drill detector with its frozen baseline on GuitarSet.

macOS + Xcode command line tools are required (Accelerate and AVFoundation).
Uses the official microphone archive, performed-chord annotations, all comp takes
from players 00/01 for development and 04/05 for an untouched final evaluation.
Data stays outside the repository. See docs/live-drill-detection.md.
"""
from __future__ import annotations

import argparse
import bisect
import collections
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
RECORD = "https://zenodo.org/records/3371780"
ARCHIVES = {"annotation.zip": "b39b78e63d3446f2e54ddb7a54df9b10",
            "audio_mono-mic.zip": "275966d6610ac34999b58426beb119c3"}
NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
# Same chord vocabulary and bass-flexible policy as Chord.swift.
QUALITIES = {
    "maj": ("", [0, 4, 7]), "min": ("m", [0, 3, 7]),
    "dim": ("°", [0, 3, 6]), "aug": ("+", [0, 4, 8]),
    "sus2": ("sus2", [0, 2, 7]), "sus4": ("sus4", [0, 5, 7]),
    "7": ("7", [0, 4, 7, 10]), "maj7": ("maj7", [0, 4, 7, 11]),
    "min7": ("m7", [0, 3, 7, 10]), "minmaj7": ("mMaj7", [0, 3, 7, 11]),
    "dim7": ("°7", [0, 3, 6, 9]), "hdim7": ("ø7", [0, 3, 6, 10]),
    "maj6": ("6", [0, 4, 7, 9]), "min6": ("m6", [0, 3, 7, 9]),
    "9": ("9", [0, 4, 7, 10, 14]), "maj9": ("maj9", [0, 4, 7, 11, 14]),
    "min9": ("m9", [0, 3, 7, 10, 14]), "11": ("11", [0, 4, 7, 10, 14, 17]),
    "13": ("13", [0, 4, 7, 10, 14, 21]), "sus4(b7)": ("7sus4", [0, 5, 7, 10]),
}
SPLITS = {"dev": {"00", "01"}, "holdout": {"04", "05"}}


def degree(text: str) -> int:
    match = re.fullmatch(r"([b#]*)(1|2|3|4|5|6|7|9|11|13)", text)
    if not match:
        raise ValueError(f"Unsupported Harte degree: {text}")
    bases = {1: 0, 2: 2, 3: 4, 4: 5, 5: 7, 6: 9, 7: 11, 9: 14, 11: 17, 13: 21}
    return (bases[int(match[2])] + match[1].count("#") - match[1].count("b")) % 12


def pitch_set(label: str) -> frozenset[int] | None:
    """Keep added and omitted degrees; never collapse an unknown quality to major."""
    if label == "N":
        return frozenset()
    match = re.fullmatch(r"([A-G])([b#]*)(?::([^/]+))?(?:/[^/]+)?", label)
    if not match:
        return None
    root = ({"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}[match[1]]
            + match[2].count("#") - match[2].count("b")) % 12
    quality = match[3] or "maj"
    if quality in QUALITIES:
        intervals = set(QUALITIES[quality][1])
    else:
        modified = re.fullmatch(r"([^()]*)\(([^()]*)\)", quality)
        if not modified or (modified[1] and modified[1] not in QUALITIES):
            return None
        intervals = {i % 12 for i in QUALITIES[modified[1]][1]} if modified[1] else set()
        try:
            for token in modified[2].split(","):
                if token.startswith("*"):
                    intervals.discard(degree(token[1:]))
                else:
                    intervals.add(degree(token))
        except ValueError:
            return None
    return frozenset((root + i) % 12 for i in intervals)


def vocabulary() -> dict[frozenset[int], tuple[str, frozenset[int]]]:
    result = {}
    for root, name in enumerate(NAMES):
        for quality, (suffix, intervals) in QUALITIES.items():
            notes = frozenset((root + i) % 12 for i in intervals)
            required = notes - {(root + 7) % 12} if len(notes) >= 4 else notes
            result.setdefault(notes, (name + suffix, required))
    return result


def input_digest(dataset: Path, items: list[dict], excluded: list[dict]) -> str:
    """Fingerprint the actual inputs, including annotations of excluded takes."""
    digest = hashlib.sha256()
    paths = [dataset / "annotation" / f"{row['id']}.jams" for row in items + excluded]
    paths += [Path(item["path"]) for item in items]
    for path in sorted(paths, key=lambda p: p.name):
        digest.update(path.name.encode())
        with path.open("rb") as source:
            digest.update(hashlib.file_digest(source, "sha256").digest())
    return digest.hexdigest()


def fetch(dataset: Path) -> None:
    dataset.mkdir(parents=True, exist_ok=True)
    for filename, expected in ARCHIVES.items():
        archive = dataset / filename
        if not archive.exists():
            temporary = archive.with_suffix(".download")
            print(f"Downloading {filename} from GuitarSet's official Zenodo record", flush=True)
            with urllib.request.urlopen(f"{RECORD}/files/{filename}", timeout=120) as response, temporary.open("wb") as out:
                while chunk := response.read(1024 * 1024):
                    out.write(chunk)
            temporary.replace(archive)
        with archive.open("rb") as source:
            actual = hashlib.file_digest(source, "md5").hexdigest()
        if actual != expected:
            raise ValueError(f"Checksum mismatch for {archive}; refusing to extract")
        destination = dataset / filename.removesuffix(".zip")
        if not destination.exists():
            with zipfile.ZipFile(archive) as bundle:
                for member in bundle.namelist():
                    if not (destination / member).resolve().is_relative_to(destination.resolve()):
                        raise ValueError("Unsafe archive path")
                bundle.extractall(destination)


def manifest(dataset: Path, split: str) -> tuple[list[dict], list[dict]]:
    vocab = vocabulary()
    items, excluded = [], []
    players = SPLITS[split] if split != "all" else set.union(*SPLITS.values())
    files = sorted(p for p in (dataset / "annotation").glob("*_comp.jams") if p.name[:2] in players)
    if len(files) != 30 * len(players):
        raise ValueError(f"Expected {30 * len(players)} comp annotations, found {len(files)}")
    for file in files:
        jam = json.loads(file.read_text())
        chords = [a for a in jam["annotations"] if a["namespace"] == "chord"]
        if len(chords) != 2:
            raise ValueError(f"Expected instructed and performed chords: {file.name}")
        reference = chords[-1]["data"]
        durations = collections.Counter()
        for segment in reference:
            notes = pitch_set(segment["value"])
            if notes in vocab:
                durations[notes] += segment["duration"]
        chosen = sorted(durations, key=lambda notes: (-durations[notes], vocab[notes][0]))[:2]
        if len(chosen) < 2:
            excluded.append({"id": file.stem, "reason": "fewer than two distinct supported pitch sets"})
            continue
        audio = dataset / "audio_mono-mic" / f"{file.stem}_mic.wav"
        if not audio.exists():
            raise FileNotFoundError(audio)
        a, b = [vocab[notes][0] for notes in chosen]
        items.append({"id": file.stem, "path": str(audio.resolve()), "targetA": a, "targetB": b,
                      "split": "dev" if file.name[:2] in SPLITS["dev"] else "holdout",
                      "reference": reference, "duration": jam["file_metadata"]["duration"],
                      "target_sets": [sorted(notes) for notes in chosen],
                      "required_sets": [sorted(vocab[notes][1]) for notes in chosen]})
    return items, excluded


def expected_target(item: dict, segment: dict) -> str | None:
    notes = pitch_set(segment["value"])
    for name, full, required in zip([item["targetA"], item["targetB"]], item["target_sets"], item["required_sets"]):
        if notes == frozenset(full) or notes == frozenset(required):
            return name
    return None


def score(item: dict, result: dict, *, interior: bool) -> collections.Counter:
    counts = collections.Counter()
    frames = result["frames"]
    times = [f["time"] for f in frames]
    for segment in item["reference"]:
        start = segment["time"] + (0.6 if interior else 0)
        end = min(item["duration"], segment["time"] + segment["duration"] - (0.15 if interior else 0))
        if end <= start:
            continue
        if pitch_set(segment["value"]) is None:
            counts["unscored_seconds"] += end - start
            continue
        expected = expected_target(item, segment)
        # Integrate piecewise-constant UI state exactly; hop-size differences
        # must not change frame weighting or create an artificial accuracy gain.
        cuts = [start] + [t for t in times if start < t < end] + [end]
        hit = False
        for left, right in zip(cuts, cuts[1:]):
            index = bisect.bisect_right(times, (left + right) / 2) - 1
            accepted = frames[index]["accepted"] if index >= 0 else None
            duration = right - left
            counts["scored_seconds"] += duration
            if expected:
                counts["target_seconds"] += duration
            else:
                counts["non_target_seconds"] += duration
            if accepted:
                counts["accepted_seconds"] += duration
                if accepted == expected:
                    counts["correct_seconds"] += duration
                    hit = True
                else:
                    counts["incorrect_seconds"] += duration
                    if not expected:
                        counts["false_accept_non_target_seconds"] += duration
        if expected:
            counts["target_segments"] += 1
            counts["recognized_segments"] += hit
    return counts


def metrics(counts: collections.Counter) -> dict:
    def ratio(a: str, b: str):
        return round(counts[a] / counts[b], 6) if counts[b] else None
    return {**{k: round(v, 6) for k, v in sorted(counts.items())},
            "accepted_precision": ratio("correct_seconds", "accepted_seconds"),
            "target_time_coverage": ratio("correct_seconds", "target_seconds"),
            "target_segment_recall": ratio("recognized_segments", "target_segments"),
            "non_target_false_accept_rate": ratio("false_accept_non_target_seconds", "non_target_seconds")}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", type=Path, required=True)
    parser.add_argument("--split", choices=["dev", "holdout", "all"], default="dev")
    parser.add_argument("--download", action="store_true")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if args.download:
        fetch(args.dataset)
    items, excluded = manifest(args.dataset, args.split)
    sources = [ROOT / path for path in ["Chordlyze/Chord.swift", "Chordlyze/ChordDrillDetector.swift",
                                        "tests/support/LegacyDrillDetector.swift", "tests/DrillDetectorTests.swift"]]
    report = {"dataset": RECORD, "archive_md5": ARCHIVES, "split": args.split,
              "selection": "All comp takes from players 00/01 (dev) and 04/05 (holdout); two most prevalent supported pitch sets per take",
              "reference": "performed chord annotations; inversions ignored; added/omitted degrees preserved",
              "input_sha256": input_digest(args.dataset, items, excluded),
              "interior_margin_seconds": {"start": 0.6, "end": 0.15},
              "source_sha256": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                for p in sources + [Path(__file__).resolve()]},
              "tracks": len(items), "excluded": excluded, "evaluations": {}}
    with tempfile.TemporaryDirectory(prefix="chordlyze-drill-benchmark-") as temporary:
        work = Path(temporary)
        manifest_path = work / "manifest.json"
        manifest_path.write_text(json.dumps(items))
        executable = work / "detector"
        subprocess.run(["swiftc", "-O", "-module-cache-path", str(work / "module-cache"),
                        *map(str, sources), "-o", str(executable)], check=True)
        for mode in ["legacy", "current"]:
            output = subprocess.check_output([str(executable), str(manifest_path)] + (["--legacy"] if mode == "legacy" else []))
            results = {r["id"]: r for r in json.loads(output)}
            summary = {}
            for split in sorted({item["split"] for item in items}):
                subset = [item for item in items if item["split"] == split]
                evaluation = {"tracks": len(subset), "processing_seconds": sum(results[i["id"]]["processing_seconds"] for i in subset),
                              "audio_seconds": sum(i["duration"] for i in subset), "per_track": []}
                for interior in [False, True]:
                    total = collections.Counter()
                    for item in subset:
                        counts = score(item, results[item["id"]], interior=interior)
                        total.update(counts)
                        if interior:
                            evaluation["per_track"].append({"id": item["id"], "targets": [item["targetA"], item["targetB"]], **metrics(counts)})
                    evaluation["interior" if interior else "full_timeline"] = metrics(total)
                summary[split] = evaluation
            report["evaluations"][mode] = summary
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    for mode, splits in report["evaluations"].items():
        for split, evaluation in splits.items():
            print(mode, split, json.dumps({k: v for k, v in evaluation["interior"].items() if k in
                ["accepted_precision", "target_time_coverage", "target_segment_recall", "non_target_false_accept_rate"]}))
    print(f"Report: {args.out}")


if __name__ == "__main__":
    main()
