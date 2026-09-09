"""The word timing contract shared with the iOS sheet's presentation guard.

Keep source timestamps for recording-backed repair. A failed word is marked
as uncertain; it must not invalidate usable anchors elsewhere in the phrase.
"""
from __future__ import annotations

import math

MAX_WORD_DURATION = 8.0


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
