"""The word timing contract shared with the iOS sheet's presentation guard.

Keep source timestamps for recording-backed repair. A failed word is marked
as uncertain; it must not invalidate usable anchors elsewhere in the phrase.
"""
from __future__ import annotations

import math
import hashlib
import json
import re
import unicodedata

MAX_WORD_DURATION = 8.0


def lyric_text_sha256(lines: list[dict]) -> str:
    """Fingerprint complete ordered lines, ignoring only Unicode/whitespace form."""
    text = [' '.join(unicodedata.normalize('NFKC', line['text']).split()) for line in lines]
    return hashlib.sha256(json.dumps(text, ensure_ascii=False, separators=(',', ':')).encode('utf-8')).hexdigest()


def reviewed_lyric_catalog(entry: dict) -> dict | None:
    """Use verified artist text only for its original reviewed recording.

    This marker is installed by the administrative replacement helper, never a
    client-writable API field. Old catalog caches cannot supersede its text.
    Timing is deliberately omitted so retries measure the current recording.
    """
    from .artist_recordings import valid_source_url
    from .fulltrack import _recording_candidate

    lyrics = entry.get('lyrics')
    if not isinstance(lyrics, dict):
        return None
    source = lyrics.get('text_source')
    recording = entry.get('audio_source')
    audio_hash = entry.get('audio_sha256')
    duration = entry.get('audio_duration')
    lines = lyrics.get('lines')
    if (not isinstance(source, dict) or not isinstance(recording, dict)
            or lyrics.get('matched') != 'aligned' or entry.get('source') != 'bandcamp'
            or source.get('provider') != 'bandcamp' or recording.get('provider') != 'bandcamp'
            or not str(recording.get('matching') or '').startswith('reviewed_')
            or not valid_source_url(source.get('url')) or source.get('url') != recording.get('url')
            or not isinstance(audio_hash, str) or re.fullmatch(r'[0-9a-f]{64}', audio_hash) is None
            or source.get('audio_sha256') != audio_hash or lyrics.get('audio_sha256') != audio_hash
            or not finite(duration) or duration <= 0 or lyrics.get('audio_duration') != duration
            or not isinstance(lines, list) or not lines
            or any(not isinstance(line, dict) or not isinstance(line.get('text'), str)
                   or not finite(line.get('time')) for line in lines)):
        return None
    expected_duration = entry.get('song_duration') or duration
    if (not finite(expected_duration) or expected_duration <= 0
            or not isinstance(entry.get('title'), str) or not isinstance(entry.get('artist'), str)
            or not _recording_candidate(recording, entry['title'], entry['artist'], expected_duration)
            or source.get('text_sha256') != lyric_text_sha256(lines)):
        return None
    return {'synced': False, 'matched': 'reviewed_artist', 'instrumental': False,
            'duration': duration, 'lines': [{'time': line['time'], 'text': line['text']} for line in lines]}


def finite(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def usable_word_indices(line: dict, before: float) -> list[int]:
    words = line.get('words') or []
    onset = line.get('time')
    if not finite(onset) or not finite(before) or before <= onset:
        return []
    # A stretched transcript word can also pin its preceding phrase prefix
    # to an instrumental boundary. The reliable suffix is the corroborating
    # evidence used by acoustic recovery; the prefix needs that recovery too.
    long_prefix = max((i for i, w in enumerate(words) if finite(w.get('time')) and finite(w.get('end'))
                       and w['end'] - w['time'] > MAX_WORD_DURATION), default=-1)
    candidates = []
    for index, word in enumerate(words):
        if index <= long_prefix:
            continue
        time, end = word.get('time'), word.get('end')
        if not finite(time) or not onset <= time < before:
            continue
        if end is not None and (not finite(end) or not 0 < end - time <= MAX_WORD_DURATION):
            continue
        candidates.append(index)
    # Both sides of a reversed sequence are ambiguous. Sorting tokens would
    # change the lyric, while choosing either side would invent certainty.
    maximum = -math.inf
    forward = set()
    for index in candidates:
        time = words[index]['time']
        if time >= maximum:
            forward.add(index)
        maximum = max(maximum, time)
    minimum = math.inf
    result = []
    for index in reversed(candidates):
        time = words[index]['time']
        if index in forward and time <= minimum:
            result.append(index)
        minimum = min(minimum, time)
    return list(reversed(result))


def mark_unreliable_words(lines: list[dict], duration: float | None) -> dict | None:
    """Flag failed geometry without erasing its evidence or changing text/time."""
    affected_lines = affected_words = 0
    for index, line in enumerate(lines):
        words = line.get('words') or []
        if not words:
            continue
        end = lines[index + 1].get('time') if index + 1 < len(lines) else duration
        if not finite(end):
            # Without a recording duration, only its upper range is unknown.
            end = max([line.get('time', 0), *[w['time'] for w in words if finite(w.get('time'))]]) + 1
        usable = set(usable_word_indices(line, end))
        invalid = set(range(len(words))) - usable
        if invalid:
            affected_lines += 1
            affected_words += len(invalid)
            for position in invalid:
                words[position]['estimated'] = True
    return {'lines': affected_lines, 'words': affected_words} if affected_lines else None


def has_measured_words(lines: list[dict], duration: float | None) -> bool:
    """At least one supported sung interval, not merely an estimated onset."""
    for index, line in enumerate(lines):
        boundary = lines[index + 1].get('time') if index + 1 < len(lines) else duration
        if not finite(boundary):
            continue
        words = line.get('words') or []
        for position in usable_word_indices(line, boundary):
            word = words[position]
            if (word.get('estimated') is not True and finite(word.get('end'))
                    and word['time'] < word['end'] <= boundary):
                return True
    return False


def preserves_lyric_text(previous: list[dict], candidate: list[dict]) -> bool:
    """Keep every known word occurrence in order when retrying its timing.

    Capitalization, punctuation and line wrapping may differ. A new transcript
    may add words, but cannot silently omit an old verse or repeated chorus.
    """
    def words(lines):
        for line in lines:
            for token in unicodedata.normalize('NFKC', line.get('text') or '').casefold().split():
                normalized = ''.join(character for character in token if character.isalnum())
                if normalized:
                    yield normalized

    remaining = iter(words(candidate))
    return all(any(found == known for found in remaining) for known in words(previous))
