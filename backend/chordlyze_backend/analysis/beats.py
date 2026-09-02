"""Beat tracking for the practice metronome.

librosa's onset-strength + dynamic-programming beat tracker: fast, no model
weights, good enough for a click track. Times share the chord timeline
(seconds from the start of the analyzed audio, excerpt or full song).
"""
from __future__ import annotations

from pathlib import Path


def track_beats(audio_path: str | Path) -> dict | None:
    """{"bpm": float, "beats": [seconds]} or None when no beat is found."""
    import librosa
    import numpy as np

    y, sr = librosa.load(str(audio_path), sr=22050, mono=True)
    if y.size == 0:
        return None
    tempo, beats = librosa.beat.beat_track(y=y, sr=sr, units="time")
    bpm = float(np.atleast_1d(tempo)[0])
    if bpm <= 0 or len(beats) < 2:
        return None
    return {"bpm": round(bpm, 1), "beats": [round(float(b), 3) for b in beats]}
