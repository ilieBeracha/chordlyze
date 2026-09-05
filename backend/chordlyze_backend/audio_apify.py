"""Bounded cloud recording downloads through Apify's maintained downloader.

Only the completed, cloud-stored file is used. YouTube's temporary stream URLs
are tied to the downloader's network and must not be fetched from Fly.
"""
from __future__ import annotations

import math
import os
from pathlib import Path
import re
import tempfile
import time
from urllib.parse import urlparse

import requests

API = 'https://api.apify.com/v2'
ACTOR = 'streamers~youtube-video-downloader'
SEARCH_ACTOR = 'streamers~youtube-scraper'
_ID = re.compile(r'^[A-Za-z0-9_-]{1,100}$')
_VIDEO = re.compile(r'^[A-Za-z0-9_-]{11}$')
_TERMINAL = {'SUCCEEDED', 'FAILED', 'ABORTED', 'TIMED-OUT'}


class AudioProviderError(Exception):
    def __init__(self, code: str):
        self.code = code
        super().__init__(code)  # Never include URLs, response bodies, or credentials.


class DownloadCancelled(Exception):
    pass


def _positive_env(name: str, default: float, maximum: float) -> float:
    try:
        value = float(os.environ.get(name, str(default)))
    except ValueError:
        raise AudioProviderError('provider_configuration') from None
    if not math.isfinite(value) or not 0 < value <= maximum:
        raise AudioProviderError('provider_configuration')
    return value


class ApifyAudio:
    def __init__(self, token: str | None = None, *, session=None):
        self.token = token if token is not None else os.environ.get('APIFY_TOKEN', '')
        if not self.token:
            raise AudioProviderError('provider_configuration')
        self.session = session or requests.Session()
        # Apify interprets zero as unlimited; a fractional setting must never
        # truncate to zero and remove the provider's runtime limit.
        self.timeout = math.ceil(_positive_env('CHORDLYZE_APIFY_TIMEOUT', 300, 900))
        self.max_charge = _positive_env('CHORDLYZE_APIFY_MAX_CHARGE_USD', 1, 5)
        self.max_bytes = int(_positive_env('CHORDLYZE_AUDIO_MAX_MB', 100, 250) * 1024 * 1024)

    def request(self, method: str, path: str, **kwargs):
        for attempt in range(3):
            try:
                return self._request_once(method, path, **kwargs)
            except AudioProviderError as error:
                if method != 'GET' or error.code != 'provider_connection' or attempt == 2:
                    raise
                time.sleep(2 ** attempt)

    def _request_once(self, method: str, path: str, **kwargs):
        # All authenticated requests stay on the fixed provider API origin.
        try:
            response = self.session.request(method, API + path,
                headers={'Authorization': 'Bearer ' + self.token},
                timeout=(10, 40), allow_redirects=False, **kwargs)
        except requests.RequestException:
            raise AudioProviderError('provider_connection') from None
        with response:
            if response.status_code in (401, 403):
                raise AudioProviderError('provider_authentication')
            if response.status_code in (402, 429):
                raise AudioProviderError('provider_limit')
            if response.status_code >= 500:
                raise AudioProviderError('provider_connection')
            if not 200 <= response.status_code < 300:
                raise AudioProviderError('provider_response')
            try:
                return response.json()
            except ValueError:
                raise AudioProviderError('provider_response') from None

    def run_actor(self, actor: str, payload: dict, *, run_id: str | None = None,
                  on_started=None, cancelled=lambda: False, max_charge: float | None = None) -> dict:
        if cancelled():
            raise DownloadCancelled()
        if run_id:
            if not isinstance(run_id, str) or not _ID.fullmatch(run_id):
                raise AudioProviderError('provider_response')
            run = self.run_response('GET', f'/actor-runs/{run_id}', expected_id=run_id)
        else:
            # POST is deliberately not retried: an ambiguous response must not
            # silently launch and bill for a second download.
            run = self.run_response('POST', f'/acts/{actor}/runs', params={
                # Apify grants one CPU core per 4096 MB; pay-per-event Actors
                # do not bill platform usage, so this only buys speed.
                'timeout': self.timeout, 'memory': 4096,
                'maxTotalChargeUsd': max_charge if max_charge is not None else self.max_charge,
            }, json=payload)
        run_id = run['id']
        if on_started:
            # Persist before polling so a replacement worker can reuse the run.
            on_started(run_id)
        deadline = time.monotonic() + self.timeout + 45
        while run.get('status') not in _TERMINAL:
            if cancelled():
                # Leave the bounded run available for the replacement worker.
                raise DownloadCancelled()
            if time.monotonic() >= deadline:
                try:
                    self.request('POST', f'/actor-runs/{run_id}/abort')
                except AudioProviderError:
                    pass
                raise AudioProviderError('provider_timeout')
            run = self.run_response('GET', f'/actor-runs/{run_id}', expected_id=run_id,
                                    params={'waitForFinish': 10})
            # The provider normally long-polls. Bound busy loops if it returns early.
            if run.get('status') not in _TERMINAL:
                time.sleep(1)
        if cancelled():
            raise DownloadCancelled()
        if run.get('status') == 'TIMED-OUT':
            raise AudioProviderError('provider_timeout')
        if run.get('status') != 'SUCCEEDED':
            raise AudioProviderError('provider_download')
        return run

    def run_response(self, method: str, path: str, *, expected_id: str | None = None, **kwargs) -> dict:
        response = self.request(method, path, **kwargs)
        run = response.get('data') if isinstance(response, dict) else None
        if (not isinstance(run, dict) or not isinstance(run.get('id'), str)
                or not _ID.fullmatch(run['id']) or (expected_id and run['id'] != expected_id)):
            raise AudioProviderError('provider_response')
        return run

    def items(self, run: dict, limit: int) -> list:
        dataset = run.get('defaultDatasetId', '')
        if not isinstance(dataset, str) or not _ID.fullmatch(dataset):
            raise AudioProviderError('provider_response')
        items = self.request('GET', f'/datasets/{dataset}/items', params={'clean': 'true', 'limit': limit})
        if not isinstance(items, list) or any(not isinstance(item, dict) for item in items):
            raise AudioProviderError('provider_response')
        return items

    def search(self, title: str, artist: str, *, checkpoint: dict | None = None,
               save_checkpoint=None, cancelled=lambda: False) -> list[dict]:
        run = self.run_actor(SEARCH_ACTOR, {
            'searchQueries': [f'{artist} {title}'.strip()], 'maxResults': 8,
            'maxResultsShorts': 0, 'maxResultStreams': 0, 'downloadSubtitles': False,
            'aiVideoDescription': False, 'aiVideoSummary': False,
        }, run_id=(checkpoint or {}).get('search_run_id'), cancelled=cancelled,
            on_started=(lambda value: save_checkpoint({'search_run_id': value})) if save_checkpoint else None,
            max_charge=.05)
        result = []
        for item in self.items(run, 8):
            duration = item.get('duration')
            if isinstance(duration, str):
                try:
                    parts = [float(part) for part in duration.split(':')]
                    duration = sum(value * 60 ** index for index, value in enumerate(reversed(parts)))
                except ValueError:
                    continue
            if not isinstance(duration, (float, int)) or not math.isfinite(duration) or duration <= 0:
                continue
            result.append({'id': item.get('id'), 'title': item.get('title') or '',
                           'channel': item.get('channelName') or '', 'duration': duration})
        return result

    def download(self, candidate: dict, duration: float, *, checkpoint: dict | None = None,
                 save_checkpoint=None, cancelled=lambda: False, source_info: dict | None = None) -> Path:
        video_id = candidate.get('id', '')
        if not isinstance(video_id, str) or not _VIDEO.fullmatch(video_id):
            raise AudioProviderError('provider_response')
        old_run = (checkpoint or {}).get('run_id') if (checkpoint or {}).get('video_id') == video_id else None
        run = self.run_actor(ACTOR, {
            'videos': [{'url': f'https://www.youtube.com/watch?v={video_id}'}],
            'storeInKVStore': True, 'preferredFormat': 'mp3', 'preferredQuality': '144p',
        }, run_id=old_run, cancelled=cancelled,
            on_started=(lambda value: save_checkpoint({'video_id': video_id, 'run_id': value,
                                                       'candidate': candidate})) if save_checkpoint else None)
        items = self.items(run, 2)
        if not isinstance(items, list) or len(items) != 1 or items[0].get('id') != video_id:
            raise AudioProviderError('provider_response')
        item = items[0]
        actual = item.get('durationSeconds')
        tolerance = max(2, min(3, duration * .01))
        if not isinstance(actual, (float, int)) or not math.isfinite(actual) or abs(actual - duration) > tolerance:
            raise AudioProviderError('recording_mismatch')
        path = self.download_file(item.get('downloadedFileUrl'), cancelled=cancelled)
        if source_info is not None:
            source_info.update(provider='apify', actor=ACTOR.replace('~', '/'),
                               run_id=run['id'], build_id=run.get('buildId'))
        return path

    def download_file(self, url: str, *, cancelled=lambda: False) -> Path:
        if not isinstance(url, str):
            raise AudioProviderError('provider_response')
        parsed = urlparse(url)
        # Inbound media never receives our account token. Reject arbitrary URLs,
        # embedded credentials and redirects before any request leaves this host.
        if (parsed.scheme != 'https' or parsed.netloc != 'api.apify.com' or parsed.query or parsed.fragment
                or not re.fullmatch(r'/v2/key-value-stores/[A-Za-z0-9_-]+/records/[^/]+', parsed.path)):
            raise AudioProviderError('provider_response')
        path = None
        try:
            with requests.get(url, stream=True, timeout=(10, 30), allow_redirects=False) as response:
                if response.status_code != 200:
                    raise AudioProviderError('provider_download')
                kind = response.headers.get('Content-Type', '').split(';')[0].strip()
                if not (kind.startswith('audio/') or kind == 'application/octet-stream'):
                    raise AudioProviderError('provider_response')
                length = response.headers.get('Content-Length')
                if length and int(length) > self.max_bytes:
                    raise AudioProviderError('recording_too_large')
                fd, name = tempfile.mkstemp(prefix='chordlyze-audio-', suffix='.mp3')
                path = Path(name)
                size = 0
                deadline = time.monotonic() + 120
                with os.fdopen(fd, 'wb') as output:
                    for chunk in response.iter_content(64 * 1024):
                        if cancelled():
                            raise DownloadCancelled()
                        if time.monotonic() >= deadline:
                            raise AudioProviderError('provider_timeout')
                        size += len(chunk)
                        if size > self.max_bytes:
                            raise AudioProviderError('recording_too_large')
                        output.write(chunk)
                if not size or (length is not None and size != int(length)):
                    raise AudioProviderError('provider_download')
                return path
        except BaseException as error:
            if path is not None:
                path.unlink(missing_ok=True)
            if isinstance(error, (requests.RequestException, ValueError)):
                raise AudioProviderError('provider_download') from None
            raise
