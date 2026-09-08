"""Recover malformed transcript spans from bounded crops of the same audio.

Only acoustic timestamps with matching text and agreeing surrounding anchors
are accepted. Ordinary transcripts do not trigger another transcription.
"""
from __future__ import annotations

import copy
import math
from pathlib import Path
import subprocess
import tempfile

from .lyrics_align import MAX_TRANSCRIBED_LINE, MAX_WORD_DURATION, _norm

MAX_REPAIR_CROPS = 3
MAX_CROP_DURATION = 30.0
ANCHOR_TOLERANCE = 0.75


def _number(value) -> bool:
    return isinstance(value, (int, float)) and math.isfinite(value)


def _span(word: dict) -> bool:
    start, end = word.get('start'), word.get('end')
    return (_number(start) and _number(end) and start >= 0
            and 0 < end - start <= MAX_WORD_DURATION)


def _crop(audio: Path, output: Path, start: float, end: float) -> None:
    completed = subprocess.run(
        ['ffmpeg', '-y', '-loglevel', 'error', '-ss', str(start), '-i', str(audio),
         '-t', str(end - start), '-vn', '-ac', '1', '-ar', '16000', str(output)],
        capture_output=True, timeout=45)
    if completed.returncode or not output.exists():
        raise RuntimeError('Could not prepare the lyric timing crop')


def repair_word_spans(audio: Path, words: list[dict], transcribe, language: str | None = None,
                      *, stats: dict | None = None) -> list[dict]:
    """Retry at most three damaged phrases, preserving text and other phrases.

    A long word can absorb an instrumental intro, including the word before
    it. Re-transcribe its whole phrase after removing most of that span. The
    crop must contain the exact phrase once and retain at least two reliable
    subsequent anchors. Missing, repeated or conflicting text is not guessed.
    Failure leaves the original available for catalog repair or coarse display.
    """
    result = copy.deepcopy(words)
    groups: list[tuple[int, int]] = []
    lo = 0
    for i in range(1, len(words) + 1):
        if i == len(words) or i - lo >= MAX_TRANSCRIBED_LINE or words[i].get('segment') != words[lo].get('segment'):
            groups.append((lo, i))
            lo = i
    attempted = repaired = 0
    for lo, hi in groups:
        group = words[lo:hi]
        bad = [i for i, word in enumerate(group)
               if _number(word.get('start')) and _number(word.get('end'))
               and word['end'] - word['start'] > MAX_WORD_DURATION]
        if not bad or attempted >= MAX_REPAIR_CROPS:
            continue
        if not all(_number(w.get('start')) and _number(w.get('end')) for w in group):
            continue
        anchors = [i for i in range(bad[-1] + 1, len(group)) if _span(group[i])]
        if len(anchors) < 2:
            continue
        start = max(0.0, group[0]['start'], group[bad[-1]]['end'] - MAX_WORD_DURATION)
        end = max(w['end'] for w in group) + 1.0
        if not 0 < end - start <= MAX_CROP_DURATION:
            continue
        attempted += 1
        try:
            with tempfile.TemporaryDirectory(prefix='chordlyze-lyric-timing-') as temporary:
                crop = Path(temporary) / 'phrase.wav'
                _crop(audio, crop, start, end)
                candidate = transcribe(crop, language)
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
            continue
        candidate = [w for w in candidate if _norm(w.get('text', ''))]
        expected = [_norm(w.get('text', '')) for w in group]
        actual = [_norm(w.get('text', '')) for w in candidate]
        matches = [i for i in range(len(candidate) - len(group) + 1)
                   if actual[i:i + len(group)] == expected]
        if len(matches) != 1 or not all(expected):
            continue
        found = candidate[matches[0]:matches[0] + len(group)]
        if not all(_span(w) and w['end'] <= end - start + 0.05 for w in found):
            continue
        if any(a['start'] >= b['start'] for a, b in zip(found, found[1:])):
            continue
        # A word pinned to the new clip boundary is still not a recovered onset.
        if start > group[0]['start'] and found[0]['start'] <= 0.1:
            continue
        confidence = [w['p'] for w in found if _number(w.get('p'))]
        if confidence and sum(confidence) / len(confidence) < 0.5:
            continue
        agreeing = [i for i in anchors
                    if abs(start + found[i]['start'] - group[i]['start']) <= ANCHOR_TOLERANCE
                    and abs(start + found[i]['end'] - group[i]['end']) <= ANCHOR_TOLERANCE]
        if len(agreeing) < max(2, math.ceil(len(anchors) * 0.75)):
            continue
        # The reliable suffix is evidence for accepting the recovery, not
        # permission to retime healthy words. Preserve those stamps exactly.
        updated = [{**original, 'start': round(start + heard['start'], 3),
                    'end': round(start + heard['end'], 3)} if i <= bad[-1] else copy.deepcopy(original)
                   for i, (original, heard) in enumerate(zip(group, found))]
        if any(a['start'] >= b['start'] for a, b in zip(updated, updated[1:])):
            continue
        if updated[bad[-1]]['end'] > updated[bad[-1] + 1]['start'] + 0.35:
            continue
        if lo and (not _number(result[lo - 1].get('start')) or updated[0]['start'] <= result[lo - 1]['start']):
            continue
        if hi < len(words) and (not _number(words[hi].get('start')) or updated[-1]['end'] > words[hi]['start']):
            continue
        result[lo:hi] = updated
        repaired += 1
    if stats is not None:
        stats.update(attempted_crops=attempted, repaired_phrases=repaired)
    return result


def repair_entry_from_audio(entry: dict, audio: Path, transcribe, *, stats: dict | None = None) -> dict | None:
    """Repair an existing chart only against its exact decoded recording.

    Decode with the same helper as chord analysis. Hash the PCM, not the
    container bytes; another edit/encoding cannot silently retime this chart.
    This function returns a copy and never writes to the shared cache.
    """
    import hashlib
    import wave
    from .analysis.engine import _decode_to_wav

    lyrics = entry.get('lyrics') or {}
    if lyrics.get('matched') not in ('aligned', 'transcribed'):
        return None
    lines = lyrics.get('lines') or []
    words = [{**w, 'start': w['time'], 'segment': i}
             for i, line in enumerate(lines) for w in line.get('words') or []]
    if not any(_number(w.get('end')) and _number(w.get('start'))
               and w['end'] - w['start'] > MAX_WORD_DURATION for w in words):
        return None
    if not entry.get('audio_sha256'):
        raise ValueError('A verified recording identity is required')
    with tempfile.TemporaryDirectory(prefix='chordlyze-lyric-identity-') as temporary:
        decoded = Path(temporary) / 'recording.wav'
        _decode_to_wav(audio, decoded)
        with wave.open(str(decoded), 'rb') as pcm:
            digest = hashlib.sha256()
            while chunk := pcm.readframes(65536):
                digest.update(chunk)
        if digest.hexdigest() != entry['audio_sha256']:
            raise ValueError('Recording identity does not match the analyzed audio')
        repaired = repair_word_spans(decoded, words, transcribe, stats=stats)
    if repaired == words:
        return None
    updated = copy.deepcopy(entry)
    cursor = 0
    for original, line in zip(lines, updated['lyrics']['lines']):
        for word in line.get('words') or []:
            heard = repaired[cursor]
            if heard != words[cursor]:
                word.update(time=heard['start'], end=heard['end'])
                word.pop('estimated', None)
            cursor += 1
        if line.get('words') and line['words'][0]['time'] != original['words'][0]['time']:
            line['time'] = line['words'][0]['time']
    if any(a['time'] >= b['time'] for a, b in zip(updated['lyrics']['lines'], updated['lyrics']['lines'][1:])):
        return None
    updated['lyrics']['word_timing_version'] = 1
    return updated
