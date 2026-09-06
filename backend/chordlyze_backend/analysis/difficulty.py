"""Playing-difficulty score for a song, derived from its chord chart.

Guitar-centric and capo-aware. Factors, each weighted by how long a chord
sounds rather than by how many distinct names appear:

- effective vocabulary: the perplexity of the chord-time distribution, so
  four chords that carry a song count as four even if a dozen passing chords
  flash by;
- change rate in changes per minute;
- barre share: time spent on shapes that are not open shapes after the best
  capo (0-7), because the app suggests that capo and the player uses it;
- extension share: time on anything beyond a plain major or minor triad.

Returns a 1-10 score and a coarse level used for badges. Calibrated on a real
110-song library so that roughly a third is easy and under a tenth is hard;
the old name-counting formula rated 96% of it hard.
"""
from __future__ import annotations

import math
from collections import defaultdict

from .chord import PITCHES, parse_label

# Beginner-friendly open shapes on guitar, as (root name, base quality).
_OPEN_SHAPES = {
    ("C", "maj"), ("A", "maj"), ("G", "maj"), ("E", "maj"), ("D", "maj"),
    ("A", "min"), ("E", "min"), ("D", "min"),
    ("A", "7"), ("E", "7"), ("D", "7"), ("G", "7"), ("C", "7"), ("B", "7"),
    ("A", "min7"), ("E", "min7"), ("D", "min7"),
    ("C", "maj7"), ("A", "maj7"), ("D", "maj7"), ("F", "maj7"), ("G", "maj7"), ("E", "maj7"),
    ("A", "sus2"), ("A", "sus4"), ("D", "sus2"), ("D", "sus4"), ("E", "sus4"), ("C", "sus2"), ("G", "sus4"),
}
_BASE_QUALITIES = ("maj7", "min7", "maj", "min", "7", "sus2", "sus4", "dim", "aug")
MAX_CAPO = 7


def _base_quality(quality: str) -> str:
    """'min9' -> 'min7'-ish shape family; 'maj' stays 'maj'."""
    for base in _BASE_QUALITIES:
        if quality.startswith(base):
            return base
    return quality


def difficulty(chords: list[dict]) -> dict | None:
    """chords: [{start, end, label}, ...] from an analysis result."""
    real = []
    for c in chords:
        if not c.get("label") or c["label"] == "N":
            continue
        chord = parse_label(c["label"])
        seconds = float(c["end"]) - float(c["start"])
        if chord is not None and seconds > 0:
            real.append((chord, seconds))
    if not real:
        return None
    total = sum(seconds for _, seconds in real)

    weight: dict[tuple[int, str], float] = defaultdict(float)
    for chord, seconds in real:
        weight[(chord.root, _base_quality(chord.quality))] += seconds
    perplexity = math.exp(-sum(w / total * math.log(w / total) for w in weight.values()))

    changes = sum(1 for prev, cur in zip(real, real[1:])
                  if (prev[0].root, prev[0].quality) != (cur[0].root, cur[0].quality))
    span = max(1.0, float(chords[-1]["end"]) - float(chords[0]["start"]))
    changes_per_min = changes / span * 60

    barre_share = min(
        sum(w for (root, quality), w in weight.items()
            if (PITCHES[(root - capo) % 12], quality) not in _OPEN_SHAPES) / total
        for capo in range(MAX_CAPO + 1))
    extension_share = sum(seconds for chord, seconds in real if chord.quality not in ("maj", "min")) / total

    score = (1.0 + 0.6 * max(0.0, perplexity - 3) + 0.05 * changes_per_min
             + 3.5 * barre_share + 0.8 * extension_share)
    score = round(min(10.0, max(1.0, score)), 1)
    level = "easy" if score <= 3.5 else "medium" if score <= 6.5 else "hard"
    return {"score": score, "level": level}
