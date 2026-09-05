"""Managed on-demand full-song worker. Only processes explicitly requested jobs."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import signal
import threading
import urllib.error
import urllib.parse
import urllib.request

from dotenv import load_dotenv
from chordlyze_backend.analysis.beats import track_beats
from chordlyze_backend.analysis.engine import recognize_audio
from chordlyze_backend.analysis.ismir import close, ismir_available
from chordlyze_backend.fulltrack import fetch_full_track


class WorkerClient:
    def __init__(self, base: str, token: str):
        self.base, self.token = base.rstrip('/'), token

    def post(self, path: str, payload: dict | None = None) -> dict:
        request = urllib.request.Request(self.base + path, data=json.dumps(payload or {}).encode(),
                                         headers={'Content-Type': 'application/json',
                                                  'Authorization': 'Bearer ' + self.token})
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)


def recording_metadata(song: dict) -> dict:
    """Keep supplied recording metadata; exact iTunes ID fills missing values."""
    if song.get('duration') and song.get('artist'):
        return song
    if song.get('itunes_id'):
        url = f"https://itunes.apple.com/lookup?id={song['itunes_id']}&entity=song"
    else:
        query = urllib.parse.urlencode({'term': f"{song['title']} {song.get('artist') or ''}",
                                        'entity': 'song', 'limit': 5})
        url = 'https://itunes.apple.com/search?' + query
    with urllib.request.urlopen(url, timeout=15) as response:
        candidates = json.load(response).get('results', [])
    from chordlyze_backend.main import score_candidate
    matches = []
    for candidate in candidates:
        duration = (candidate.get('trackTimeMillis') or 0) / 1000
        comparable = {**candidate, 'duration': duration}
        score = score_candidate(comparable, song['title'], song.get('artist') or '', song.get('duration'))
        if duration and (candidate.get('trackId') == song.get('itunes_id') or score >= .75):
            matches.append((score, candidate))
    if not matches:
        return song
    match = max(matches, key=lambda pair: pair[0])[1]
    return {**song, 'duration': song.get('duration') or match['trackTimeMillis'] / 1000,
            'artist': song.get('artist') or match.get('artistName', ''),
            'album': song.get('album') or match.get('collectionName'),
            'artwork': song.get('artwork') or match.get('artworkUrl100')}


def process_job(client: WorkerClient, job: dict) -> str:
    song = job['song']
    identity = {'track_id': song['track_id'], 'job_id': job['id'], 'lease': job['lease'],
                'library_generation': job['generation']}
    finished = threading.Event()
    abandoned = threading.Event()
    stage = ['downloading']

    def heartbeat():
        while not finished.wait(15):
            try:
                client.post('/internal/jobs/heartbeat', {**identity, 'stage': stage[0]})
            except urllib.error.HTTPError as error:
                if error.code in (401, 409):
                    abandoned.set()
                    return
            except OSError:
                pass  # Lease expiry on the server bounds recovery after a disconnect.

    pulse = threading.Thread(target=heartbeat, daemon=True)
    pulse.start()
    audio = None
    try:
        song = recording_metadata(song)
        if not song.get('duration'):
            client.post('/internal/jobs/finish', {**identity, 'state': 'unavailable'})
            return 'unavailable'
        source_info = {}
        audio = fetch_full_track(song['title'], song.get('artist') or '', song['duration'], source_info=source_info)
        if abandoned.is_set():
            return 'abandoned'
        if audio is None:
            client.post('/internal/jobs/finish', {**identity, 'state': 'unavailable'})
            return 'unavailable'
        stage[0] = 'analyzing'
        client.post('/internal/jobs/heartbeat', {**identity, 'stage': stage[0]})
        recognition = recognize_audio(audio, model='ismir2019', max_duration=1200)
        # Reject an incomplete download or a different edit before publishing.
        if abs(recognition.duration - song['duration']) > max(2, min(3, song['duration'] * .01)):
            client.post('/internal/jobs/finish', {**identity, 'state': 'unavailable'})
            return 'unavailable'
        if abandoned.is_set():
            return 'abandoned'
        client.post('/analysis/submit', {
            **identity, **recognition.metadata(), 'title': song['title'],
            'artist': song.get('artist'), 'album': song.get('album'),
            'artwork': song.get('artwork'), 'isrc': song.get('isrc'),
            'song_duration': song['duration'], 'source': 'youtube', 'audio_source': source_info,
            'segments': [segment.to_dict() for segment in recognition.segments],
            'tempo': track_beats(audio),
        })
        return 'ready'
    except Exception:
        # Do not write track metadata, downloaded audio, tokens or lyrics to logs.
        try:
            client.post('/internal/jobs/finish', {**identity, 'state': 'failed'})
        except Exception:
            pass
        return 'failed'
    finally:
        finished.set()
        pulse.join(timeout=1)
        if audio is not None:
            audio.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--env', type=Path, default=Path(__file__).with_name('.env.worker'))
    parser.add_argument('--once', action='store_true')
    args = parser.parse_args()
    load_dotenv(args.env)
    token = os.environ.get('CHORDLYZE_WORKER_TOKEN')
    if not token or not ismir_available():
        raise SystemExit('Configure the worker token and install the pinned recognizer before starting.')
    client = WorkerClient(os.environ.get('CHORDLYZE_API_URL', 'https://chordlyze-api.fly.dev'), token)
    stopping = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stopping.set())
    signal.signal(signal.SIGINT, lambda *_: stopping.set())
    try:
        while not stopping.is_set():
            try:
                job = client.post('/internal/jobs/claim').get('job')
                if job:
                    print('Song request ' + process_job(client, job), flush=True)
                elif not args.once:
                    stopping.wait(3)
            except Exception:
                print('Analysis service unavailable; reconnecting.', flush=True)
                stopping.wait(15)
            if args.once:
                break
    finally:
        close()


if __name__ == '__main__':
    main()
