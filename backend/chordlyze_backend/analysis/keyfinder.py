"""Key detection and Roman-numeral analysis over recognized chord segments.

Key is estimated from chord content: each maj/min chord votes for the keys whose
diatonic triads contain it, weighted by segment duration. Roman numerals are then
assigned relative to the winning key.
"""
from __future__ import annotations

from dataclasses import dataclass

from .engine import ChordSegment

PITCHES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
_ENHARMONIC = {"Db": "C#", "Eb": "D#", "Gb": "F#", "Ab": "G#", "Bb": "A#",
               "Cb": "B", "Fb": "E", "E#": "F", "B#": "C"}

# Diatonic triads as (scale degree semitone offset, quality) per mode.
_MAJOR_DEGREES = [(0, "maj"), (2, "min"), (4, "min"), (5, "maj"), (7, "maj"), (9, "min"), (11, "dim")]
_MINOR_DEGREES = [(0, "min"), (2, "dim"), (3, "maj"), (5, "min"), (7, "min"), (8, "maj"), (10, "maj")]
_ROMAN = ["I", "II", "III", "IV", "V", "VI", "VII"]


def _pc(name: str) -> int:
    name = _ENHARMONIC.get(name, name)
    return PITCHES.index(name)


def parse_label(label: str) -> tuple[int, str] | None:
    """'C#:min' -> (1, 'min'); returns None for 'N' (no chord)."""
    if label == "N":
        return None
    root, _, quality = label.partition(":")
    return _pc(root), (quality or "maj")


@dataclass(frozen=True)
class KeyEstimate:
    tonic: str          # e.g. "G"
    mode: str           # "major" | "minor"
    confidence: float   # 0..1, vote share of winning key

    @property
    def name(self) -> str:
        return f"{self.tonic} {self.mode}"


def estimate_key(segments: list[ChordSegment]) -> KeyEstimate | None:
    scores: dict[tuple[int, str], float] = {}
    total = 0.0
    for seg in segments:
        parsed = parse_label(seg.label)
        if parsed is None:
            continue
        root, quality = parsed
        dur = seg.end - seg.start
        total += dur
        for tonic in range(12):
            for degrees, mode in ((_MAJOR_DEGREES, "major"), (_MINOR_DEGREES, "minor")):
                for offset, dq in degrees:
                    if (tonic + offset) % 12 == root and dq == quality:
                        weight = dur * (1.5 if offset == 0 else 1.0)  # tonic chord counts extra
                        scores[(tonic, mode)] = scores.get((tonic, mode), 0.0) + weight
    if not scores or total == 0.0:
        return None
    (tonic, mode), _best = max(scores.items(), key=lambda kv: kv[1])
    # Confidence = how much of the song's chord time is diatonic to this key.
    degrees = _MAJOR_DEGREES if mode == "major" else _MINOR_DEGREES
    diatonic = {((tonic + offset) % 12, quality) for offset, quality in degrees}
    fit = 0.0
    for seg in segments:
        parsed = parse_label(seg.label)
        if parsed and parsed in diatonic:
            fit += seg.end - seg.start
    return KeyEstimate(PITCHES[tonic], mode, round(fit / total, 3))


def roman_numeral(label: str, key: KeyEstimate) -> str | None:
    """Roman numeral of a chord in a key; chromatic chords get a 'b'/'#' prefix guess."""
    parsed = parse_label(label)
    if parsed is None:
        return None
    root, quality = parsed
    tonic = _pc(key.tonic)
    offset = (root - tonic) % 12
    degrees = _MAJOR_DEGREES if key.mode == "major" else _MINOR_DEGREES
    for i, (deg_offset, deg_quality) in enumerate(degrees):
        if deg_offset == offset:
            numeral = _ROMAN[i]
            out = numeral if quality == "maj" else numeral.lower()
            return out + ("°" if quality == "dim" else "")
    # Chromatic: name by nearest flat degree (e.g. bVII in major).
    for i, (deg_offset, _q) in enumerate(degrees):
        if (deg_offset - 1) % 12 == offset:
            numeral = "b" + _ROMAN[i]
            return numeral if quality == "maj" else numeral.lower()
    return "?"


def analyze(segments: list[ChordSegment]) -> dict:
    key = estimate_key(segments)
    chords = []
    for seg in segments:
        entry = seg.to_dict()
        entry["roman"] = roman_numeral(seg.label, key) if key else None
        chords.append(entry)
    return {
        "key": key.name if key else None,
        "key_confidence": key.confidence if key else None,
        "chords": chords,
    }
