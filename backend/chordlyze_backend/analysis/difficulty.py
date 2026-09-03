"""Playing-difficulty score for a song, derived from its chord chart.

Factors: chord vocabulary size, change rate, and the share of chords that are
hard on guitar (barre shapes / uncommon roots). Returns a 1-10 score and a
coarse level used for badges.
"""
from __future__ import annotations

from .chord import display as _display

# Beginner-friendly open shapes on guitar.
_OPEN_SHAPES = {"C", "A", "G", "E", "D", "Am", "Em", "Dm", "A7", "E7", "D7",
                "G7", "C7", "B7"}


def difficulty(chords: list[dict]) -> dict | None:
    """chords: [{start, end, label}, ...] from an analysis result."""
    real = [c for c in chords if c.get("label") and c["label"] != "N"]
    if not real:
        return None
    names = [_display(c["label"]) for c in real]
    unique = set(names)
    duration = max(1.0, float(real[-1]["end"]) - float(real[0]["start"]))
    changes_per_min = (len(real) - 1) / duration * 60
    hard_fraction = sum(1 for n in unique if n not in _OPEN_SHAPES) / len(unique)

    score = 1.0 + 0.45 * len(unique) + 0.07 * changes_per_min + 3.5 * hard_fraction
    score = round(min(10.0, max(1.0, score)), 1)
    level = "easy" if score <= 3.5 else "medium" if score <= 6.5 else "hard"
    return {"score": score, "level": level}
