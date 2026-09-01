"""Scoring of a practice take against a song's reference chord chart.

The take is recorded with the song in headphones, so the microphone hears only
the player's instrument; the detected chords are compared to the reference at
the same timeline (plus an optional start offset).
"""
from __future__ import annotations

from .analysis.difficulty import _display


def _overlap(a0: float, a1: float, b0: float, b1: float) -> float:
    return max(0.0, min(a1, b1) - max(a0, b0))


def score_take(reference: list[dict], detected: list[dict],
               offset: float = 0.0) -> dict:
    """reference/detected: [{start, end, label}]; offset shifts the take onto
    the song timeline (take second 0 == song second `offset`)."""
    ref = [r for r in reference if r.get("label") not in (None, "N")]
    det = [{"start": float(d["start"]) + offset, "end": float(d["end"]) + offset,
            "label": d["label"]}
           for d in detected if d.get("label") not in (None, "N")]
    if not ref:
        return {"error": "no reference chords"}
    take_start = det[0]["start"] if det else 0.0
    take_end = det[-1]["end"] if det else 0.0

    # Judge only the part of the song the take covers.
    covered = [r for r in ref
               if _overlap(float(r["start"]), float(r["end"]), take_start, take_end) > 0.5]
    if not covered:
        return {"error": "take does not overlap the song"}

    per_chord: dict[str, dict] = {}
    correct_time = 0.0
    total_time = 0.0
    for r in covered:
        r0, r1 = float(r["start"]), float(r["end"])
        name = _display(r["label"])
        dur = r1 - r0
        hit = sum(_overlap(r0, r1, d["start"], d["end"])
                  for d in det if _display(d["label"]) == name)
        hit = min(hit, dur)
        correct_time += hit
        total_time += dur
        agg = per_chord.setdefault(name, {"name": name, "hit": 0.0, "total": 0.0,
                                          "count": 0})
        agg["hit"] += hit
        agg["total"] += dur
        agg["count"] += 1

    # Transition lag: reference chord-change instants vs when the player
    # actually landed the new chord.
    transitions: dict[tuple[str, str], dict] = {}
    for prev, cur in zip(covered, covered[1:]):
        t = float(cur["start"])
        frm, to = _display(prev["label"]), _display(cur["label"])
        if frm == to:
            continue
        landed = None
        for d in det:
            if _display(d["label"]) == to and d["end"] > t - 0.5:
                landed = max(0.0, d["start"] - t)
                break
        agg = transitions.setdefault((frm, to), {"from": frm, "to": to,
                                                 "lags": [], "misses": 0, "count": 0})
        agg["count"] += 1
        if landed is None or landed > 3.0:
            agg["misses"] += 1
        else:
            agg["lags"].append(landed)

    transition_rows = []
    for agg in transitions.values():
        avg = round(sum(agg["lags"]) / len(agg["lags"]), 2) if agg["lags"] else None
        transition_rows.append({"from": agg["from"], "to": agg["to"],
                                "avg_lag": avg, "misses": agg["misses"],
                                "count": agg["count"]})
    transition_rows.sort(key=lambda r: (r["misses"], r["avg_lag"] or 0), reverse=True)

    # Section accuracy: covered span split into quarters.
    span0, span1 = float(covered[0]["start"]), float(covered[-1]["end"])
    quarter = max(1.0, (span1 - span0) / 4)
    sections = []
    for i in range(4):
        s0, s1 = span0 + i * quarter, span0 + (i + 1) * quarter
        tot = hit = 0.0
        for r in covered:
            seg = _overlap(float(r["start"]), float(r["end"]), s0, s1)
            if seg <= 0:
                continue
            name = _display(r["label"])
            got = sum(_overlap(max(float(r["start"]), s0), min(float(r["end"]), s1),
                               d["start"], d["end"])
                      for d in det if _display(d["label"]) == name)
            tot += seg
            hit += min(got, seg)
        sections.append({"start": round(s0, 1), "end": round(s1, 1),
                         "accuracy": round(hit / tot, 3) if tot else None})

    all_lags = [l for agg in transitions.values() for l in agg["lags"]]
    return {
        "accuracy": round(correct_time / total_time, 3) if total_time else 0.0,
        "avg_lag": round(sum(all_lags) / len(all_lags), 2) if all_lags else None,
        "covered_start": round(span0, 1),
        "covered_end": round(span1, 1),
        "per_chord": sorted(
            [{"name": a["name"], "accuracy": round(a["hit"] / a["total"], 3),
              "count": a["count"]} for a in per_chord.values()],
            key=lambda r: r["accuracy"]),
        "transitions": transition_rows[:8],
        "sections": sections,
    }
