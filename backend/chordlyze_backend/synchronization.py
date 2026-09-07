"""Align audible song samples to a chord chart, refusing ambiguous matches.

Spotify positions accompany each microphone clip. Search a single affine map
across all clips; repeated progressions must win against competing alignments.
No match is treated as an instruction to shift the chart speculatively.
"""
from dataclasses import dataclass

import numpy as np

from .analysis.chord import parse_label


class UncertainSync(ValueError):
    pass


@dataclass
class Sample:
    spotify_start: float
    duration: float
    segments: list[dict]


def _code(label):
    chord = parse_label(label)
    if chord is None:
        return -1
    # Extension recognition is less reliable in a room than root/triad family.
    families = {"maj": 0, "min": 1, "dim": 2, "aug": 3, "sus": 4}
    return chord.root * 5 + families[chord.family]


def align(reference: list[dict], samples: list[Sample]) -> dict:
    if len(samples) != 3 or len(reference) < 6:
        raise UncertainSync("Not enough chord changes to synchronize reliably. Try calibration by ear.")
    starts = np.array([s["start"] for s in reference], dtype=float)
    ends = np.array([s["end"] for s in reference], dtype=float)
    labels = np.array([_code(s["label"]) for s in reference], dtype=int)
    times, heard, groups = [], [], []
    changes = 0
    for group, sample in enumerate(samples):
        if not 8 <= sample.duration <= 30 or not np.isfinite(sample.spotify_start) or sample.spotify_start < 0:
            raise UncertainSync("A listening sample was too short or interrupted. Try again.")
        local = np.arange(.25, sample.duration - .25, .2)
        codes = np.full(len(local), -1, dtype=int)
        previous = None
        for segment in sample.segments:
            code = _code(segment["label"])
            codes[(local >= segment["start"]) & (local < segment["end"])] = code
            if code >= 0 and previous is not None and code != previous:
                changes += 1
            previous = code if code >= 0 else previous
        voiced = codes >= 0
        if voiced.mean() < .6:
            raise UncertainSync("The microphone could not hear enough music. Use the phone speaker and try again.")
        times.extend((local[voiced] + sample.spotify_start).tolist())
        heard.extend(codes[voiced].tolist())
        groups.extend([group] * int(voiced.sum()))
    if changes < 6 or len(set(heard)) < 3:
        raise UncertainSync("These passages repeat too few chords for a reliable match. Try calibration by ear.")
    t, y, g = np.array(times), np.array(heard), np.array(groups)
    sample_span = max(s.spotify_start for s in samples) - min(s.spotify_start for s in samples)
    if sample_span < 15:
        raise UncertainSync("Listening samples need to be farther apart. Try again.")
    # Short spans cannot distinguish drift from recognition boundary noise.
    scales = np.arange(.9, 1.10001, .002) if sample_span >= 60 else np.array([1.0])
    offsets = np.arange(-30, 30.0001, .1)
    ss, oo = np.meshgrid(scales, offsets, indexing="ij")
    ss, oo = ss.ravel(), oo.ravel()
    scores = np.empty(len(ss))
    per_group = np.empty((len(ss), 3))
    for begin in range(0, len(ss), 512):
        stop = min(len(ss), begin + 512)
        chart_times = (t[None, :] - oo[begin:stop, None]) / ss[begin:stop, None]
        index = np.searchsorted(starts, chart_times, side="right") - 1
        safe = np.clip(index, 0, len(starts) - 1)
        match = (index >= 0) & (chart_times < ends[safe]) & (labels[safe] == y[None, :])
        per_group[begin:stop] = np.stack([match[:, g == i].mean(axis=1) for i in range(3)], axis=1)
        scores[begin:stop] = per_group[begin:stop].mean(axis=1)
    best = int(np.argmax(scores))
    # Use the middle of the best plateau, favoring less speculative speed change.
    close = np.where(scores >= scores[best] - .002)[0]
    best = int(min(close, key=lambda i: (abs(ss[i] - 1), abs(oo[i] - np.median(oo[close])))))
    endpoint_times = np.array([t.min(), t.max()])
    displacement = np.max(np.abs((endpoint_times[None, :] - oo[:, None]) / ss[:, None]
                                - (endpoint_times[None, :] - oo[best]) / ss[best]), axis=1)
    alternatives = scores[displacement >= 1.5]
    margin = float(scores[best] - alternatives.max()) if len(alternatives) else 1.0
    if scores[best] < .78 or per_group[best].min() < .65 or margin < .06:
        raise UncertainSync("No unique timing match. The recording may differ, or the room audio is unclear. Your current timing was kept.")
    if abs(oo[best]) > 29.8 or (len(scales) > 1 and (ss[best] < .902 or ss[best] > 1.098)):
        raise UncertainSync("The timing difference is outside the supported range. Check the song version or calibrate by ear.")
    anchors = []
    for i in range(3):
        midpoint = float(np.median(t[g == i]))
        anchors.append({"chart": max(0, (midpoint - float(oo[best])) / float(ss[best])), "spotify": midpoint})
    return {"offset": round(float(oo[best]), 4), "scale": round(float(ss[best]), 5),
            "anchors": anchors, "method": "automatic", "match_score": round(float(scores[best]), 3),
            "match_margin": round(margin, 3), "drift_measured": len(scales) > 1}
