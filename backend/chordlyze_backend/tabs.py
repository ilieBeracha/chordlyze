"""Song charts and tabs from Songsterr, lined up with the Spotify recording.

Songsterr's public site API names a song's tracks; its CDN serves each
track's notes as JSON measures. A guitar part supplies chord names and the
tab; the vocal part carries the lyrics, one syllable per sung note. Both sit
on the tab's own clock (measures, beats and tempo marks).

That clock is mapped onto the recording by anchors: sung line starts fitted
to the recording's time-synced lyrics, or, for a recording that already has
an analyzed chart, the tab's chord changes fitted to the chart's. A tab that
does not fit is rejected, never shown misplaced.

String 0 is the highest-pitched string, as in Songsterr's data.
"""
from __future__ import annotations

import gzip
import json
import math
import re
import urllib.error
import urllib.parse
import urllib.request
from difflib import SequenceMatcher

import numpy as np

from .analysis.chord import parse_display
from .analysis.engine import ChordSegment
from .analysis.keyfinder import analyze

SEARCH_URL = "https://www.songsterr.com/api/songs"
META_URL = "https://www.songsterr.com/api/meta/{song_id}"
PART_URL = "https://dqsljvtekg760.cloudfront.net/{song_id}/{revision}/{image}/{part}.json"

# General MIDI programs 24-31: nylon, steel, jazz, clean, muted, overdriven,
# distortion and harmonics guitars.
GUITAR_INSTRUMENTS = range(24, 32)
# Guitar parts read for chord names, most-viewed first.
MAX_CHORD_PARTS = 3
# Line-up acceptance. A candidate anchor further than DRIFT_LIMIT from the
# overall fit, or LINE_TOLERANCE from what its neighbours predict, is not an
# anchor; enough anchors must remain, over enough of the song, and the tab's
# tempo must be within MAX_TEMPO_GAP of the recording's.
DRIFT_LIMIT = 3.0
LINE_TOLERANCE = 1.0
MAX_TEMPO_GAP = 0.05
MIN_ANCHORS = 4
MIN_INLIER_SHARE = 0.6
MIN_COVERAGE = 0.5
# Words matched in a row before a line start counts as found in the tab.
MIN_RUN = 3
# Chord line-up: timeline resolution, tempo search step, how far a tab
# change may sit from the chart's same change, and the share of the
# overlapping time the warped tab must name the chart's chord.
CHORD_STEP = 0.1
CHORD_SCALE_STEP = 0.005
CHORD_SNAP = 1.5
MIN_CHORD_AGREEMENT = 0.7
# Share of a half bar's sounding notes a triad must hold to name it.
HEARD_CHORD_SHARE = 0.7

TIMING_NOTE = "Chords and lyrics from Songsterr, lined up with the recording."


class Unavailable(Exception):
    """Songsterr is down or unreachable: "try again", never "no chart"."""


class NotFound(Exception):
    """No usable Songsterr chart or tab for this recording; the reason says why."""


def _get(url: str):
    """JSON from Songsterr; None on 404."""
    req = urllib.request.Request(url, headers={"User-Agent": "Chordlyze/0.5",
                                               "Accept-Encoding": "gzip"})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            body = resp.read()
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None
        raise Unavailable(f"tab service returned {exc.code}") from exc
    except (urllib.error.URLError, TimeoutError) as exc:
        raise Unavailable(f"tab service unreachable: {exc}") from exc
    if body[:2] == b"\x1f\x8b":
        body = gzip.decompress(body)
    return json.loads(body)


_TITLE_NOISE = re.compile(r"\s*[\(\[][^\)\]]*[\)\]]|\s+-\s+.*$")


def _clean(title: str) -> str:
    """Strip '(feat. X)', '[Remix]', '- Remastered 2011' style noise."""
    return _TITLE_NOISE.sub("", title).strip() or title


def _sim(a: str, b: str) -> float:
    return SequenceMatcher(None, a.lower().strip(), b.lower().strip()).ratio()


def best_match(results: list[dict], title: str, artist: str) -> dict | None:
    """The search result that is this song by this artist, if any. Songsterr
    has no durations, so both names must agree closely."""
    def score(cand: dict) -> float:
        t = max(_sim(cand.get("title") or "", title), _sim(cand.get("title") or "", _clean(title)))
        a = _sim(cand.get("artist") or "", artist)
        return 0.0 if t < 0.8 or a < 0.7 else t + a
    scored = [(score(c), c) for c in results]
    scored = [(s, c) for s, c in scored if s > 0]
    return max(scored, key=lambda sc: sc[0])[1] if scored else None


def guitar_parts(meta: dict) -> list[int]:
    """Guitar track indexes, Songsterr's most-viewed guitar part first."""
    parts = [i for i, t in enumerate(meta.get("tracks") or [])
             if t.get("instrumentId") in GUITAR_INSTRUMENTS and not t.get("isEmpty")]
    popular = meta.get("popularTrackGuitar")
    return sorted(parts, key=lambda i: i != popular)


def _beat(beat: dict) -> dict:
    out = {"duration": beat["duration"]}
    if beat.get("rest"):
        out["rest"] = True
    if beat.get("chord", {}).get("text"):
        out["chord"] = beat["chord"]["text"]
    notes = []
    for note in beat.get("notes") or []:
        if note.get("rest") or "fret" not in note:
            continue
        n = {"string": note["string"], "fret": note["fret"]}
        for flag in ("tie", "dead"):
            if note.get(flag):
                n[flag] = True
        notes.append(n)
    out["notes"] = notes
    return out


def simplify(part: dict) -> dict:
    """Songsterr's part JSON reduced to what the tab rows draw. Only the
    first voice is kept: its beats fill each measure."""
    measures = []
    for m in part["measures"]:
        out = {"beats": [_beat(b) for b in m["voices"][0]["beats"]]}
        if m.get("marker", {}).get("text"):
            out["marker"] = m["marker"]["text"]
        measures.append(out)
    return {"name": part.get("name") or "", "tuning": part.get("tuning") or [],
            "capo": part.get("capo") or 0, "measures": measures}


# MARK: - The tab's clock

def _length(beat: dict) -> float:
    n, d = beat["duration"]
    return n / d


def measure_lengths(part: dict) -> list[float]:
    """Each measure's length in whole notes, from the running time signature."""
    lengths, signature = [], None
    for m in part["measures"]:
        signature = m.get("signature") or signature
        if signature is None:
            raise NotFound("the tab has no time signature")
        lengths.append(signature[0] / signature[1])
    return lengths


def play_order(part: dict) -> list[int]:
    """Measure indexes in the order they sound, repeats unrolled."""
    measures = part["measures"]
    for m in measures:
        unknown = [k for k in m if any(w in k.lower() for w in ("alternat", "volta", "coda", "segno", "fine"))]
        if unknown:
            raise NotFound(f"the tab uses {unknown[0]}, which Chordlyze cannot follow yet")
    order, start = [], 0
    for i, m in enumerate(measures):
        if m.get("repeatStart"):
            start = i
        order.append(i)
        times = m.get("repeat")
        if times:
            for _ in range(int(times) - 1):
                order.extend(range(start, i + 1))
            start = i + 1
    return order


def clock(part: dict, order: list[int], automations: dict) -> list[tuple[float, float]]:
    """(start, end) seconds of each played measure on the tab's clock.
    Tempo marks sit at a measure and a fraction of it; a linear mark ramps to
    the next mark in playing order."""
    lengths = measure_lengths(part)
    marks: dict[int, list[dict]] = {}
    for t in automations.get("tempo") or []:
        marks.setdefault(t["measure"], []).append(t)
    if not marks:
        raise NotFound("the tab has no tempo")
    # Tempo points along the played timeline, in whole notes from the start.
    points, at = [], 0.0
    for m in order:
        for t in sorted(marks.get(m, []), key=lambda t: t["position"]):
            spw = 60.0 * t["type"] / t["bpm"]  # seconds per whole note
            points.append((at + t["position"] * lengths[m], spw, bool(t.get("linear"))))
        at += lengths[m]
    points.sort(key=lambda p: p[0])
    if points[0][0] > 0:
        points.insert(0, (0.0, points[0][1], False))

    def seconds(x: float) -> float:
        total = 0.0
        for i, (x0, spw0, linear) in enumerate(points):
            if x0 >= x:
                break
            x1 = points[i + 1][0] if i + 1 < len(points) else math.inf
            end = min(x, x1)
            if linear and x1 < math.inf and points[i + 1][1] != spw0:
                # bpm (∝ 1/spw) changes linearly over [x0, x1].
                b0, b1 = 1 / spw0, 1 / points[i + 1][1]
                slope = (b1 - b0) / (x1 - x0)
                total += math.log((b0 + slope * (end - x0)) / b0) / slope
            else:
                total += (end - x0) * spw0
        return total

    spans, at = [], 0.0
    for m in order:
        spans.append((seconds(at), seconds(at + lengths[m])))
        at += lengths[m]
    return spans


def _beat_times(part: dict, m: int, span: tuple[float, float], length: float):
    """(beat, start, end) seconds for measure m's first-voice beats."""
    start, end = span
    rate = (end - start) / length
    at = 0.0
    for beat in part["measures"][m]["voices"][0]["beats"]:
        size = _length(beat)
        yield beat, start + at * rate, start + (at + size) * rate
        at += size


# MARK: - Chords and words on the tab's clock

def chord_events(part: dict, order: list[int], spans) -> list[tuple[float, str]]:
    lengths = measure_lengths(part)
    events = []
    for m, span in zip(order, spans):
        for beat, start, _ in _beat_times(part, m, span, lengths[m]):
            text = (beat.get("chord") or {}).get("text")
            if text:
                events.append((start, text.strip()))
    return events


_SECTION = re.compile(r"^\s*\[[^\]]*\]\s*$")
_GHOST = re.compile(r"\([^)]*\)")


def syllable_lines(text: str) -> list[list[list[str]]]:
    """Lyric text as lines of words of syllables. Every syllable takes one
    sung note, including '+' (a held note) and '(u)' style melisma."""
    lines = []
    for line in text.split("\n"):
        if not line.strip() or _SECTION.match(line):
            continue
        words = [[s for s in word.split("-") if s] for word in line.split()]
        lines.append([w for w in words if w])
    return lines


def sung_words(vocal: dict, order: list[int], spans) -> list[dict]:
    """Lyric words with the times of their sung notes, lines marked. Lyrics
    sit on the written notes, so a repeated passage sings them once."""
    lyrics = [e for e in vocal.get("newLyrics") or [] if (e.get("text") or "").strip()]
    if not lyrics:
        raise NotFound("the tab has no lyrics to line up with the recording")
    if len(lyrics) > 1 or lyrics[0].get("line") != 1:
        raise NotFound("the tab sings repeats with different lyrics, which Chordlyze cannot follow yet")
    lengths = measure_lengths(vocal)
    first_pass = {}
    for m, span in zip(order, spans):
        first_pass.setdefault(m, span)
    offset = int(lyrics[0].get("offset") or 1) - 1
    notes = []
    for m in range(offset, len(vocal["measures"])):
        if m not in first_pass:
            continue
        for beat, start, end in _beat_times(vocal, m, first_pass[m], lengths[m]):
            sounding = [n for n in beat.get("notes") or [] if not n.get("rest")]
            if beat.get("rest") or not sounding:
                continue
            if all(n.get("tie") for n in sounding):
                if notes:
                    notes[-1][1] = end  # the held note keeps sounding
                continue
            notes.append([start, end])
    words, i = [], 0
    for line in syllable_lines(lyrics[0]["text"]):
        starts_line = True
        for syllables in line:
            if i + len(syllables) > len(notes):
                raise NotFound("the tab's lyrics run past its sung notes")
            text = _GHOST.sub("", "".join(s for s in syllables if s != "+"))
            if text:
                words.append({"time": notes[i][0], "end": notes[i + len(syllables) - 1][1],
                              "text": text, "line_start": starts_line})
                starts_line = False
            i += len(syllables)
    return words


# MARK: - Lining the tab up with the recording

def _norm(word: str) -> str:
    return re.sub(r"[^a-z0-9']", "", word.lower().replace("’", "'"))


def _fit(pairs):
    n = len(pairs)
    mx = sum(p[0] for p in pairs) / n
    my = sum(p[1] for p in pairs) / n
    var = sum((p[0] - mx) ** 2 for p in pairs)
    scale = sum((p[0] - mx) * (p[1] - my) for p in pairs) / var if var > 0 else 1.0
    return scale, my - scale * mx


def _settle(found: list[tuple[float, float]], span: float, what: str) -> dict:
    """Anchors from candidate (tab time, recording time) pairs. Between
    anchors the tab's clock is warped linearly, so a recording that drifts
    from the tab's tempo marks stays in step. Raises when the anchors do not
    hold over most of `span` seconds of the recording."""
    found = sorted(found)
    if len(found) < MIN_ANCHORS:
        raise NotFound(f"the tab's {what} do not match this recording's {what}")
    # A different arrangement shows as a stretched or shifted clock: reject it.
    scale, offset = _fit(found)
    anchors = [p for p in found if abs(scale * p[0] + offset - p[1]) <= DRIFT_LIMIT]
    # A stray anchor disagrees with what its neighbours predict.
    changed = True
    while changed and len(anchors) >= 3:
        changed = False
        worst, worst_error = None, LINE_TOLERANCE
        for k in range(len(anchors)):
            (t0, r0) = anchors[k - 1] if k > 0 else anchors[k + 1]
            (t1, r1) = anchors[k + 1] if 0 < k < len(anchors) - 1 else anchors[k - 2 if k else k + 2]
            if t1 == t0:
                continue
            t, r = anchors[k]
            error = abs(r0 + (r1 - r0) * (t - t0) / (t1 - t0) - r)
            if error > worst_error:
                worst, worst_error = k, error
        if worst is not None:
            del anchors[worst]
            changed = True
    anchors = [p for k, p in enumerate(anchors) if k == 0 or (p[0] > anchors[k - 1][0] and p[1] > anchors[k - 1][1])]
    if len(anchors) >= 2:
        scale, offset = _fit(anchors)
    covered = (anchors[-1][1] - anchors[0][1]) if anchors else 0
    if (len(anchors) < max(MIN_ANCHORS, MIN_INLIER_SHARE * len(found))
            or not 1 - MAX_TEMPO_GAP <= scale <= 1 + MAX_TEMPO_GAP or covered < MIN_COVERAGE * span):
        raise NotFound("the tab's timing does not line up with this recording")
    return {"scale": scale, "offset": offset, "anchors": [[round(t, 3), round(r, 3)] for t, r in anchors],
            "found": len(found)}


def line_up(words: list[dict], lines: list[dict]) -> dict:
    """Anchors at the start of every recording lyric line found, in order,
    among the tab's sung words."""
    tab = [(_norm(w["text"]), w["time"]) for w in words]
    tab = [t for t in tab if t[0]]
    rec, starts = [], {}
    for line in lines:
        first = True
        for word in line["text"].split():
            norm = _norm(word)
            if norm:
                if first:
                    starts[len(rec)] = line["time"]
                    first = False
                rec.append((norm, line["time"]))
    matcher = SequenceMatcher(None, [t[0] for t in tab], [r[0] for r in rec], autojunk=False)
    found = []
    for i, j, size in matcher.get_matching_blocks():
        if size < MIN_RUN:
            continue
        for k in range(size):
            if j + k in starts:
                found.append((tab[i + k][1], starts[j + k]))
    line_times = [line["time"] for line in lines if line["text"].strip()]
    span = (max(line_times) - min(line_times)) if line_times else 0
    return {**_settle(found, span, "lyrics"), "basis": "lyrics"}


_PITCH = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}


def _symbol(label: str) -> int | None:
    """Chord label reduced to root and major/minor (0-23); None for no chord.
    Inversions and extensions vary between transcribers; the root and third
    do not."""
    if not label or label == "N" or ":" not in label:
        return None
    root, quality = label.split(":", 1)
    if root[:1] not in _PITCH:
        return None
    pc = (_PITCH[root[0]] + root[1:].count("#") - root[1:].count("b")) % 12
    minor = quality.startswith(("min", "dim", "hdim"))
    return pc + 12 * minor


def _timeline(spans: list[tuple[float, float, int]], length: float) -> np.ndarray:
    """Chord symbols sampled every CHORD_STEP seconds; -1 where none sounds."""
    out = np.full(max(1, int(math.ceil(length / CHORD_STEP))), -1, dtype=np.int16)
    for start, end, symbol in spans:
        a, b = max(int(round(start / CHORD_STEP)), 0), max(int(round(end / CHORD_STEP)), 0)
        out[a:b] = symbol
    return out


def named_chords(events: list[tuple[float, str]], tab_end: float) -> list[tuple[float, float, int]]:
    """The tab's written chord names as (start, end, symbol) on its clock."""
    named = [(t, _symbol(_label(name))) for t, name in events]
    named = [(t, s) for t, s in named if s is not None]
    return [(t, nxt, s) for (t, s), (nxt, _) in zip(named, named[1:] + [(tab_end, None)])]


_TRIADS = [(root, minor, {root % 12, (root + (3 if minor else 4)) % 12, (root + 7) % 12})
           for minor in (False, True) for root in range(12)]


def heard_chords(part: dict, order: list[int], spans) -> list[tuple[float, float, int]]:
    """Chords worked out from the tab's notes, for tabs that do not write
    chord names: every half bar, the major or minor triad holding most of
    the sounding pitch classes (string tuning, capo and fret give each
    pitch). Half bars without a clear triad name nothing."""
    tuning, capo = part.get("tuning") or [], part.get("capo") or 0
    lengths = measure_lengths(part)
    out = []
    for m, span in zip(order, spans):
        weights = [np.zeros(12), np.zeros(12)]
        middle = span[0] + (span[1] - span[0]) / 2
        for beat, start, end in _beat_times(part, m, span, lengths[m]):
            for note in beat.get("notes") or []:
                if note.get("rest") or note.get("dead") or "fret" not in note or note["string"] >= len(tuning):
                    continue
                pitch = (tuning[note["string"]] + capo + note["fret"]) % 12
                weights[0 if start < middle else 1][pitch] += end - start
        for half, chroma in enumerate(weights):
            total = chroma.sum()
            if total <= 0:
                continue
            fits = sorted(((sum(chroma[p] for p in pcs) / total, root + 12 * minor)
                           for root, minor, pcs in _TRIADS), reverse=True)
            if fits[0][0] >= HEARD_CHORD_SHARE and fits[0][0] > fits[1][0]:
                a = span[0] if half == 0 else middle
                out.append((a, middle if half == 0 else span[1], fits[0][1]))
    merged = []
    for a, b, s in out:
        if merged and merged[-1][2] == s and abs(merged[-1][1] - a) < 1e-6:
            merged[-1] = (merged[-1][0], b, s)
        else:
            merged.append((a, b, s))
    return merged


def chord_line_up(tab_spans: list[tuple[float, float, int]], chart: list[dict], duration: float) -> dict:
    """Anchors where the tab's chord changes meet the same changes in an
    analyzed chart. A coarse search over tempo and offset finds where the
    tab sits; each tab change then pairs with the chart's nearest change to
    the same chord, and the pairs must hold like lyric anchors do."""
    rec = [(c["start"], c["end"], _symbol(c["label"])) for c in chart]
    rec = [(a, b, s) for a, b, s in rec if s is not None]
    if len(tab_spans) < MIN_ANCHORS or len(rec) < MIN_ANCHORS:
        raise NotFound("the tab or the chart has too few chords to line them up")
    tab = [(a, s) for a, _, s in tab_spans]
    tab_end = tab_spans[-1][1]
    reference = _timeline(rec, duration)
    best = (0.0, 1.0, 0.0)
    for scale in np.arange(1 - MAX_TEMPO_GAP, 1 + MAX_TEMPO_GAP + 1e-9, CHORD_SCALE_STEP):
        moving = _timeline([(a * scale, b * scale, s) for a, b, s in tab_spans], tab_end * scale)
        size = 1 << int(math.ceil(math.log2(len(reference) + len(moving))))
        score = np.zeros(size)
        for symbol in set(np.unique(moving).tolist()) - {-1}:
            a = np.fft.rfft((reference == symbol).astype(float), size)
            b = np.fft.rfft((moving == symbol).astype(float)[::-1], size)
            score += np.fft.irfft(a * b, size)
        k = int(np.argmax(score))
        if score[k] > best[0]:
            best = (float(score[k]), float(scale), (k - (len(moving) - 1)) * CHORD_STEP)
    _, scale, offset = best
    found = []
    for t, s in tab:
        guess = scale * t + offset
        near = [a for a, _, r in rec if r == s and abs(a - guess) <= CHORD_SNAP]
        if near:
            found.append((t, min(near, key=lambda a: abs(a - guess))))
    fitted = _settle(found, duration, "chords")
    to_rec = warp(fitted)
    warped = _timeline([(to_rec(a), to_rec(b), s) for a, b, s in tab_spans], duration)
    both = (warped >= 0) & (reference >= 0)
    agreement = float((warped[both] == reference[both]).mean()) if both.any() else 0.0
    if agreement < MIN_CHORD_AGREEMENT:
        raise NotFound("the tab's chords disagree with this recording's chart")
    return {**fitted, "basis": "chords", "agreement": round(agreement, 3)}


def warp(fitted: dict):
    """Tab time to recording time: through the anchors, and at the overall
    scale before the first and after the last."""
    anchors, scale = fitted["anchors"], fitted["scale"]

    def to_rec(t: float) -> float:
        if t <= anchors[0][0]:
            return anchors[0][1] + (t - anchors[0][0]) * scale
        if t >= anchors[-1][0]:
            return anchors[-1][1] + (t - anchors[-1][0]) * scale
        k = next(i for i in range(1, len(anchors)) if anchors[i][0] >= t)
        (t0, r0), (t1, r1) = anchors[k - 1], anchors[k]
        return r0 + (r1 - r0) * (t - t0) / (t1 - t0)
    return to_rec


# MARK: - Charts and tabs

_ROOT = re.compile(r"^([A-G][#b]?)(.*?)(/[A-G][#b]?)?$")


def _label(name: str) -> str:
    """The chart label for a Songsterr chord name, in the recognizer's
    vocabulary. A chord outside it (add9, power chords) is reduced to its
    triad, as the recognizer would name it; an unreadable name is no chord."""
    def spelled(text: str) -> str | None:
        try:
            parsed = parse_display(text)
        except (ValueError, IndexError):
            return None
        return parsed.label if parsed is not None and parsed.intervals is not None else None

    if (label := spelled(name)) is not None:
        return label
    match = _ROOT.match(name.strip())
    if match is None:
        return "N"
    root, quality, bass = match.group(1), match.group(2), match.group(3) or ""
    minor = quality.startswith("m") and not quality.startswith("maj")
    return spelled(root + ("m" if minor else "") + bass) or spelled(root + ("m" if minor else "")) or "N"


def _source(title: str, artist: str, named: bool) -> dict:
    """The Songsterr song: a guitar part (one that names chords when `named`,
    else preferably one), and its vocal part when it has one."""
    query = urllib.parse.urlencode({"pattern": f"{_clean(title)} {artist}", "size": 20})
    match = best_match(_get(f"{SEARCH_URL}?{query}") or [], title, artist)
    if match is None:
        raise NotFound("Songsterr has no tab for this song")
    song_id = match["songId"]
    meta = _get(META_URL.format(song_id=song_id))
    if meta is None:
        raise NotFound("Songsterr has no tab for this song")

    def part(index: int) -> dict:
        data = _get(PART_URL.format(song_id=song_id, revision=meta["revisionId"],
                                    image=meta["image"], part=index))
        if data is None:
            raise NotFound("Songsterr's tab is unavailable")
        return data

    candidates = guitar_parts(meta)
    if not candidates:
        raise NotFound("Songsterr has no guitar part for this song")
    first = None
    for index in candidates[:MAX_CHORD_PARTS]:
        guitar = part(index)
        first = first or (index, guitar)
        if sum(1 for m in guitar["measures"] for b in m["voices"][0]["beats"] if b.get("chord")) >= 2:
            break
    else:
        if named:
            raise NotFound("Songsterr's guitar parts do not name chords for this song")
        index, guitar = first
    vocal_index = meta.get("popularTrackVocals")
    vocal = part(vocal_index) if vocal_index is not None else None
    if vocal is not None and len(vocal["measures"]) != len(guitar["measures"]):
        raise NotFound("the tab's parts disagree on its length")
    return {"song_id": song_id, "revision": meta["revisionId"], "guitar": guitar, "guitar_index": index,
            "vocal": vocal, "vocal_index": vocal_index}


def _tab(src: dict, order, spans, to_rec, duration: float) -> dict:
    return {**simplify(src["guitar"]), "index": src["guitar_index"],
            "bars": [{"measure": m, "start": round(to_rec(a), 3), "end": round(to_rec(b), 3)}
                     for m, (a, b) in zip(order, spans) if to_rec(b) > 0 and to_rec(a) < duration]}


def _identity(src: dict, fitted: dict) -> dict:
    return {"song_id": src["song_id"], "revision": src["revision"], "part": src["guitar_index"],
            "vocal_part": src["vocal_index"], **fitted}


def tab_for_chart(title: str, artist: str, duration: float, lines: list[dict] | None,
                  chords: list[dict]) -> dict:
    """The tab for a recording that already has an analyzed chart: lined up
    by the recording's lyrics when the tab sings them, else by the chart's
    own chord changes (instrumentals, unmatched lyrics) against the tab's
    written chord names, or chords worked out from its notes."""
    src = _source(title, artist, named=False)
    guitar = src["guitar"]
    order = play_order(guitar)
    spans = clock(guitar, order, guitar.get("automations") or {})
    fitted = None
    if src["vocal"] is not None and lines:
        try:
            fitted = line_up(sung_words(src["vocal"], order, spans), lines)
        except NotFound:
            fitted = None
    if fitted is None:
        named = named_chords(chord_events(guitar, order, spans), spans[-1][1])
        fitted = chord_line_up(named if len(named) >= MIN_ANCHORS else heard_chords(guitar, order, spans),
                               chords, duration)
    return {"tab": _tab(src, order, spans, warp(fitted), duration), "songsterr": _identity(src, fitted)}


def build(title: str, artist: str, duration: float, lines: list[dict]) -> dict:
    """The chart, recording-timed lyrics and tab for a recording without a
    chart, from Songsterr. `lines` are its time-synced lyric lines."""
    src = _source(title, artist, named=True)
    guitar, vocal = src["guitar"], src["vocal"]
    if vocal is None:
        raise NotFound("the tab has no vocal part to line up with the recording")
    order = play_order(guitar)
    spans = clock(guitar, order, guitar.get("automations") or {})
    words = sung_words(vocal, order, spans)
    fitted = line_up(words, lines)
    to_rec = warp(fitted)

    # Chords: each sounds until the next; silence before the first.
    end = min(to_rec(spans[-1][1]), duration)
    events = [(max(0.0, to_rec(t)), name) for t, name in chord_events(guitar, order, spans)]
    events = [(t, name) for t, name in events if t < end]
    if not events:
        raise NotFound("the tab's chords fall outside this recording")
    segments = []
    if events[0][0] > 0:
        segments.append(ChordSegment(0.0, events[0][0], "N"))
    for (t, name), nxt in zip(events, events[1:] + [(end, None)]):
        if nxt[0] <= t:
            continue  # a later chord at the same moment replaces this one
        segments.append(ChordSegment(round(t, 3), round(nxt[0], 3), _label(name)))
    chart = analyze(segments)

    # Beat grid: one beat per time-signature unit, bars numbered 1..n.
    signature, signatures = None, []
    for m in guitar["measures"]:
        signature = m.get("signature") or signature
        signatures.append(signature)
    beats, positions, bars = [], [], []
    for m, (start, stop) in zip(order, spans):
        count = signatures[m][0]
        times = [to_rec(start + (stop - start) * k / count) for k in range(count)]
        if times[0] < 0 or times[-1] >= duration:
            continue
        first = len(beats)
        beats.extend(round(t, 3) for t in times)
        positions.extend(range(1, count + 1))
        bars.append({"start": beats[first], "end": round(to_rec(stop), 3), "beats": count})
    if bars and bars[-1]["end"] < duration:
        beats.append(bars[-1]["end"])
        positions.append(1)
    bars = [b for b in bars if b["end"] in beats]
    gaps = sorted(b - a for a, b in zip(beats, beats[1:]))
    if not gaps:
        raise NotFound("the tab's measures fall outside this recording")
    tempo = {"bpm": round(60 / gaps[len(gaps) // 2], 1), "beats": beats, "beat_positions": positions,
             "bars": bars, "rhythm_version": 1}

    # Lyrics: Songsterr's lines, each word at its first sung note.
    lyric_lines = []
    for w in words:
        stamp = {"time": round(to_rec(w["time"]), 3), "end": round(to_rec(w["end"]), 3),
                 "text": w["text"], "estimated": False}
        if w["line_start"] or not lyric_lines:
            lyric_lines.append({"time": stamp["time"], "text": w["text"], "words": [stamp]})
        else:
            lyric_lines[-1]["text"] += " " + w["text"]
            lyric_lines[-1]["words"].append(stamp)

    chart.update({"source": "songsterr", "model": "songsterr", "audio_duration": duration,
                  "song_duration": duration, "tempo": tempo, "songsterr": _identity(src, fitted)})
    return {"analysis": chart,
            "lyrics": {"lines": lyric_lines, "synced": True, "matched": "songsterr",
                       "instrumental": False, "timing_note": TIMING_NOTE},
            "tab": _tab(src, order, spans, to_rec, duration)}
