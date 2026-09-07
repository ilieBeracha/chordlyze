"""Audio-derived beats, downbeats, complete bars and recurring sections.

Beat This predicts beats/downbeats without a fixed meter. Complete cycles of
two through twelve detected beats become bars, with no invented denominator.
Missing or implausible cycles remain gaps rather than forced 4/4 bars.
"""
from __future__ import annotations

from pathlib import Path
import numpy as np
from .structure import STRUCTURE_MODEL, analyze_sections
from .rhythm import MODEL as RHYTHM_MODEL, worker

RHYTHM_VERSION = 1


def complete_bars(beats: list[float], positions: list[int], duration: float) -> list[dict]:
    """Only complete cycles ending at a detected next downbeat; no tail extrapolation."""
    if len(beats) != len(positions) or len(beats) < 3:
        return []
    if (any(not np.isfinite(b) or b < 0 or b >= duration for b in beats)
            or any(b <= a for a, b in zip(beats, beats[1:]))):
        raise ValueError("invalid beat times")
    starts = [i for i, p in enumerate(positions) if p == 1]
    bars = []
    for a, b in zip(starts, starts[1:]):
        count = b-a
        gaps = np.diff(beats[a:b+1])
        if (count not in range(2, 13) or positions[a:b] != list(range(1, count+1))
                or np.max(gaps) > np.min(gaps)*1.8):
            continue
        bars.append({"start": beats[a], "end": beats[b], "beats": count})
    return bars


def track_beats(audio_path: str | Path) -> dict | None:
    import librosa

    y, sr = librosa.load(str(audio_path), sr=22050, mono=True)
    if y.size < sr or not np.isfinite(y).all() or float(np.max(np.abs(y))) < 1e-5:
        return None
    duration = len(y)/sr
    beats, downbeats = worker.predict(y)
    # A downbeat is an actual predicted beat, never a freely snapped timestamp.
    downbeat_set = set(downbeats)
    indices = [i for i, t in enumerate(beats) if t in downbeat_set]
    positions = [0]*len(beats)
    for a, b in zip(indices, indices[1:]):
        if 2 <= b-a <= 12:
            positions[a:b] = list(range(1, b-a+1))
    for i in indices: positions[i] = 1
    bars = complete_bars(beats, positions, duration)
    if len(beats) < 2:
        _, times = librosa.beat.beat_track(y=y, sr=sr, units="time")
        beats = [round(float(b), 3) for b in times if 0 <= b < duration]
        positions, bars = [], []
    if len(beats) < 2:
        return None
    bpm = 60/float(np.median(np.diff(beats)))
    contiguous = all(abs(a["end"]-b["start"]) < .001 for a, b in zip(bars, bars[1:]))
    return {"bpm": round(bpm, 1), "beats": beats, "beat_positions": positions,
            "bars": bars, "rhythm_version": RHYTHM_VERSION,
            "rhythm_model": RHYTHM_MODEL if positions else "librosa-beat-only-v1",
            "structure_model": STRUCTURE_MODEL,
            "sections": analyze_sections(y, sr, bars) if contiguous and bars else []}


def validate_tempo(tempo: dict | None, duration: float) -> dict | None:
    """Validate worker timing before storage; legacy beat-only payloads still work."""
    if tempo is None:
        return None
    import math

    def number(value):
        return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)
    beats = tempo.get("beats")
    if (not number(tempo.get("bpm")) or tempo["bpm"] <= 0 or not isinstance(beats, list)
            or len(beats) > 10000 or any(not number(b) or b < 0 or b >= duration for b in beats)
            or any(b <= a for a, b in zip(beats, beats[1:]))):
        raise ValueError("invalid tempo or beat times")
    if "rhythm_version" not in tempo:
        if any(k in tempo for k in ("bars", "sections", "beat_positions")):
            raise ValueError("bar data requires a rhythm version")
        return {"bpm": tempo["bpm"], "beats": beats}
    if tempo["rhythm_version"] != RHYTHM_VERSION:
        raise ValueError("unsupported rhythm version")
    positions, bars, sections = (tempo.get(k) for k in ("beat_positions", "bars", "sections"))
    if (not isinstance(positions, list) or not isinstance(bars, list) or not isinstance(sections, list)
            or any(type(p) is not int or not 0 <= p <= 12 for p in positions)
            or (positions and len(positions) != len(beats))):
        raise ValueError("invalid bar positions")
    expected = complete_bars(beats, positions, duration) if positions else []
    if bars != expected:
        raise ValueError("bars do not match detected beat cycles")
    previous_end, occurrences = 0, {}
    for section in sections:
        if not isinstance(section, dict):
            raise ValueError("invalid section")
        a, b, label = section.get("start_bar"), section.get("end_bar"), section.get("label")
        if (type(a) is not int or type(b) is not int or a != previous_end+1 or not a <= b <= len(bars)
                or not isinstance(label, str) or not label.isascii() or not label.isalpha()
                or not label.isupper() or len(label) > 3
                or section.get("start") != bars[a-1]["start"] or section.get("end") != bars[b-1]["end"]
                or any(x["end"] != y["start"] for x, y in zip(bars[a-1:b], bars[a:b]))):
            raise ValueError("section is not a contiguous bar range")
        occurrences[label] = occurrences.get(label, 0)+1
        if section.get("occurrence") != occurrences[label]:
            raise ValueError("invalid section occurrence")
        previous_end = b
    if sections and previous_end != len(bars):
        raise ValueError("sections do not cover the complete bars")
    return tempo
