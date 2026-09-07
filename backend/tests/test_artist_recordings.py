from pathlib import Path

import pytest
import yt_dlp

from chordlyze_backend import artist_recordings as recordings, fulltrack
from chordlyze_backend.audio_apify import AudioProviderError, DownloadCancelled

TITLE, ARTIST, DURATION = 'Shadows', 'Zero 7, Lou Stone', 317.72
SOURCE = {'url': 'https://zero7.bandcamp.com/track/shadows'}
INFO = {'id': 'recording', 'ext': 'mp3', 'track': TITLE, 'artist': ARTIST,
        'duration': DURATION, 'formats': [{'format_id': 'mp3-128'}]}


@pytest.mark.parametrize('url', [None, 4, 'http://zero7.bandcamp.com/track/shadows',
    'https://bandcamp.com/track/shadows', 'https://zero7.bandcamp.com.evil.test/track/shadows',
    'https://user@zero7.bandcamp.com/track/shadows', 'https://localhost/track/shadows',
    'https://zero7.bandcamp.com:443/track/shadows', 'https://zero7.bandcamp.com/album/shadows',
    'https://zero7.bandcamp.com/track/shadows?download=1',
    'https://zero7.bandcamp.com/track/shadows#download'])
def test_only_reviewed_public_track_url_shape_is_allowed(url):
    assert not recordings.valid_source_url(url)


def test_source_requires_isrc_and_recording_metadata():
    assert recordings.source_for('uk46t1001001', TITLE, ARTIST, DURATION)['url'] == SOURCE['url']
    for isrc, title, artist, duration in [(None, TITLE, ARTIST, DURATION),
        ('UNKNOWN', TITLE, ARTIST, DURATION), ('UK46T1001001', 'Different', ARTIST, DURATION),
        ('UK46T1001001', TITLE, 'Another artist', DURATION), ('UK46T1001001', TITLE, ARTIST, 286)]:
        assert recordings.source_for(isrc, title, artist, duration) is None


@pytest.fixture
def downloader(monkeypatch):
    class FakeDownloader:
        initial = INFO.copy()
        final = INFO.copy()
        calls = []
        directories = []
        hook_status = {}
        error = False
        def __init__(self, options):
            self.options = options
            self.audio = Path(options['outtmpl']).parent / 'recording.mp3'
            self.directories.append(self.audio.parent)
        def __enter__(self): return self
        def __exit__(self, *args): pass
        def prepare_filename(self, info): return str(self.audio)
        def extract_info(self, url, download):
            self.calls.append(download)
            if download:
                self.audio.write_bytes(b'public stream')
                for hook in self.options['progress_hooks']: hook(self.hook_status)
                if self.error: raise yt_dlp.utils.DownloadError('removed')
                return self.final
            return self.initial
    monkeypatch.setattr(yt_dlp, 'YoutubeDL', FakeDownloader)
    return FakeDownloader


def fetch(**kwargs):
    return recordings.fetch_artist_recording(SOURCE, TITLE, ARTIST, DURATION, **kwargs)


def test_validated_audio_survives_temporary_directory_and_has_provenance(downloader):
    provenance = {}
    audio = fetch(source_info=provenance)
    try:
        assert audio.read_bytes() == b'public stream'
        assert not any(path.exists() for path in downloader.directories)
        assert provenance['provider'] == 'bandcamp'
        assert provenance['url'] == SOURCE['url'] and provenance['duration'] == DURATION
        assert downloader.calls == [False, True]
    finally:
        audio.unlink()


@pytest.mark.parametrize('changes', [{'duration': 286}, {'duration': float('nan')},
    {'artist': 'Another artist'}, {'track': 'Another song'}, {'formats': []}, {'_type': 'playlist'}])
def test_mismatch_or_missing_public_stream_never_downloads(downloader, changes):
    downloader.initial = {**INFO, **changes}
    assert fetch() is None
    assert downloader.calls == [False]
    assert not any(path.exists() for path in downloader.directories)


def test_changed_recording_is_rejected_and_deleted(downloader):
    downloader.final = {**INFO, 'duration': 286}
    with pytest.raises(AudioProviderError) as error: fetch()
    assert error.value.code == 'recording_mismatch'
    assert not any(path.exists() for path in downloader.directories)


def test_cancellation_before_network_and_during_download(downloader):
    with pytest.raises(DownloadCancelled): fetch(cancelled=lambda: True)
    assert downloader.calls == []
    with pytest.raises(DownloadCancelled): fetch(cancelled=lambda: True in downloader.calls)
    assert not any(path.exists() for path in downloader.directories)


@pytest.mark.parametrize('limit', ['size', 'time'])
def test_budget_limits_remove_partial_audio(downloader, monkeypatch, limit):
    if limit == 'size':
        downloader.hook_status = {'downloaded_bytes': recordings.MAX_BYTES + 1}
    else:
        ticks = iter([0, 0, recordings.MAX_SECONDS + 1])
        monkeypatch.setattr(recordings.time, 'monotonic', lambda: next(ticks))
    with pytest.raises(AudioProviderError): fetch()
    assert not any(path.exists() for path in downloader.directories)


def test_removed_stream_cleans_partial_file_and_allows_fallback(downloader):
    downloader.error = True
    assert fetch() is None
    assert not any(path.exists() for path in downloader.directories)


@pytest.mark.parametrize('available', [False, True])
def test_fulltrack_uses_reviewed_source_before_existing_search(monkeypatch, tmp_path, available):
    audio = tmp_path / 'audio.mp3'
    calls = []
    monkeypatch.setattr(recordings, 'fetch_artist_recording', lambda *a, **kw: audio if available else None)
    monkeypatch.setattr(fulltrack, '_search_youtube', lambda *a, **kw: calls.append('search') or [])
    monkeypatch.setenv('CHORDLYZE_AUDIO_PROVIDER', 'yt_dlp')
    result = fulltrack.fetch_full_track(TITLE, ARTIST, DURATION, isrc='UK46T1001001')
    assert result == (audio if available else None)
    assert calls == ([] if available else ['search'])
