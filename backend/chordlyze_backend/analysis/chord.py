"""Canonical chord model: pitch-class root, Harte quality, optional slash bass.

Recognizers emit Harte labels ("C#:min7/b7", "N"); the client shows display
names ("C#m7/B", "N.C."). Both sides parse and format through this one table so
a quality the recognizer starts emitting tomorrow is not silently mangled by a
string split somewhere else.
"""
from __future__ import annotations

from dataclasses import dataclass, replace

PITCHES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
_LETTER = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}
_ACCIDENTAL = {"#": 1, "b": -1, "♯": 1, "♭": -1}

# Harte shorthand -> (display suffix, roman-numeral extension, triad family,
# intervals in semitones above the root).
_QUALITIES: dict[str, tuple[str, str, str, tuple[int, ...]]] = {
    "maj":     ("",      "",      "maj", (0, 4, 7)),
    "min":     ("m",     "",      "min", (0, 3, 7)),
    "dim":     ("°",     "°",     "dim", (0, 3, 6)),
    "aug":     ("+",     "+",     "aug", (0, 4, 8)),
    "sus2":    ("sus2",  "sus2",  "sus", (0, 2, 7)),
    "sus4":    ("sus4",  "sus4",  "sus", (0, 5, 7)),
    "7":       ("7",     "7",     "maj", (0, 4, 7, 10)),
    "maj7":    ("maj7",  "maj7",  "maj", (0, 4, 7, 11)),
    "min7":    ("m7",    "7",     "min", (0, 3, 7, 10)),
    "minmaj7": ("mMaj7", "maj7",  "min", (0, 3, 7, 11)),
    "dim7":    ("°7",    "°7",    "dim", (0, 3, 6, 9)),
    "hdim7":   ("ø7",    "ø7",    "dim", (0, 3, 6, 10)),
    "maj6":    ("6",     "6",     "maj", (0, 4, 7, 9)),
    "min6":    ("m6",    "6",     "min", (0, 3, 7, 9)),
    "9":       ("9",     "9",     "maj", (0, 4, 7, 10, 14)),
    "maj9":    ("maj9",  "maj9",  "maj", (0, 4, 7, 11, 14)),
    "min9":    ("m9",    "9",     "min", (0, 3, 7, 10, 14)),
}
_BY_SUFFIX = {v[0]: k for k, v in _QUALITIES.items()}
# Harte bass degrees are scale degrees relative to the root ("/3", "/b7").
_DEGREE = {1: 0, 2: 2, 3: 4, 4: 5, 5: 7, 6: 9, 7: 11, 9: 14, 11: 17, 13: 21}


def _family_of(quality: str) -> str:
    if quality in _QUALITIES:
        return _QUALITIES[quality][2]
    for prefix in ("min", "dim", "aug", "sus"):
        if quality.startswith(prefix):
            return prefix
    return "maj"


@dataclass(frozen=True)
class Chord:
    root: int                 # pitch class, 0 = C
    quality: str              # Harte shorthand ("maj", "min7", …)
    bass: int | None = None   # pitch class of the slash bass; None = root position

    @property
    def suffix(self) -> str:
        return _QUALITIES[self.quality][0] if self.quality in _QUALITIES else self.quality

    @property
    def roman_extension(self) -> str:
        return _QUALITIES[self.quality][1] if self.quality in _QUALITIES else self.quality

    @property
    def family(self) -> str:
        """Triad family driving key finding and numeral case: maj/min/dim/aug/sus."""
        return _family_of(self.quality)

    @property
    def intervals(self) -> tuple[int, ...] | None:
        return _QUALITIES[self.quality][3] if self.quality in _QUALITIES else None

    @property
    def display(self) -> str:
        out = PITCHES[self.root] + self.suffix
        if self.bass is not None:
            out += "/" + PITCHES[self.bass]
        return out

    @property
    def label(self) -> str:
        out = f"{PITCHES[self.root]}:{self.quality}"
        if self.bass is not None:
            out += "/" + _degree_name((self.bass - self.root) % 12)
        return out

    def without_bass(self) -> "Chord":
        return replace(self, bass=None)

    def transposed(self, semitones: int) -> "Chord":
        return Chord((self.root + semitones) % 12, self.quality,
                     None if self.bass is None else (self.bass + semitones) % 12)


def _degree_name(semitones: int) -> str:
    for degree, offset in _DEGREE.items():
        if offset % 12 == semitones:
            return str(degree)
        if (offset - 1) % 12 == semitones:
            return f"b{degree}"
    raise ValueError(f"no scale degree {semitones} semitones above the root")


def _parse_note(text: str) -> tuple[int, str]:
    """Leading note name -> (pitch class, rest of the string)."""
    if not text or text[0] not in _LETTER:
        raise ValueError(f"not a chord root: {text!r}")
    pc = _LETTER[text[0]]
    i = 1
    while i < len(text) and text[i] in _ACCIDENTAL:
        pc += _ACCIDENTAL[text[i]]
        i += 1
    return pc % 12, text[i:]


def _parse_degree(text: str) -> int:
    """Harte bass degree ("3", "b7", "#5") -> semitones above the root."""
    i = 0
    shift = 0
    while i < len(text) and text[i] in "b#":
        shift += 1 if text[i] == "#" else -1
        i += 1
    degree = text[i:]
    if not degree.isdigit() or int(degree) not in _DEGREE:
        raise ValueError(f"bad bass degree: {text!r}")
    return (_DEGREE[int(degree)] + shift) % 12


def parse_label(label: str) -> Chord | None:
    """Harte label -> Chord; None for "N" (no chord). Raises on garbage."""
    if label == "N":
        return None
    root, rest = _parse_note(label)
    quality = "maj"
    bass = None
    if rest.startswith(":"):
        rest = rest[1:]
        quality, _, degree = rest.partition("/")
        if not quality:
            raise ValueError(f"empty quality in {label!r}")
        if degree:
            bass = (root + _parse_degree(degree)) % 12
    elif rest.startswith("/"):
        bass = (root + _parse_degree(rest[1:])) % 12
    elif rest:
        raise ValueError(f"malformed chord label {label!r}")
    return Chord(root, quality, bass)


def parse_display(name: str) -> Chord | None:
    """Display name ("F#m7/A", "N.C.") -> Chord; None for no-chord."""
    if name == "N.C.":
        return None
    body, _, bass_text = name.partition("/")
    root, suffix = _parse_note(body)
    bass = None
    if bass_text:
        bass, trailing = _parse_note(bass_text)
        if trailing:
            raise ValueError(f"malformed bass in {name!r}")
    return Chord(root, _BY_SUFFIX.get(suffix, suffix), bass)


def display(label: str) -> str:
    """'C:maj' -> 'C', 'A:min7' -> 'Am7', 'N' -> 'N.C.'."""
    chord = parse_label(label)
    return "N.C." if chord is None else chord.display
