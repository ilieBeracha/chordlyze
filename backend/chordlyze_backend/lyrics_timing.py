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

from .lyrics_align import MAX_TRANSCRIBED_LINE, MAX_WORD_DURATION, _norm, align_words
from .lyrics_validation import finite, mark_unreliable_words, usable_word_indices

MAX_REPAIR_CROPS = 3
MAX_CROP_DURATION = 30.0
ANCHOR_TOLERANCE = 0.75


def _number(value) -> bool:
    return finite(value)


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


def _boundary(lines: list[dict], index: int, duration: float) -> float:
    return min(lines[index + 1]['time'], duration) if index + 1 < len(lines) else duration


def accept_line_recovery(lines: list[dict], index: int, duration: float,
                         candidate: list[dict], *, diagnostics: dict | None = None) -> list[dict] | None:
    """Accept recognized words in recording coordinates, never forced text.

    Require a unique phrase, or uniquely recognized damaged words bracketed
    by agreeing measured anchors. At least two anchors must corroborate the
    occurrence. Only damaged stamps change; a missing healthy word in the
    new recognition cannot erase that word's existing evidence.
    """
    def decline(reason):
        if diagnostics is not None:
            diagnostics['reason'] = reason
        return None
    original = lines[index]
    words = original.get('words') or []
    expected = [_norm(w.get('text', '')) for w in words]
    if not words or expected != [_norm(w) for w in original.get('text', '').split()] or not all(expected):
        return decline('incomplete_source_text')
    usable = set(usable_word_indices(original, _boundary(lines, index, duration)))
    damaged = set(range(len(words))) - usable
    if not damaged:
        return decline('no_damaged_words')
    candidate = [w for w in candidate if _norm(w.get('text', ''))]
    actual = [_norm(w['text']) for w in candidate]
    matches = [i for i in range(len(actual) - len(expected) + 1)
               if actual[i:i + len(expected)] == expected]
    if len(matches) > 1:
        return decline('phrase_not_uniquely_recognized')

    # Match context in sequence so repeated words cannot each claim the same
    # recognized anchor. Estimated catalog stamps are never corroboration.
    context, anchors, target_offset = [], [], 0
    for neighbor in range(max(0, index - 1), min(len(lines), index + 2)):
        line = lines[neighbor]
        if neighbor == index:
            target_offset = len(context)
        valid = set(usable_word_indices(line, _boundary(lines, neighbor, duration)))
        for position, word in enumerate(line.get('words') or []):
            if position in valid and word.get('estimated') is not True and word.get('end') is not None:
                anchors.append((len(context), word))
            context.append(_norm(word.get('text', '')))
    pairing = align_words(context, actual)
    observed = [(position, word, candidate[pairing[position]]) for position, word in anchors
                if pairing[position] is not None and context[position] == actual[pairing[position]]]
    agreeing = [(position, word, heard) for position, word, heard in observed if _span(heard)
                and finite(heard.get('p')) and heard['p'] >= .5
                and abs(word['time'] - heard['start']) <= ANCHOR_TOLERANCE
                and abs(word['end'] - heard['end']) <= ANCHOR_TOLERANCE]
    if len(agreeing) < max(2, math.ceil(len(observed) * .75)):
        return decline('insufficient_agreeing_anchors')
    if matches:
        found = candidate[matches[0]:matches[0] + len(words)]
    else:
        found = [candidate[pairing[target_offset + i]] if pairing[target_offset + i] is not None
                 and expected[i] == actual[pairing[target_offset + i]] else None for i in range(len(words))]
        for position in damaged:
            heard = found[position]
            if heard is None or not finite(heard.get('p')) or heard['p'] < .5:
                return decline('damaged_word_not_confidently_recognized')
            before = [p for p, _, _ in agreeing if p < target_offset + position]
            after = [p for p, _, _ in agreeing if p > target_offset + position]
            if not before or not after:
                return decline('partial_phrase_missing_bracketing_anchors')
            left, right = pairing[max(before)], pairing[min(after)]
            choices = [i for i in range(left + 1, right) if actual[i] == expected[position]]
            if choices != [pairing[target_offset + position]]:
                return decline('ambiguous_word_between_anchors')
    observed_target = [w for w in found if w is not None]
    if (not all(_span(w) and w['end'] <= duration and finite(w.get('p')) and w['p'] >= .15 for w in observed_target)
            or sum(w['p'] for w in observed_target) / len(observed_target) < .5
            or any(a['start'] > b['start'] for a, b in zip(observed_target, observed_target[1:]))):
        return decline('unreliable_recognition')
    # Every retained anchor in the target phrase must agree, including one
    # surrounded by damaged words. Agreement elsewhere cannot outvote it.
    if any(found[i] is not None and words[i].get('estimated') is not True and
           (abs(words[i]['time'] - found[i]['start']) > ANCHOR_TOLERANCE or
            (words[i].get('end') is not None and abs(words[i]['end'] - found[i]['end']) > ANCHOR_TOLERANCE))
           for i in usable):
        return decline('retained_anchor_disagreement')

    result = copy.deepcopy(lines)
    line = result[index]
    for position in damaged:
        word, heard = line['words'][position], found[position]
        word.update(time=round(heard['start'], 3), end=round(heard['end'], 3))
        word.pop('estimated', None)
    if 0 in damaged:
        line['time'] = line['words'][0]['time']
    if len(usable_word_indices(line, _boundary(result, index, duration))) != len(words):
        return decline('recovery_still_has_invalid_geometry')
    if index:
        previous = result[index - 1]
        if line['time'] <= previous['time']:
            return decline('preceding_line_conflict')
        before = set(usable_word_indices(lines[index - 1], original['time']))
        after = set(usable_word_indices(previous, line['time']))
        if not before <= after:
            return decline('preceding_anchor_conflict')
    if diagnostics is not None:
        diagnostics.update(reason='accepted', repaired_words=len(damaged), agreeing_anchors=len(agreeing))
    return result


def recovery_window(lines: list[dict], index: int, duration: float) -> tuple[float, float] | None:
    """Bound one recognition crop to this phrase and nearby context."""
    onset, boundary = lines[index]['time'], _boundary(lines, index, duration)
    if not finite(onset) or not finite(boundary) or boundary <= onset:
        return None
    start = max(0, onset - 2)
    end = min(duration, boundary + 3)
    if index and onset - lines[index - 1]['time'] < 8:
        start = max(0, lines[index - 1]['time'] - .5)
    if index + 1 < len(lines):
        following = lines[index + 1].get('words') or []
        ends = [w['end'] for w in following[:3] if finite(w.get('end'))]
        if ends:
            end = min(duration, max(end, max(ends) + .5))
    if end - start > MAX_CROP_DURATION:
        # Never seek to a suspicious word's far-away end: that could select
        # another chorus. The specialized intro retry handles long prefixes.
        end = min(end, start + MAX_CROP_DURATION)
    return (start, end) if end > start else None


def accept_phrase_recovery(lines: list[dict], index: int, duration: float,
                           candidate: list[dict], *, diagnostics: dict | None = None) -> list[dict] | None:
    accepted = accept_line_recovery(lines, index, duration, candidate, diagnostics=diagnostics)
    if accepted is not None or index + 1 >= len(lines):
        return accepted
    first, second = lines[index:index + 2]
    a, b = first.get('words') or [], second.get('words') or []
    if not a or not b or not all(_span({**w, 'start': w.get('time')}) for w in a + b):
        return None
    # A small cross-boundary inversion implicates words on both sides, just
    # like an inversion inside one line. A distant mismatched chorus must not
    # make a healthy adjoining phrase eligible for retiming.
    crossing = [w['time'] for w in a if w['time'] >= second['time']]
    if not crossing or max(crossing) - second['time'] > ANCHOR_TOLERANCE or b[0]['time'] != second['time']:
        return None
    combined = {'time': first['time'], 'text': first['text'] + ' ' + second['text'], 'words': a + b}
    packed = lines[:index] + [combined] + lines[index + 2:]
    fixed = accept_line_recovery(packed, index, duration, candidate)
    if fixed is None:
        return None
    heard = fixed[index]['words']
    result = copy.deepcopy(lines)
    result[index]['words'], result[index + 1]['words'] = heard[:len(a)], heard[len(a):]
    result[index]['time'] = fixed[index]['time']
    if heard[len(a)]['time'] != b[0]['time']:
        result[index + 1]['time'] = heard[len(a)]['time']
    for position in (index, index + 1):
        line = result[position]
        if len(usable_word_indices(line, _boundary(result, position, duration))) != len(line['words']):
            return None
    if diagnostics is not None:
        diagnostics.update(reason='accepted_boundary_pair', repaired_words=sum(
            (old['time'], old.get('end')) != (new['time'], new.get('end')) for old, new in zip(a + b, heard)))
    return result


def repair_line_timings(audio: Path, lines: list[dict], duration: float, transcribe,
                        language: str | None = None, *, max_crops: int = MAX_REPAIR_CROPS,
                        stats: dict | None = None) -> list[dict]:
    result = copy.deepcopy(lines)
    attempted = repaired = 0
    for index in range(len(result)):
        line = result[index]
        if (attempted >= max_crops or not line.get('words') or
                len(usable_word_indices(line, _boundary(result, index, duration))) == len(line['words'])):
            continue
        window = recovery_window(result, index, duration)
        if window is None:
            continue
        start, end = window
        attempted += 1
        try:
            with tempfile.TemporaryDirectory(prefix='chordlyze-lyric-boundary-') as temporary:
                crop = Path(temporary) / 'phrase.wav'
                _crop(audio, crop, start, end)
                heard = transcribe(crop, language)
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
            continue
        # Crop-relative times must themselves fit the crop before translation.
        candidate = [{**w, 'start': start + w['start'], 'end': start + w['end']}
                     for w in heard if _span(w) and w['end'] <= end - start]
        accepted = accept_phrase_recovery(result, index, duration, candidate)
        if accepted is not None:
            repaired += sum(a != b for a, b in zip(result, accepted))
            result = accepted
    if stats is not None:
        stats.update(attempted_crops=attempted, repaired_phrases=repaired)
    return result


def finalize_line_timings(audio: Path, lines: list[dict], duration: float | None,
                          transcribe=None) -> tuple[list[dict], dict | None]:
    """Apply the same contract to both worker sources, before publication.

    The existing bundled model handles the optional bounded retry. Unresolved
    timing retains its evidence and is marked approximate, including on the
    first response to older clients. A missing local file cannot erase lyrics.
    """
    result = copy.deepcopy(lines)
    if audio.exists():
        try:
            import soundfile as sf
            measured_duration = sf.info(str(audio)).duration
            if finite(measured_duration) and measured_duration > 0:
                duration = measured_duration
        except (OSError, RuntimeError):
            pass
        if finite(duration) and duration > 0:
            if transcribe is None:
                from .lyrics_align import transcribe_words_local
                transcribe = lambda crop, hint: transcribe_words_local(crop, hint, timeout=120)
            from .lyrics_align import language_hint
            result = repair_line_timings(audio, result, duration, transcribe,
                language_hint([line.get('text', '') for line in result]))
    return result, mark_unreliable_words(result, duration)


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
    duration = entry.get('audio_duration') or entry.get('song_duration') or math.inf
    if not any(len(usable_word_indices(line, _boundary(lines, i, duration))) != len(line.get('words') or [])
               for i, line in enumerate(lines)):
        return None
    if not entry.get('audio_sha256'):
        raise ValueError('A verified recording identity is required')
    with tempfile.TemporaryDirectory(prefix='chordlyze-lyric-identity-') as temporary:
        decoded = Path(temporary) / 'recording.wav'
        _decode_to_wav(audio, decoded)
        with wave.open(str(decoded), 'rb') as pcm:
            duration = pcm.getnframes() / pcm.getframerate()
            digest = hashlib.sha256()
            while chunk := pcm.readframes(65536):
                digest.update(chunk)
        if digest.hexdigest() != entry['audio_sha256']:
            raise ValueError('Recording identity does not match the analyzed audio')
        prefix_stats, boundary_stats = {}, {}
        repaired = repair_word_spans(decoded, words, transcribe, stats=prefix_stats)
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
        updated['lyrics']['lines'] = repair_line_timings(decoded, updated['lyrics']['lines'], duration,
            transcribe, max_crops=MAX_REPAIR_CROPS - prefix_stats['attempted_crops'], stats=boundary_stats)
        if stats is not None:
            stats.update({key: prefix_stats[key] + boundary_stats[key]
                          for key in ('attempted_crops', 'repaired_phrases')})
    if updated == entry:
        return None
    if any(a['time'] >= b['time'] for a, b in zip(updated['lyrics']['lines'], updated['lyrics']['lines'][1:])):
        return None
    updated['lyrics']['word_timing_version'] = 2
    return updated
