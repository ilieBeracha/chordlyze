"""Chord recognition engine.

Practice and ingest use the pinned ISMIR ensemble. Preview analysis retains
madmom's major/minor vocabulary. Both share PCM decoding, duration measurement,
content hashing, canonical labels and segment validation.
"""
from __future__ import annotations

import hashlib
import math
import subprocess
import tempfile
import threading
import wave
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

from .chord import parse_label
from .provenance import model_metadata

# AAC can decode a partial final frame beyond the recorder's requested limit.
# Retain the measured samples for scoring and hashing, while accepting padding.
DECODE_PADDING_TOLERANCE = 0.05


@dataclass(frozen=True)
class ChordSegment:
    start: float  # seconds
    end: float    # seconds
    label: str    # e.g. "C:maj", "A:min", "N" (no chord)

    def to_dict(self) -> dict:
        # Keep sample-accurate duration: rounding a tiny final interval can
        # make it empty or extend it past the recording's measured end.
        return {"start": self.start, "end": self.end, "label": self.label}


class AudioDecodeError(RuntimeError):
    pass


@dataclass(frozen=True)
class Recognition:
    segments: list[ChordSegment]
    duration: float
    audio_sha256: str
    model: str

    def metadata(self) -> dict:
        return {**model_metadata(self.model), "audio_duration": self.duration,
                "audio_sha256": self.audio_sha256}


def _decode_to_wav(src: Path, dst: Path) -> None:
    proc = subprocess.run(
        ["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", str(src),
         "-vn", "-ac", "1", "-ar", "44100", "-acodec", "pcm_s16le", str(dst)],
        capture_output=True, text=True, timeout=120,
    )
    if proc.returncode != 0:
        raise AudioDecodeError(f"ffmpeg failed to decode {src.name}")


@lru_cache(maxsize=1)
def _processors():
    # Imported lazily: madmom loads model weights at construction time.
    from madmom.features.chords import (
        CNNChordFeatureProcessor,
        CRFChordRecognitionProcessor,
    )
    return CNNChordFeatureProcessor(), CRFChordRecognitionProcessor()

_MADMOM_LOCK = threading.Lock()


def recognize_audio(audio_path: str | Path, model: str = "ismir2019", *,
                    max_duration: float | None = None) -> Recognition:
    """Recognize with explicit capabilities; never silently change models."""
    model_metadata(model)  # Reject an unknown model before processing audio.
    src = Path(audio_path)
    if not src.exists():
        raise FileNotFoundError(src)
    with tempfile.TemporaryDirectory() as tmp:
        wav = Path(tmp) / "audio.wav"
        try:
            _decode_to_wav(src, wav)
        except subprocess.TimeoutExpired as exc:
            raise AudioDecodeError("audio decoding timed out") from exc
        with wave.open(str(wav), "rb") as pcm:
            duration = pcm.getnframes() / pcm.getframerate()
            if duration <= 0:
                raise AudioDecodeError("audio contains no samples")
            if max_duration is not None and duration > max_duration + DECODE_PADDING_TOLERANCE:
                raise AudioDecodeError(f"recording exceeds {max_duration:g} seconds")
            digest = hashlib.sha256()
            while chunk := pcm.readframes(65536):
                digest.update(chunk)
        if model == "ismir2019":
            from .ismir import recognize
            raw = recognize(wav)
        else:
            with _MADMOM_LOCK:
                features, decoder = _processors()
                raw = decoder(features(str(wav)))
    segments = validated_segments(raw, duration)
    return Recognition(segments, duration, digest.hexdigest(), model)


def validated_segments(raw, duration: float) -> list[ChordSegment]:
    """Validate before clipping decoder frame rounding to the true audio end."""
    segments = []
    previous_end = 0.0
    for start, end, label in raw:
        start, end = float(start), float(end)
        if (not math.isfinite(start) or not math.isfinite(end) or start < 0 or end <= start
                or start < previous_end - 1e-6):
            raise ValueError("invalid recognizer segment times")
        previous_end = end
        chord = parse_label(str(label))
        if start < duration:
            segments.append(ChordSegment(start, min(end, duration), chord.label if chord else "N"))
    return merge_adjacent(segments)


def recognize_chords(audio_path: str | Path) -> list[ChordSegment]:
    """Legacy major/minor entry point, retained for previews and comparisons."""
    return recognize_audio(audio_path, model="madmom").segments


def merge_adjacent(segments: list[ChordSegment]) -> list[ChordSegment]:
    """Join touching segments that carry the same label."""
    merged: list[ChordSegment] = []
    for seg in segments:
        if merged and merged[-1].label == seg.label and abs(merged[-1].end - seg.start) < 1e-6:
            merged[-1] = ChordSegment(merged[-1].start, seg.end, seg.label)
        else:
            merged.append(seg)
    return merged
