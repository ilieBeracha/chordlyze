"""Reviewed artist-hosted full recordings, keyed by recording ISRC.

These are public streams, never purchase-only downloads. Explicit source metadata
avoids guessing artist domains or accepting a different release with the same name.
The extracted recording is checked again before its audio is used.
"""
from __future__ import annotations

import json
import math
import os
from pathlib import Path
import re
import shutil
import tempfile
import time
from urllib.parse import urlsplit

from .audio_apify import AudioProviderError, DownloadCancelled

SOURCES_FILE = Path(__file__).with_name('recording_sources.json')
MAX_BYTES = 100 * 1024 * 1024
MAX_SECONDS = 120


def valid_source_url(url: str) -> bool:
    if not isinstance(url, str):
        return False
    try:
        parsed = urlsplit(url)
        return (parsed.scheme == 'https' and parsed.username is None and parsed.password is None
                and parsed.port is None and not parsed.query and not parsed.fragment
                and re.fullmatch(r'[a-z0-9-]+\.bandcamp\.com', parsed.hostname or '') is not None
                and re.fullmatch(r'/track/[a-z0-9-]+', parsed.path) is not None)
    except ValueError:
        return False


def source_for(isrc: str | None, title: str, artist: str, duration: float) -> dict | None:
    from .fulltrack import pick_candidate
    if not isrc:
        return None
    sources = json.loads(SOURCES_FILE.read_text())
    source = sources.get((isrc or '').upper())
    if not isinstance(source, dict) or not valid_source_url(source.get('url', '')):
        return None
    candidate = {**source, 'channel': source.get('artist', '')}
    return source if pick_candidate([candidate], title, artist, duration) else None


def fetch_artist_recording(source: dict, title: str, artist: str, duration: float, *,
                           source_info: dict | None = None, cancelled=lambda: False) -> Path | None:
    """Return independently validated full audio, or None for a missing public stream.
    All partial files are removed on provider failures, size limits, and cancellation.
    """
    import yt_dlp
    from .fulltrack import pick_candidate

    if not valid_source_url(source.get('url', '')):
        raise AudioProviderError('provider_configuration')
    if cancelled():
        raise DownloadCancelled()
    started = time.monotonic()

    def progress(status):
        if cancelled():
            raise DownloadCancelled()
        if time.monotonic() - started > MAX_SECONDS:
            raise AudioProviderError('provider_timeout')
        if max(status.get('downloaded_bytes') or 0, status.get('total_bytes') or 0) > MAX_BYTES:
            raise AudioProviderError('provider_download')

    def candidate(info):
        if not isinstance(info, dict) or info.get('_type') in ('playlist', 'multi_video'):
            return None
        length = info.get('duration')
        if not isinstance(length, (int, float)) or not math.isfinite(length):
            return None
        return pick_candidate([{'title': info.get('track') or info.get('title') or '',
                                'channel': info.get('artist') or info.get('uploader') or '',
                                'duration': length}], title, artist, duration)

    with tempfile.TemporaryDirectory(prefix='chordlyze-artist-') as directory:
        options = {'quiet': True, 'no_warnings': True, 'noprogress': True, 'noplaylist': True,
                   'socket_timeout': 20, 'retries': 1, 'fragment_retries': 1,
                   'format': 'bestaudio/best', 'max_filesize': MAX_BYTES,
                   'outtmpl': str(Path(directory) / '%(id)s.%(ext)s'), 'progress_hooks': [progress]}
        try:
            with yt_dlp.YoutubeDL(options) as ydl:
                info = ydl.extract_info(source['url'], download=False)
                if not candidate(info) or not info.get('formats'):
                    return None
                progress({})
                result = ydl.extract_info(source['url'], download=True)
                progress({})
                if not candidate(result):
                    raise AudioProviderError('recording_mismatch')
                audio = Path(ydl.prepare_filename(result)).resolve()
                if audio.parent != Path(directory).resolve() or not audio.is_file():
                    raise AudioProviderError('provider_download')
                if not 0 < audio.stat().st_size <= MAX_BYTES:
                    raise AudioProviderError('provider_download')
        except yt_dlp.utils.DownloadError:
            # A removed/non-streamable release may still have a YouTube match.
            if cancelled():
                raise DownloadCancelled()
            return None
        descriptor, name = tempfile.mkstemp(prefix='chordlyze-audio-', suffix=audio.suffix)
        os.close(descriptor)
        destination = Path(name)
        try:
            shutil.move(audio, destination)
        except BaseException:
            destination.unlink(missing_ok=True)
            raise
        if source_info is not None:
            source_info.update(provider='bandcamp', url=source['url'], title=result.get('track') or result.get('title'),
                               artist=result.get('artist'), duration=result['duration'],
                               matching='reviewed_isrc_title_artist_duration')
        return destination
