"""Grade the recorded intersection of a take and its reference chart.

Silence remains part of the recording span. Chord identity and transition
timing are evaluated separately; each detected onset can match only one
reference change. Bass voicing remains the player's choice.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, replace

from .analysis.chord import Chord, parse_label

SCORING_VERSION = 2
EARLY_WINDOW = 0.5
LATE_WINDOW = 3.0


@dataclass(frozen=True)
class _Segment:
    start: float
    end: float
    chord: Chord | None


def _segments(rows: list[dict], comparison: str, offset: float = 0) -> list[_Segment]:
    result: list[_Segment] = []
    for row in rows:
        start, end = float(row["start"]), float(row["end"])
        if not math.isfinite(start) or not math.isfinite(end) or start < 0 or end <= start:
            raise ValueError("segments must have finite, nonnegative, increasing times")
        start, end = start + offset, end + offset
        if result and start < result[-1].end - 1e-6:
            raise ValueError("segments overlap or are unordered")
        chord = parse_label(row["label"])
        if chord:
            chord = chord.without_bass()
            if comparison == "major_minor" and chord.family in ("maj", "min"):
                chord = Chord(chord.root, chord.family)
        if result and result[-1].chord == chord and abs(start - result[-1].end) < 1e-6:
            result[-1] = replace(result[-1], end=end)
        else:
            result.append(_Segment(start, end, chord))
    return result


def _overlap(a0: float, a1: float, b0: float, b1: float) -> float:
    return max(0.0, min(a1, b1) - max(a0, b0))


def _mean(values: list[float]) -> float | None:
    return round(sum(values) / len(values), 3) if values else None


def _timing(offsets: list[float]) -> dict:
    return {
        # Preserve the original nonnegative late-only API field.
        "avg_lag": _mean([max(0, x) for x in offsets]),
        "avg_early": _mean([max(0, -x) for x in offsets]),
        "avg_offset": _mean(offsets),
        "avg_timing_error": _mean([abs(x) for x in offsets]),
    }


def score_take(reference: list[dict], detected: list[dict], offset: float = 0.0, *,
               take_duration: float | None = None, comparison: str = "root_quality",
               supported_qualities: set[str] | None = None) -> dict:
    """Score a take whose second zero is song second offset.

    The API supplies duration measured from decoded audio, independent of
    recognized chords. Older direct callers may infer the span from all
    detected intervals, including N. major_minor is only for references
    from the legacy recognizer; rich charts keep exact root/quality grading.
    """
    if comparison not in ("root_quality", "major_minor"):
        raise ValueError("unknown chord comparison")
    if not math.isfinite(offset):
        raise ValueError("offset must be finite")
    if take_duration is not None and (not math.isfinite(take_duration) or take_duration <= 0):
        raise ValueError("take duration must be positive and finite")
    ref = _segments(reference, comparison)
    det = _segments(detected, comparison, offset)
    if not any(r.chord for r in ref):
        return {"error": "no reference chords"}
    if take_duration is None:
        if not det:
            return {"error": "take has no recording span"}
        take_start, take_end = det[0].start, det[-1].end
    else:
        take_start, take_end = offset, offset + take_duration
    if not math.isfinite(take_end):
        raise ValueError("recording end must be finite")

    covered = [replace(r, start=max(r.start, take_start), end=min(r.end, take_end))
               for r in ref if r.chord and _overlap(r.start, r.end, take_start, take_end) > 0]
    if not covered:
        return {"error": "take does not overlap the song"}
    if supported_qualities is not None:
        unsupported = sorted({r.chord.display for r in covered
                              if r.chord.quality not in supported_qualities})
        if unsupported:
            return {"error": "unsupported reference chords for this recognizer: " + ", ".join(unsupported)}

    def hit_time(r: _Segment, start: float, end: float) -> float:
        return sum(_overlap(start, end, d.start, d.end) for d in det if d.chord == r.chord)

    per_chord: dict[str, dict] = {}
    correct_time = total_time = 0.0
    for r in covered:
        duration = r.end - r.start
        hit = hit_time(r, r.start, r.end)
        correct_time += hit
        total_time += duration
        row = per_chord.setdefault(r.chord.display, {"name": r.chord.display, "hit": 0.0,
                                                    "total": 0.0, "count": 0})
        row["hit"] += hit
        row["total"] += duration
        row["count"] += 1

    transitions: dict[tuple[str, str], dict] = {}
    last_match = -1
    for prev, cur in zip(ref, ref[1:]):
        t = cur.start
        if (prev.chord is None or cur.chord is None or prev.chord == cur.chord
                or abs(prev.end - t) > 1e-6 or not take_start < t < take_end):
            continue
        frm, to = prev.chord.display, cur.chord.display
        row = transitions.setdefault((frm, to), {"from": frm, "to": to, "offsets": [],
                                                 "misses": 0, "count": 0})
        row["count"] += 1
        earliest = max(t - EARLY_WINDOW, prev.start, take_start)
        latest = min(t + LATE_WINDOW, cur.end, take_end)
        match = next((i for i, d in enumerate(det)
                      if i > last_match and d.chord == cur.chord
                      and earliest <= d.start < latest
                      and _overlap(t, min(cur.end, take_end), d.start, d.end) > 0), None)
        if match is None:
            row["misses"] += 1
        else:
            last_match = match
            row["offsets"].append(det[match].start - t)

    transition_rows = [{"from": row["from"], "to": row["to"], "misses": row["misses"],
                        "count": row["count"], **_timing(row["offsets"])}
                       for row in transitions.values()]
    transition_rows.sort(key=lambda r: (r["misses"], r["avg_timing_error"] or 0), reverse=True)

    # Include reference rests within the recording; their score is unassessed,
    # not a wrong chord. Every section is clipped to the actual covered span.
    span0, span1 = max(take_start, ref[0].start), min(take_end, ref[-1].end)
    quarter = (span1 - span0) / 4
    sections = []
    for i in range(4):
        start, end = span0 + i * quarter, span0 + (i + 1) * quarter
        total = hit = 0.0
        for r in covered:
            a, b = max(r.start, start), min(r.end, end)
            if b > a:
                total += b - a
                hit += hit_time(r, a, b)
        sections.append({"start": round(start, 3), "end": round(end, 3),
                         "accuracy": round(hit / total, 3) if total else None})

    offsets = [x for row in transitions.values() for x in row["offsets"]]
    return {
        "scoring_version": SCORING_VERSION,
        "comparison": comparison,
        "accuracy": round(correct_time / total_time, 3),
        **_timing(offsets),
        "covered_start": round(span0, 3),
        "covered_end": round(span1, 3),
        "scored_duration": round(total_time, 3),
        "per_chord": sorted(
            [{"name": r["name"], "accuracy": round(r["hit"] / r["total"], 3), "count": r["count"]}
             for r in per_chord.values()], key=lambda r: r["accuracy"]),
        "transitions": transition_rows[:8],
        "sections": sections,
    }
