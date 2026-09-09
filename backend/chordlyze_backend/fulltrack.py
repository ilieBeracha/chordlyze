"""Full-song audio for whole-track chord analysis.

The iTunes preview is a 30 s slice at an unknown offset, so chords from it
can't be placed on the song timeline. A reviewed artist stream or YouTube upload
whose length matches the track gives the whole song from 0:00. A result must carry
the song's title and last as long as the track. Matching duration alone cannot
distinguish alternate arrangements; declared recording variants must also match.
"""
from __future__ import annotations

import re
import math
import os
import shutil
import tempfile
import unicodedata
from pathlib import Path

_VARIANT = re.compile(
    r"\b(live|session|cover|remix|karaoke|instrumental|acoustic|stripped|reaction|tutorial|"
    r"lesson|slowed|sped up|nightcore|8d|extended|edit)\b", re.I)
_DECORATION = re.compile(r"[\(\[][^\)\]]*[\)\]]|\s+-\s+.*$")


def _words(text: str) -> str:
    """Lowercase words only: case and punctuation ignored."""
    return " ".join(re.sub(r"[^\w]+", " ", unicodedata.normalize("NFKC", text).casefold()).split())


def _core(title: str) -> str:
    """Comparable form of a title: bracketed notes and ' - …' suffixes dropped."""
    return _words(_DECORATION.sub("", title) or title)


def pick_candidate(entries: list[dict], title: str, artist: str, duration: float) -> dict | None:
    """Best search result for `title` lasting `duration` seconds, or None.
    The result's title must contain the song's title; duration (±1%, bounded to 2–3 seconds)
    narrows the candidates. Recognized variant words must match in both
    directions: a requested alternate edition cannot fall back to the regular
    recording just because their durations match."""
    tol = max(2.0, min(3.0, duration * 0.01))
    wanted = _core(title)
    if not wanted:
        return None
    requested_variants = {hit.group(0).casefold() for hit in _VARIANT.finditer(title)}

    def usable(e: dict) -> bool:
        d = e.get("duration")
        if not d or abs(d - duration) > tol:
            return False
        name = e.get("title") or ""
        credit = _words(f"{name} {e.get('channel') or e.get('uploader') or ''}")
        requested_artist = _words(artist)
        if requested_artist and f" {requested_artist} " not in f" {credit} ":
            return False
        if f" {wanted} " not in f" {_core(name)} " and f" {wanted} " not in f" {_words(name)} ":
            return False
        return {hit.group(0).casefold() for hit in _VARIANT.finditer(name)} == requested_variants

    good = [e for e in entries if usable(e)]
    if not good:
        return None

    def score(e: dict) -> float:
        channel = (e.get("channel") or e.get("uploader") or "").lower()
        name = (e.get("title") or "").lower()
        s = 0.0
        if channel.endswith(" - topic"):
            s += 3          # auto-generated album audio: exact studio version
        if artist and artist.lower() in channel:
            s += 2
        if title.lower() in name:
            s += 1
        s -= abs((e.get("duration") or 0) - duration) / tol
        return s

    return max(good, key=score)


def _search_youtube(title: str, artist: str, *, blocked_ok: bool = True) -> list[dict] | None:
    """Flat YouTube search results (id, title, channel, duration), no download.
    None when YouTube refuses the search from this network and `blocked_ok`."""
    import yt_dlp

    options = {"quiet": True, "no_warnings": True, "extract_flat": "in_playlist",
               "skip_download": True, "socket_timeout": 20}
    try:
        with yt_dlp.YoutubeDL(options) as ydl:
            info = ydl.extract_info(f"ytsearch8:{artist} {title}".strip(), download=False)
    except yt_dlp.utils.DownloadError:
        if not blocked_ok:
            raise
        return None
    return info.get("entries") or []


def _recording_candidate(source: dict, title: str, artist: str, duration: float) -> dict | None:
    """Validate saved provenance before using it to pin a lyric retry."""
    name = source.get('title')
    credit = source.get('artist') or source.get('channel') or source.get('uploader') or ''
    length = source.get('duration')
    if (not isinstance(name, str) or not isinstance(credit, str)
            or isinstance(length, bool) or not isinstance(length, (int, float))
            or not math.isfinite(length) or length <= 0):
        return None
    return pick_candidate([{'id': source.get('video_id'), 'title': name,
                            'channel': credit, 'duration': length}], title, artist, duration)


def fetch_full_track(title: str, artist: str, duration: float, *, source_info: dict | None = None,
                     checkpoint: dict | None = None, save_checkpoint=None,
                     cancelled=lambda: False, isrc: str | None = None,
                     recording_source: dict | None = None,
                     preferred_source: dict | None = None) -> Path | None:
    """Download the matching upload's audio to a temp file; None when no
    result matches. Provider failures raise a sanitized AudioProviderError in
    cloud mode or yt_dlp.utils.DownloadError in local development.

    A supplied recording_source pins a lyric retry to the saved recording.
    Invalid or missing provenance (an empty dict) never falls back to search.
    The worker still verifies the decoded PCM hash before aligning lyrics.
    """
    from .audio_apify import ApifyAudio, AudioProviderError, DownloadCancelled

    if cancelled():
        raise DownloadCancelled()
    from .artist_recordings import source_for, fetch_artist_recording, valid_source_url
    saved = None
    if recording_source is not None:
        if not isinstance(recording_source, dict):
            return None
        saved = _recording_candidate(recording_source, title, artist, duration)
        if saved is None:
            return None
        if recording_source.get('provider') == 'bandcamp':
            if not valid_source_url(recording_source.get('url')):
                return None
            audio = fetch_artist_recording(recording_source, title, artist, duration,
                                           source_info=source_info, cancelled=cancelled)
            if audio is not None and source_info is not None:
                source_info['matching'] = 'saved_recording_title_artist_duration'
            return audio
        video = saved.get('id')
        if (recording_source.get('provider') not in (None, 'youtube', 'yt_dlp', 'apify')
                or not isinstance(video, str) or not re.fullmatch(r'[A-Za-z0-9_-]{11}', video)
                or recording_source.get('url') not in (None, f'https://www.youtube.com/watch?v={video}')):
            return None
        previous = (checkpoint or {}).get('candidate')
        identifiers = [(checkpoint or {}).get('video_id')]
        if isinstance(previous, dict):
            identifiers.append(previous.get('id'))
        if any(value is not None and value != video for value in identifiers):
            checkpoint = None
    # New analyses prefer a reviewed artist stream; retries already have a
    # recording identity and must not substitute another registry entry.
    reviewed = source_for(isrc, title, artist, duration) if recording_source is None else None
    if (recording_source is None and isinstance(preferred_source, dict)
            and preferred_source.get('provider') == 'bandcamp'
            and str(preferred_source.get('matching') or '').startswith('reviewed_')
            and valid_source_url(preferred_source.get('url'))
            and _recording_candidate(preferred_source, title, artist, duration)):
        reviewed = preferred_source
    if reviewed:
        audio = fetch_artist_recording(reviewed, title, artist, duration,
                                       source_info=source_info, cancelled=cancelled)
        if audio is not None:
            if reviewed is preferred_source and source_info is not None:
                source_info['matching'] = 'reviewed_artist_title_duration'
            return audio
    provider = os.environ.get('CHORDLYZE_AUDIO_PROVIDER', 'yt_dlp')
    if provider == 'apify':
        client = ApifyAudio()
        previous = (checkpoint or {}).get('candidate')
        chosen = saved or (pick_candidate([previous], title, artist, duration) if isinstance(previous, dict) else None)
        search = 'saved_recording' if saved else 'checkpoint'
        if chosen is None:
            # Datacenter IPs are refused downloads, not usually searches. The
            # paid cloud search is the fallback when refused or on a miss.
            entries = _search_youtube(title, artist)
            search = 'yt_dlp'
            chosen = pick_candidate(entries, title, artist, duration) if entries is not None else None
        if chosen is None:
            entries = client.search(title, artist, checkpoint=checkpoint,
                                    save_checkpoint=save_checkpoint, cancelled=cancelled)
            search = 'apify'
            chosen = pick_candidate(entries, title, artist, duration)
        if chosen is None:
            return None
        path = client.download(chosen, duration, checkpoint=checkpoint,
                               save_checkpoint=save_checkpoint, cancelled=cancelled, source_info=source_info)
        if source_info is not None:
            source_info.update(video_id=chosen['id'], url=f"https://www.youtube.com/watch?v={chosen['id']}",
                               title=chosen['title'], channel=chosen.get('channel'),
                               duration=chosen['duration'], matching='title_artist_duration', search=search)
        return path
    if provider != 'yt_dlp':
        raise AudioProviderError('provider_configuration')

    import yt_dlp

    chosen = saved or pick_candidate(_search_youtube(title, artist, blocked_ok=False), title, artist, duration)
    if chosen is None:
        return None

    # Different library IDs can resolve to the same upload. Give each job its
    # own directory so concurrent downloads cannot overwrite/unlink each other.
    with tempfile.TemporaryDirectory(prefix="chordlyze-download-") as directory:
        outtmpl = str(Path(directory) / "%(id)s.%(ext)s")
        download = {"quiet": True, "no_warnings": True, "noprogress": True,
                    "format": "bestaudio/best", "noplaylist": True,
                    "socket_timeout": 20, "outtmpl": outtmpl}
        with yt_dlp.YoutubeDL(download) as ydl:
            result = ydl.extract_info(f"https://www.youtube.com/watch?v={chosen['id']}", download=True)
            source = Path(ydl.prepare_filename(result))
        descriptor, destination = tempfile.mkstemp(prefix="chordlyze-audio-", suffix=source.suffix)
        os.close(descriptor)
        path = Path(destination)
        try:
            shutil.move(source, path)
        except BaseException:
            path.unlink(missing_ok=True)
            raise
        if source_info is not None:
            source_info.update(video_id=chosen['id'], url=f"https://www.youtube.com/watch?v={chosen['id']}",
                               title=chosen.get('title'), channel=chosen.get('channel') or chosen.get('uploader'),
                               duration=chosen.get('duration'), matching='title_artist_duration')
        return path
