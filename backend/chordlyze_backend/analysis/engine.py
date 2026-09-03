"""Chord recognition engine.

Primary pipeline: madmom CNN chord features + CRF decoding (maj/min vocabulary,
MIREX-grade accuracy). Audio is decoded to a mono 44.1 kHz WAV via ffmpeg so any
input container/codec works.
"""
from __future__ import annotations

import subprocess
import tempfile
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path


@dataclass(frozen=True)
class ChordSegment:
    start: float  # seconds
    end: float    # seconds
    label: str    # e.g. "C:maj", "A:min", "N" (no chord)

    def to_dict(self) -> dict:
        return {"start": round(self.start, 3), "end": round(self.end, 3), "label": self.label}


class AudioDecodeError(RuntimeError):
    pass


def _decode_to_wav(src: Path, dst: Path) -> None:
    proc = subprocess.run(
        ["ffmpeg", "-y", "-i", str(src), "-ac", "1", "-ar", "44100",
         "-sample_fmt", "s16", str(dst)],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        raise AudioDecodeError(f"ffmpeg failed to decode {src.name}: {proc.stderr.strip().splitlines()[-1]}")


@lru_cache(maxsize=1)
def _processors():
    # Imported lazily: madmom loads model weights at construction time.
    from madmom.features.chords import (
        CNNChordFeatureProcessor,
        CRFChordRecognitionProcessor,
    )
    return CNNChordFeatureProcessor(), CRFChordRecognitionProcessor()

def recognize_chords(audio_path: str | Path) -> list[ChordSegment]:
    """Run chord recognition on an audio file. Returns time-aligned segments."""
    src = Path(audio_path)
    if not src.exists():
        raise FileNotFoundError(src)
    features, decoder = _processors()
    with tempfile.TemporaryDirectory() as tmp:
        wav = Path(tmp) / "audio.wav"
        _decode_to_wav(src, wav)
        feats = features(str(wav))
        raw = decoder(feats)
    segments = [ChordSegment(float(s), float(e), str(lbl)) for s, e, lbl in raw]
    return merge_adjacent(segments)


def merge_adjacent(segments: list[ChordSegment]) -> list[ChordSegment]:
    """Join touching segments that carry the same label."""
    merged: list[ChordSegment] = []
    for seg in segments:
        if merged and merged[-1].label == seg.label and abs(merged[-1].end - seg.start) < 1e-6:
            merged[-1] = ChordSegment(merged[-1].start, seg.end, seg.label)
        else:
            merged.append(seg)
    return merged
