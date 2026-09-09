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
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import unicodedata

from .lyrics_validation import MAX_WORD_DURATION, mark_unreliable_words, usable_word_indices

WHISPER_MODEL = os.environ.get('CHORDLYZE_WHISPER_MODEL', 'small')
# "groq": hosted whisper-large-v3-turbo, seconds per song, needs GROQ_API_KEY.
# "local": faster-whisper in a subprocess, minutes per song on shared CPUs.
TRANSCRIBER = os.environ.get('CHORDLYZE_TRANSCRIBER', 'local')
GROQ_MODEL = os.environ.get('CHORDLYZE_GROQ_MODEL', 'whisper-large-v3-turbo')
GROQ_URL = os.environ.get('CHORDLYZE_GROQ_URL', 'https://api.groq.com/openai/v1/audio/transcriptions')
ALIGNER = (f'groq-{GROQ_MODEL}+text-match-v1' if TRANSCRIBER == 'groq'
           else f'faster-whisper-{WHISPER_MODEL}+text-match-v1') + '+bounded-word-repair-v2'
MIN_MATCHED_WORDS = 0.5   # share of lyric words found in the transcript
MIN_PLACED_LINES = 0.6    # share of lyric lines that received a time
MIN_TRANSCRIBED_WORDS = 12       # a transcript kept as the lyrics needs this many words
MIN_TRANSCRIBED_CONFIDENCE = 0.5  # and this mean word probability
MAX_TRANSCRIBED_LINE = 9          # words per line when a segment runs long


def reliable_word_times(line: dict) -> bool:
    """Reject broken transcript spans, not lyric text or long musical rests."""
    words = line.get('words') or []
    previous = -1.0
    for word in words:
        start = word.get('time')
        end = word.get('end')
        if not isinstance(start, (float, int)) or not math.isfinite(start) or start < previous:
            return False
        if end is not None and (not isinstance(end, (float, int)) or not math.isfinite(end)
                                or end <= start or end - start > MAX_WORD_DURATION):
            return False
        previous = start
    return True


def mark_estimated_words(lines: list[dict]) -> None:
    """Backfill legacy recording alignments without changing their timestamps.

    Older alignments retained ends only for heard words. Do not classify an
    entirely onset-only source: enhanced LRC also legitimately has no ends.
    Explicit provenance from newer workers always wins.
    """
    if not any(w.get('end') is not None for line in lines for w in line.get('words') or []):
        return
    for line in lines:
        for word in line.get('words') or []:
            if word.get('end') is None and 'estimated' not in word:
                word['estimated'] = True


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


def _uncertain_word(word: dict) -> bool:
    confidence = word.get('p')
    start, end = word.get('start'), word.get('end')
    if end is not None and (not isinstance(end, (int, float)) or not math.isfinite(end)
            or not isinstance(start, (int, float)) or not math.isfinite(start) or end <= start):
        return True
    return word.get('estimated') is True or (confidence is not None and
        (not isinstance(confidence, (int, float)) or not math.isfinite(confidence) or confidence < .5))


MATCH = 2.0        # identical normalized words
NEAR_MATCH = 1.2   # close spelling (transcript slips like "meat" for "meet")
GAP = -0.5         # a lyric word not heard, or a transcript word not in the lyrics
NEAR_RATIO = 0.75


def _similar(a: str, b: str, cache: dict) -> float:
    """Score for pairing lyric word `a` with transcript word `b`."""
    if a == b:
        return MATCH
    if len(a) < 3 or len(b) < 3 or a[0] != b[0] and abs(len(a) - len(b)) > 2:
        return 0.0
    key = (a, b)
    if key not in cache:
        cache[key] = NEAR_MATCH if SequenceMatcher(None, a, b).ratio() >= NEAR_RATIO else 0.0
    return cache[key]


def align_words(a: list[str], b: list[str]) -> list[int | None]:
    """Transcript index for each lyric word, or None, by a global monotonic
    alignment that maximizes match score minus gap costs. A repeated line
    therefore lands on its own occurrence: reaching a later repetition would
    mean skipping every transcript word in between, and each skip costs."""
    n, m = len(a), len(b)
    cache: dict = {}
    score = [[0.0] * (m + 1) for _ in range(n + 1)]
    move = [[0] * (m + 1) for _ in range(n + 1)]  # 1 diagonal, 2 up (skip lyric), 3 left (skip transcript)
    for i in range(1, n + 1):
        score[i][0] = i * GAP
        move[i][0] = 2
    for j in range(1, m + 1):
        score[0][j] = j * GAP
        move[0][j] = 3
    for i in range(1, n + 1):
        row, above = score[i], score[i - 1]
        for j in range(1, m + 1):
            pair = _similar(a[i - 1], b[j - 1], cache)
            best, how = above[j] + GAP, 2
            left = row[j - 1] + GAP
            if left > best:
                best, how = left, 3
            if pair > 0:
                diag = above[j - 1] + pair
                if diag >= best:
                    best, how = diag, 1
            row[j] = best
            move[i][j] = how
    result: list[int | None] = [None] * n
    i, j = n, m
    while i > 0 or j > 0:
        how = move[i][j]
        if how == 1:
            result[i - 1] = j - 1
            i, j = i - 1, j - 1
        elif how == 2:
            i -= 1
        else:
            j -= 1
    return result


def time_lines(lines: list[str], transcript: list[dict]) -> tuple[list[dict], int, int]:
    """Match lyric words to transcript words (in order) and time each line by
    its first word. Unmatched words between matched neighbours are
    interpolated; lines before the first or after the last match are left
    out. Returns (timed lines, matched word count, lyric word count)."""
    lyric = [(index, word) for index, line in enumerate(lines) for word in line.split()]
    spoken = [entry for entry in transcript if _norm(entry['text'])]
    a = [_norm(word) for _, word in lyric]
    b = [_norm(entry['text']) for entry in spoken]
    pairing = align_words(a, b)
    times: list[float | None] = [float(spoken[j]['start']) if j is not None else None for j in pairing]
    # Ends only where a word was actually heard; interpolated words have none.
    ends: list[float | None] = [float(spoken[j]['end']) if j is not None and spoken[j].get('end') is not None else None
                                for j in pairing]
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
        words = []
        for k in positions:
            if times[k] is None:
                continue
            word = {'time': round(times[k], 2), 'text': lyric[k][1]}
            if ends[k] is not None and ends[k] > times[k]:
                word['end'] = round(ends[k], 2)
            else:
                word['estimated'] = pairing[k] is None
            if pairing[k] is not None and _uncertain_word(spoken[pairing[k]]):
                word['estimated'] = True
            words.append(word)
        result.append({'time': round(times[positions[0]], 2), 'text': line, 'words': words})
        last = times[positions[0]]
    return result, matched, len(lyric)



def complete_lyrics(catalog: dict, aligned: list[dict]) -> tuple[list[dict], str | None]:
    """Keep every catalog line, using recording times only for matched text.

    Missing text gets line-level timing, never invented word stamps. Interpolate
    between recording anchors; use their nearest offset at the edges. The note
    makes these estimates explicit. Matching is ordered and occurrence-aware.
    """
    import bisect
    import copy
    source = [line for line in catalog.get('lines', []) if line.get('text', '').strip()]
    if not source:
        return copy.deepcopy(aligned), None
    norm = lambda text: ' '.join(text.split()).casefold()
    a = [norm(line['text']) for line in source]
    b = [norm(line['text']) for line in aligned]
    pairs = {}
    for block in SequenceMatcher(None, a, b, autojunk=False).get_matching_blocks():
        for offset in range(block.size):
            pairs[block.a + offset] = block.b + offset
    # Whisper can stretch an intro word over tens of seconds. Such a line is
    # not an alignment anchor. Recover its line time from a synchronized catalog
    # and nearby consistent recording offsets, without inventing word onsets.
    invalid = {i for i, j in pairs.items() if not reliable_word_times(aligned[j])}
    if invalid:
        from statistics import median
        original_aligned = aligned
        aligned = copy.deepcopy(aligned)
        for i in sorted(invalid):
            line = aligned[pairs[i]]
            if catalog.get('synced'):
                neighbors = sorted((k for k in pairs if k not in invalid and aligned[pairs[k]].get('words')),
                                   key=lambda k: abs(k-i))[:5]
                offsets = [float(aligned[pairs[k]]['time'])-float(source[k]['time']) for k in neighbors]
                offset = median(offsets) if len(offsets) >= 3 else 0.0
                consistent = [x for x in offsets if abs(x-offset) <= 1.0]
                offset = median(consistent) if len(consistent) >= 3 else 0.0
                candidate = round(max(0, float(source[i]['time']) + offset), 3)
                position = pairs[i]
                previous = original_aligned[position - 1] if position else None
                following = original_aligned[position + 1] if position + 1 < len(original_aligned) else None
                lower = float(previous['time']) if previous else -1.0
                if previous:
                    preserved = usable_word_indices(previous, line['time'])
                    lower = max([lower, *[float(previous['words'][k]['time']) for k in preserved]])
                upper = float(following['time']) if following else math.inf
                own_boundary = upper if math.isfinite(upper) else max(w['time'] for w in line['words']) + 1
                own_anchors = usable_word_indices(line, own_boundary)
                first_anchor = min((line['words'][k]['time'] for k in own_anchors), default=math.inf)
                # A catalog repair must not make a healthy neighboring word
                # array fall outside its line, or jump over the next phrase.
                # Retain coarse original timing when these sources conflict;
                # only a recording-backed repair may settle the disagreement.
                if lower < candidate < upper and candidate <= first_anchor:
                    line['time'] = candidate
    # A different catalog edition must not absorb unrelated transcript text.
    if len(pairs) != len(aligned):
        result = copy.deepcopy(source)
        for line in result:
            line.pop('words', None)
        return result, 'Approximate lyric timing: complete catalog text retained.'
    result = [copy.deepcopy(aligned[pairs[i]]) if i in pairs else copy.deepcopy(line)
              for i, line in enumerate(source)]
    mark_estimated_words(result)
    anchors = sorted(pairs)
    for i, line in enumerate(result):
        if i in pairs:
            # Partial word arrays must never hide words still present in line text.
            words = line.get('words') or []
            if words and norm(' '.join(w['text'] for w in words)) != norm(line['text']):
                line.pop('words', None)
            continue
        line.pop('words', None)
        k = bisect.bisect_left(anchors, i)
        before = anchors[k-1] if k else None
        after = anchors[k] if k < len(anchors) else None
        t = float(source[i]['time'])
        if before is not None and after is not None:
            ca, cb = float(source[before]['time']), float(source[after]['time'])
            share = (t-ca)/(cb-ca) if cb > ca else (i-before)/(after-before)
            t = result[before]['time'] + share*(result[after]['time']-result[before]['time'])
        elif before is not None:
            t += result[before]['time'] - float(source[before]['time'])
        elif after is not None:
            t += result[after]['time'] - float(source[after]['time'])
        line['time'] = round(max(0, t), 3)
    # Conflicting anchors cannot provide a safe mixed timeline. Preserve the
    # complete catalog instead, rather than dropping or reordering its text.
    if any(x['time'] >= y['time'] for x, y in zip(result, result[1:])):
        result = copy.deepcopy(source)
        for line in result:
            line.pop('words', None)
        return result, 'Approximate lyric timing: complete catalog text retained.'
    # Preserve malformed stamps as evidence and retain the usable subset.
    # Removing the whole word array hid healthy anchors and made audits look
    # repaired even though only a coarse catalog onset had been substituted.
    mark_unreliable_words(result, None)
    approximate = len(pairs) != len(source) or any(not line.get('words') or
        any(w.get('estimated') for w in line['words']) for line in result)
    return result, 'Some lyric timing is approximate; all catalog lines are included.' if approximate else None


def transcribe_words(audio: Path, language: str | None) -> list[dict]:
    """Word-timed transcript: [{'start', 'text', 'p', 'segment'}, ...] from the
    configured transcriber."""
    if TRANSCRIBER == 'groq':
        words = transcribe_words_groq(audio, language)
    elif TRANSCRIBER == 'local':
        words = transcribe_words_local(audio, language)
    else:
        raise AlignmentUnavailable(f'unknown transcriber {TRANSCRIBER!r}')
    # The bundled local model retries only malformed spans. It does not make
    # another paid provider request or hold the model in the song worker.
    from .lyrics_timing import repair_word_spans
    return repair_word_spans(audio, words,
        lambda crop, hint: transcribe_words_local(crop, hint, timeout=120), language)


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
        if entry.get('end') is not None and float(entry['end']) > start:
            word['end'] = float(entry['end'])
        if segment is not None and segment.get('avg_logprob') is not None:
            word['p'] = round(math.exp(float(segment['avg_logprob'])), 3)
        words.append(word)
    return words


def transcribe_words_local(audio: Path, language: str | None, *, timeout: float = 1800) -> list[dict]:
    """Word-timed transcript from a separate process, so the speech model's
    memory is released before the next song."""
    command = [sys.executable, '-m', 'chordlyze_backend.lyrics_align_worker', str(audio)]
    if language:
        command.append(language)
    env = {**os.environ, 'PYTHONPATH': os.pathsep.join(filter(None, [
        str(Path(__file__).resolve().parents[1]), os.environ.get('PYTHONPATH')]))}
    # Lowest priority: chord charts in progress must not wait for a transcript.
    completed = subprocess.run(command, capture_output=True, text=True, timeout=timeout, env=env,
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
        entry = {'time': round(float(word['start']), 2), 'text': word['text']}
        if word.get('end') is not None and float(word['end']) > float(word['start']):
            entry['end'] = round(float(word['end']), 2)
        if _uncertain_word(word):
            entry['estimated'] = True
        group.append(entry)
    flush()
    return lines


def transcribe_lyrics(audio: Path, transcribe=transcribe_words) -> list[dict] | None:
    """Lyrics for a song without any catalog text: the transcript, or None."""
    return transcribed_lines(transcribe(audio, None))
