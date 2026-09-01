"""Forced alignment of lyric lines to audio via whisper word timestamps.

Transcribes the song (faster-whisper tiny, int8, CPU) and matches each lyric
line to the transcript with a monotonic fuzzy search, yielding real line
start times. Quality-gated: returns None when the match is too poor
(instrument-heavy mixes can defeat the tiny model).
"""
from __future__ import annotations

import os
import re
import threading
from difflib import SequenceMatcher
from functools import lru_cache
from pathlib import Path

_WORD_RE = re.compile(r"[\w']+", re.UNICODE)
# One transcription at a time — CPU-bound and memory-heavy.
_MODEL_LOCK = threading.Lock()


def _norm_words(text: str) -> list[str]:
    return [w.lower() for w in _WORD_RE.findall(text)]


@lru_cache(maxsize=1)
def _model():
    from faster_whisper import WhisperModel
    os.environ.setdefault("HF_HOME", "/data/hf")
    return WhisperModel("tiny", device="cpu", compute_type="int8")


def transcribe_words(audio_path: str | Path) -> list[tuple[float, str]]:
    """[(start_seconds, normalized_word), ...] for the whole file."""
    with _MODEL_LOCK:
        segments, _ = _model().transcribe(str(audio_path), word_timestamps=True,
                                          vad_filter=True)
        words: list[tuple[float, str]] = []
        for seg in segments:
            for w in seg.words or []:
                for token in _norm_words(w.word):
                    words.append((float(w.start), token))
    return words


def match_lines(transcript: list[tuple[float, str]],
                line_texts: list[str]) -> list[dict] | None:
    """Monotonically match lyric lines against transcript words.

    Returns [{time, text}] or None when overall quality is too low.
    """
    if not transcript or not line_texts:
        return None
    tokens = [w for _, w in transcript]
    times = [t for t, _ in transcript]

    results: list[dict] = []
    ratios: list[float] = []
    pointer = 0
    for text in line_texts:
        target = _norm_words(text)
        if not target:
            continue
        window = len(target)
        best_ratio, best_at = 0.0, None
        # Search forward from the current position only (lyrics are ordered).
        for start in range(pointer, min(len(tokens) - 1, pointer + 120)):
            cand = tokens[start:start + window]
            ratio = SequenceMatcher(None, " ".join(cand), " ".join(target)).ratio()
            if ratio > best_ratio:
                best_ratio, best_at = ratio, start
                if ratio > 0.9:
                    break
        if best_at is not None and best_ratio >= 0.4:
            results.append({"time": round(times[best_at], 2), "text": text})
            pointer = best_at + max(1, window // 2)
            ratios.append(best_ratio)
        else:
            results.append({"time": -1.0, "text": text})  # interpolate later
            ratios.append(0.0)

    matched = [r for r in results if r["time"] >= 0]
    if len(matched) < max(3, len(results) // 3) or \
            sum(ratios) / len(ratios) < 0.45:
        return None

    # Interpolate unmatched lines between their matched neighbors.
    for i, row in enumerate(results):
        if row["time"] >= 0:
            continue
        prev_t = next((results[j]["time"] for j in range(i - 1, -1, -1)
                       if results[j]["time"] >= 0), matched[0]["time"])
        next_t = next((results[j]["time"] for j in range(i + 1, len(results))
                       if results[j]["time"] >= 0), matched[-1]["time"] + 10)
        row["time"] = round(prev_t + (next_t - prev_t) / 2, 2)

    # Enforce strictly increasing times.
    for i in range(1, len(results)):
        if results[i]["time"] <= results[i - 1]["time"]:
            results[i]["time"] = round(results[i - 1]["time"] + 0.5, 2)
    return results


def align(audio_path: str | Path, line_texts: list[str]) -> list[dict] | None:
    """Full pipeline: transcribe then match. None when alignment is unusable."""
    try:
        transcript = transcribe_words(audio_path)
    except Exception:
        return None
    return match_lines(transcript, line_texts)
