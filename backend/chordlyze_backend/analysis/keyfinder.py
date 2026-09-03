"""Key detection and Roman-numeral analysis over recognized chord segments.

Key is estimated from chord content: each chord votes for the keys whose
diatonic triads share its root and triad family (a min7 votes like a min
triad), weighted by segment duration. Roman numerals are then assigned
relative to the winning key, with the chord's extension appended.
"""
from __future__ import annotations

from dataclasses import dataclass

from .chord import PITCHES, Chord, parse_label
from .engine import ChordSegment

# Diatonic triads as (scale degree semitone offset, family) per mode.
_MAJOR_DEGREES = [(0, "maj"), (2, "min"), (4, "min"), (5, "maj"), (7, "maj"), (9, "min"), (11, "dim")]
_MINOR_DEGREES = [(0, "min"), (2, "dim"), (3, "maj"), (5, "min"), (7, "min"), (8, "maj"), (10, "maj")]
_ROMAN = ["I", "II", "III", "IV", "V", "VI", "VII"]


def _pc(name: str) -> int:
    return PITCHES.index(name)


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
        chord = parse_label(seg.label)
        if chord is None:
            continue
        dur = seg.end - seg.start
        total += dur
        for tonic in range(12):
            for degrees, mode in ((_MAJOR_DEGREES, "major"), (_MINOR_DEGREES, "minor")):
                for offset, family in degrees:
                    if (tonic + offset) % 12 == chord.root and family == chord.family:
                        weight = dur * (1.5 if offset == 0 else 1.0)  # tonic chord counts extra
                        scores[(tonic, mode)] = scores.get((tonic, mode), 0.0) + weight
    if not scores or total == 0.0:
        return None
    (tonic, mode), _best = max(scores.items(), key=lambda kv: kv[1])
    # Confidence = how much of the song's chord time is diatonic to this key.
    degrees = _MAJOR_DEGREES if mode == "major" else _MINOR_DEGREES
    diatonic = {((tonic + offset) % 12, family) for offset, family in degrees}
    fit = 0.0
    for seg in segments:
        chord = parse_label(seg.label)
        if chord and (chord.root, chord.family) in diatonic:
            fit += seg.end - seg.start
    return KeyEstimate(PITCHES[tonic], mode, round(fit / total, 3))


def _numeral(index: int, chord: Chord, prefix: str = "") -> str:
    numeral = _ROMAN[index]
    if chord.family in ("min", "dim"):
        numeral = numeral.lower()
    return prefix + numeral + chord.roman_extension


def roman_numeral(label: str, key: KeyEstimate) -> str | None:
    """Roman numeral of a chord in a key; chromatic chords get a 'b' prefix guess."""
    chord = parse_label(label)
    if chord is None:
        return None
    tonic = _pc(key.tonic)
    offset = (chord.root - tonic) % 12
    degrees = _MAJOR_DEGREES if key.mode == "major" else _MINOR_DEGREES
    for i, (deg_offset, _family) in enumerate(degrees):
        if deg_offset == offset:
            return _numeral(i, chord)
    # Chromatic: name by nearest flat degree (e.g. bVII in major).
    for i, (deg_offset, _family) in enumerate(degrees):
        if (deg_offset - 1) % 12 == offset:
            return _numeral(i, chord, prefix="b")
    return "?"


def analyze(segments: list[ChordSegment]) -> dict:
    key = estimate_key(segments)
    chords = []
    for seg in segments:
        entry = seg.to_dict()
        entry["roman"] = roman_numeral(seg.label, key) if key else None
        chords.append(entry)
    from .difficulty import difficulty
    return {
        "key": key.name if key else None,
        "key_confidence": key.confidence if key else None,
        "chords": chords,
        # Seconds of audio the chords describe; nothing past this is known.
        "analyzed_end": round(segments[-1].end, 3) if segments else 0.0,
        "difficulty": difficulty(chords),
    }
