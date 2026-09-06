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
# "groq": hosted whisper-large-v3-turbo, seconds per song, needs GROQ_API_KEY.
# "local": faster-whisper in a subprocess, minutes per song on shared CPUs.
TRANSCRIBER = os.environ.get('CHORDLYZE_TRANSCRIBER', 'local')
GROQ_MODEL = os.environ.get('CHORDLYZE_GROQ_MODEL', 'whisper-large-v3-turbo')
GROQ_URL = os.environ.get('CHORDLYZE_GROQ_URL', 'https://api.groq.com/openai/v1/audio/transcriptions')
ALIGNER = (f'groq-{GROQ_MODEL}+text-match-v1' if TRANSCRIBER == 'groq'
           else f'faster-whisper-{WHISPER_MODEL}+text-match-v1')
MIN_MATCHED_WORDS = 0.5   # share of lyric words found in the transcript
MIN_PLACED_LINES = 0.6    # share of lyric lines that received a time
MIN_TRANSCRIBED_WORDS = 12       # a transcript kept as the lyrics needs this many words
MIN_TRANSCRIBED_CONFIDENCE = 0.5  # and this mean word probability
MAX_TRANSCRIBED_LINE = 9          # words per line when a segment runs long


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
    """Word-timed transcript: [{'start', 'text', 'p', 'segment'}, ...] from the
    configured transcriber."""
    if TRANSCRIBER == 'groq':
        return transcribe_words_groq(audio, language)
    if TRANSCRIBER != 'local':
        raise AlignmentUnavailable(f'unknown transcriber {TRANSCRIBER!r}')
    return transcribe_words_local(audio, language)


def _compact_audio(audio: Path) -> Path:
    """16 kHz mono at a low bitrate: what a speech model wants, a few MB to
    upload instead of a full-quality download."""
    compact = audio.with_name(audio.stem + '-speech.mp3')
    completed = subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', str(audio), '-vn', '-ac', '1',
                                '-ar', '16000', '-b:a', '48k', str(compact)], capture_output=True, text=True, timeout=300)
    if completed.returncode != 0 or not compact.exists():
        raise AlignmentUnavailable(f'audio conversion failed: {completed.stderr.strip()[-200:]}')
    return compact


def transcribe_words_groq(audio: Path, language: str | None, post=None, sleep=None) -> list[dict]:
    """Hosted transcription. Word times come from the response's words; each
    word's confidence is its segment's average log probability, exponentiated,
    which is what the local path reports too. A rate limit is waited out once
    or twice, then reported."""
    import math
    import time as clock

    import requests

    key = os.environ.get('GROQ_API_KEY')
    if not key:
        raise AlignmentUnavailable('GROQ_API_KEY is not configured')
    post = post or requests.post
    sleep = sleep or clock.sleep
    compact = _compact_audio(audio)
    try:
        data = [('model', GROQ_MODEL), ('response_format', 'verbose_json'),
                ('timestamp_granularities[]', 'word'), ('timestamp_granularities[]', 'segment')]
        if language:
            data.append(('language', language))
        for attempt in range(3):
            with compact.open('rb') as handle:
                response = post(GROQ_URL, headers={'Authorization': 'Bearer ' + key}, data=data,
                                files={'file': (compact.name, handle, 'audio/mpeg')}, timeout=(10, 180))
            if response.status_code == 429 and attempt < 2:
                sleep(float(response.headers.get('Retry-After') or 15))
                continue
            break
    finally:
        compact.unlink(missing_ok=True)
    if response.status_code in (401, 403):
        raise AlignmentUnavailable('transcriber rejected the API key')
    if response.status_code != 200:
        raise AlignmentUnavailable(f'transcriber returned {response.status_code}')
    body = response.json()
    segments = body.get('segments') or []
    words: list[dict] = []
    for entry in body.get('words') or []:
        start = float(entry['start'])
        segment = next((seg for seg in segments if float(seg.get('start', 0)) - 0.01 <= start <= float(seg.get('end', 1e9)) + 0.01), None)
        word = {'start': start, 'text': str(entry.get('word', '')).strip(),
                'segment': int(segment['id']) if segment and 'id' in segment else None}
        if segment is not None and segment.get('avg_logprob') is not None:
            word['p'] = round(math.exp(float(segment['avg_logprob'])), 3)
        words.append(word)
    return words


def transcribe_words_local(audio: Path, language: str | None) -> list[dict]:
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


def transcribed_lines(words: list[dict]) -> list[dict] | None:
    """Lines made from the transcript itself, for songs no catalog has. One
    line per transcript segment, long segments split. None when the
    transcript is too short or too unsure to show as lyrics."""
    words = [word for word in words if word.get('text')]
    if len(words) < MIN_TRANSCRIBED_WORDS:
        return None
    confidences = [float(word['p']) for word in words if 'p' in word]
    if confidences and sum(confidences) / len(confidences) < MIN_TRANSCRIBED_CONFIDENCE:
        return None
    lines: list[dict] = []
    group: list[dict] = []
    current = None

    def flush() -> None:
        if group:
            lines.append({'time': group[0]['time'], 'text': ' '.join(w['text'] for w in group), 'words': list(group)})
            group.clear()

    for word in words:
        segment = word.get('segment')
        if group and (segment != current or len(group) >= MAX_TRANSCRIBED_LINE):
            flush()
        current = segment
        group.append({'time': round(float(word['start']), 2), 'text': word['text']})
    flush()
    return lines


def transcribe_lyrics(audio: Path, transcribe=transcribe_words) -> list[dict] | None:
    """Lyrics for a song without any catalog text: the transcript, or None."""
    return transcribed_lines(transcribe(audio, None))
