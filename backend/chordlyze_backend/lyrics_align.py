"""Line and word times for plain lyrics, from the analyzed recording.

Catalog lyrics without timestamps used to be spread evenly across the song,
which put every line tens of seconds off. Instead the worker transcribes the
recording with word timestamps and matches the known lyric text to it, so
lines land where they are actually sung. Instrumental intros, breaks and
outros produce no transcript words and therefore no misplaced lines.
"""
from __future__ import annotations

from difflib import SequenceMatcher
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import unicodedata

WHISPER_MODEL = os.environ.get('CHORDLYZE_WHISPER_MODEL', 'small')
ALIGNER = f'faster-whisper-{WHISPER_MODEL}+text-match-v1'
MIN_MATCHED_WORDS = 0.5   # share of lyric words found in the transcript
MIN_PLACED_LINES = 0.6    # share of lyric lines that received a time


class AlignmentUnavailable(RuntimeError):
    pass


def language_hint(lines: list[str]) -> str | None:
    """Script-based hint for the transcriber; None lets it detect the language."""
    text = ' '.join(lines)
    if re.search(r'[֐-׿]', text):
        return 'he'
    if re.search(r'[؀-ۿ]', text):
        return 'ar'
    return None


def _norm(word: str) -> str:
    word = unicodedata.normalize('NFKC', word).casefold()
    return re.sub(r"[^\w']+", '', word).replace("'", '')


def time_lines(lines: list[str], transcript: list[dict]) -> tuple[list[dict], int, int]:
    """Match lyric words to transcript words (in order) and time each line by
    its first word. Unmatched words between matched neighbours are
    interpolated; lines before the first or after the last match are left
    out. Returns (timed lines, matched word count, lyric word count)."""
    lyric = [(index, word) for index, line in enumerate(lines) for word in line.split()]
    spoken = [entry for entry in transcript if _norm(entry['text'])]
    a = [_norm(word) for _, word in lyric]
    b = [_norm(entry['text']) for entry in spoken]
    times: list[float | None] = [None] * len(lyric)
    for tag, i1, i2, j1, j2 in SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if tag == 'equal':
            for offset in range(i2 - i1):
                times[i1 + offset] = float(spoken[j1 + offset]['start'])
    matched = sum(time is not None for time in times)
    known = [index for index, time in enumerate(times) if time is not None]
    for index in range(len(times)):
        if times[index] is not None:
            continue
        before = max((k for k in known if k < index), default=None)
        after = min((k for k in known if k > index), default=None)
        if before is None or after is None:
            continue
        times[index] = times[before] + (times[after] - times[before]) * (index - before) / (after - before)
    result: list[dict] = []
    last = -1.0
    for index, line in enumerate(lines):
        positions = [k for k, (line_index, _) in enumerate(lyric) if line_index == index]
        if not positions or times[positions[0]] is None or times[positions[0]] < last:
            continue
        words = [{'time': round(times[k], 2), 'text': lyric[k][1]} for k in positions if times[k] is not None]
        result.append({'time': round(times[positions[0]], 2), 'text': line, 'words': words})
        last = times[positions[0]]
    return result, matched, len(lyric)


def transcribe_words(audio: Path, language: str | None) -> list[dict]:
    """Word-timed transcript from a separate process, so the speech model's
    memory is released before the next song."""
    command = [sys.executable, '-m', 'chordlyze_backend.lyrics_align_worker', str(audio)]
    if language:
        command.append(language)
    env = {**os.environ, 'PYTHONPATH': os.pathsep.join(filter(None, [
        str(Path(__file__).resolve().parents[1]), os.environ.get('PYTHONPATH')]))}
    # Lowest priority: chord charts in progress must not wait for a transcript.
    completed = subprocess.run(command, capture_output=True, text=True, timeout=1800, env=env,
                               preexec_fn=lambda: os.nice(15))
    if completed.returncode != 0:
        # The transcript process prints no lyrics or track metadata on failure.
        raise AlignmentUnavailable(f'transcription failed: {completed.stderr.strip()[-300:]}')
    words = json.loads(completed.stdout)
    if not isinstance(words, list):
        raise AlignmentUnavailable('invalid transcript')
    return words


def align_lyrics(audio: Path, lines: list[str], transcribe=transcribe_words,
                 stats: dict | None = None) -> list[dict] | None:
    """Timed lines for the given plain lyrics, or None when too little of the
    text was found in the recording to trust the result. `stats` receives
    the match counts (numbers only, safe to log)."""
    lines = [line.strip() for line in lines if line.strip()]
    if not lines:
        return None
    words = transcribe(audio, language_hint(lines))
    timed, matched, total = time_lines(lines, words)
    if stats is not None:
        stats.update(matched_words=matched, lyric_words=total, transcript_words=len(words),
                     placed_lines=len(timed), lines=len(lines))
    if total == 0 or matched < MIN_MATCHED_WORDS * total or len(timed) < MIN_PLACED_LINES * len(lines):
        return None
    return timed
