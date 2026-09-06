"""Managed on-demand full-song worker. Only processes explicitly requested jobs."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import queue
import signal
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

from dotenv import load_dotenv
import numpy as np
import soundfile as sf
from chordlyze_backend.genre import lookup_genre
from chordlyze_backend.analysis.beats import track_beats
from chordlyze_backend.analysis.engine import recognize_audio
from chordlyze_backend.analysis.ismir import close, ismir_available, warm
from chordlyze_backend.fulltrack import fetch_full_track
from chordlyze_backend.audio_apify import ApifyAudio, AudioProviderError, DownloadCancelled
from chordlyze_backend.lyrics_align import ALIGNER, align_lyrics, transcribe_lyrics


class WorkerClient:
    def __init__(self, base: str, token: str):
        self.base, self.token = base.rstrip('/'), token

    def post(self, path: str, payload: dict | None = None) -> dict:
        request = urllib.request.Request(self.base + path, data=json.dumps(payload or {}).encode(),
                                         headers={'Content-Type': 'application/json',
                                                  'Authorization': 'Bearer ' + self.token})
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)

    def get(self, path: str, params: dict) -> dict:
        query = urllib.parse.urlencode({key: value for key, value in params.items() if value is not None})
        with urllib.request.urlopen(self.base + path + '?' + query, timeout=60) as response:
            return json.load(response)


def warm_recognizer() -> float:
    """Load the recognizer and run the JIT-compiled decode and beat paths once
    on silence, so the first real song does not pay start-up costs."""
    started = time.monotonic()
    warm()
    descriptor, name = tempfile.mkstemp(prefix='chordlyze-warmup-', suffix='.wav')
    os.close(descriptor)
    path = Path(name)
    try:
        sf.write(path, np.zeros(22050 * 4, dtype='float32'), 22050)
        recognize_audio(path, model='ismir2019', max_duration=10)
        track_beats(path)
    finally:
        path.unlink(missing_ok=True)
    return time.monotonic() - started


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


def attach_lyrics(client: WorkerClient, song: dict, audio: Path, generation: str,
                  stopping: threading.Event | None = None, align=align_lyrics,
                  transcribe=transcribe_lyrics) -> str:
    """After a chart is published: when the catalog has only untimed lyrics,
    time them from the recording; when it has none, keep the transcript as
    the lyrics, labeled as transcribed."""
    if stopping and stopping.is_set():
        return 'skipped'
    try:
        found = client.get('/lyrics', {'title': song['title'], 'artist': song.get('artist') or '',
                                       'duration': song.get('duration'), 'album': song.get('album')})
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        lines = transcribe(audio)
        if lines is None:
            return 'none'
        client.post('/internal/jobs/lyrics', {'track_id': song['track_id'], 'library_generation': generation,
                                              'lines': lines, 'aligner': ALIGNER, 'source': 'transcribed'})
        return 'transcribed'
    if found.get('synced') or found.get('instrumental'):
        return 'synced'
    stats: dict = {}
    timed = align(audio, [line.get('text') or '' for line in found.get('lines', [])], stats=stats)
    if timed is None:
        return 'unaligned ' + ' '.join(f'{key}={value}' for key, value in stats.items())
    client.post('/internal/jobs/lyrics', {'track_id': song['track_id'], 'library_generation': generation,
                                          'lines': timed, 'aligner': ALIGNER})
    return 'aligned'


class LyricsAligner:
    """Times plain lyrics on a background thread, so the worker keeps claiming
    songs and heartbeating while a transcript runs. Audio stays on disk until
    its alignment finishes; a full queue drops the alignment, not the chart."""

    def __init__(self, client: WorkerClient, stopping: threading.Event | None = None, *,
                 align=align_lyrics, limit: int = 4):
        self.client, self.stopping, self.align = client, stopping, align
        self.pending: queue.Queue = queue.Queue(maxsize=limit)
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def submit(self, song: dict, audio: Path, generation: str) -> bool:
        try:
            self.pending.put_nowait((song, audio, generation))
            return True
        except queue.Full:
            print('Lyrics skipped: alignment queue is full', flush=True)
            return False

    def _run(self) -> None:
        while True:
            song, audio, generation = self.pending.get()
            try:
                print('Lyrics ' + attach_lyrics(self.client, song, audio, generation, self.stopping,
                                                align=self.align), flush=True)
            except Exception as error:
                print(f'Lyrics alignment failed: {type(error).__name__}: {str(error)[:200]}', flush=True)
            finally:
                audio.unlink(missing_ok=True)
                self.pending.task_done()


def process_job(client: WorkerClient, job: dict, stopping: threading.Event | None = None,
                aligner: LyricsAligner | None = None) -> str:
    song = job['song']
    identity = {'track_id': song['track_id'], 'job_id': job['id'], 'lease': job['lease'],
                'library_generation': job['generation']}
    finished = threading.Event()
    abandoned = threading.Event()
    stage = ['downloading']
    checkpoint = dict(job.get('download_checkpoint') or {})

    def cancelled():
        return abandoned.is_set() or bool(stopping and stopping.is_set())

    def save_checkpoint(update):
        checkpoint.update(update)
        client.post('/internal/jobs/heartbeat', {**identity, 'stage': stage[0],
                                                 'download_checkpoint': checkpoint})

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
    phases: dict[str, float] = {}
    mark = time.monotonic()

    def phase(name: str) -> None:
        nonlocal mark
        phases[name] = round(time.monotonic() - mark)
        mark = time.monotonic()

    try:
        song = recording_metadata(song)
        if not song.get('duration'):
            client.post('/internal/jobs/finish', {**identity, 'state': 'unavailable'})
            return 'unavailable'
        source_info = {}
        audio = fetch_full_track(song['title'], song.get('artist') or '', song['duration'],
                                 source_info=source_info, checkpoint=checkpoint,
                                 save_checkpoint=save_checkpoint, cancelled=cancelled)
        phase('download')
        if cancelled():
            return 'abandoned'
        if audio is None:
            client.post('/internal/jobs/finish', {**identity, 'state': 'unavailable'})
            return 'unavailable'
        stage[0] = 'analyzing'
        client.post('/internal/jobs/heartbeat', {**identity, 'stage': stage[0]})
        recognition = recognize_audio(audio, model='ismir2019', max_duration=1200)
        phase('recognize')
        # Reject an incomplete download or a different edit before publishing.
        if abs(recognition.duration - song['duration']) > max(2, min(3, song['duration'] * .01)):
            client.post('/internal/jobs/finish', {**identity, 'state': 'unavailable'})
            return 'unavailable'
        if cancelled():
            return 'abandoned'
        tempo = track_beats(audio)
        phase('beats')
        try:
            genre = lookup_genre(song['title'], song.get('artist'), song['duration'], song.get('isrc'))
        except Exception as error:  # noqa: BLE001 - a missing genre must not lose the chart
            print(f'Genre lookup failed: {error}', flush=True)
            genre = None
        client.post('/analysis/submit', {
            **identity, **recognition.metadata(), 'title': song['title'],
            'artist': song.get('artist'), 'album': song.get('album'),
            'artwork': song.get('artwork'), 'isrc': song.get('isrc'),
            'song_duration': song['duration'], 'source': 'youtube', 'audio_source': source_info,
            'segments': [segment.to_dict() for segment in recognition.segments],
            'tempo': tempo, 'genre': genre,
        })
        # Timings only; never track metadata.
        print('Song phases ' + ' '.join(f'{name}={seconds}s' for name, seconds in phases.items()), flush=True)
        # The chart is published. Lyrics timing is an addition to it and must
        # not hold up the next song.
        if aligner is not None and aligner.submit(song, audio, job['generation']):
            audio = None  # The aligner deletes it when done.
        return 'ready'
    except DownloadCancelled:
        return 'abandoned'
    except AudioProviderError as error:
        try:
            state = 'unavailable' if error.code == 'recording_mismatch' else 'failed'
            client.post('/internal/jobs/finish', {**identity, 'state': state, 'error_code': error.code})
        except Exception:
            pass
        print('Recording provider: ' + error.code, flush=True)
        return state
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


def claim_loop(client: WorkerClient, stopping: threading.Event, aligner: LyricsAligner | None,
               *, once: bool = False, process=None) -> None:
    process = process or process_job
    while not stopping.is_set():
        try:
            job = client.post('/internal/jobs/claim').get('job')
            if job:
                started = time.monotonic()
                result = process(client, job, stopping, aligner)
                print(f'Song request {result} ({time.monotonic() - started:.0f}s)', flush=True)
            elif not once:
                stopping.wait(3)
        except Exception as error:
            print(f'Analysis service unavailable ({type(error).__name__}); reconnecting.', flush=True)
            stopping.wait(15)
        if once:
            break


def run_loops(client: WorkerClient, stopping: threading.Event, aligner: LyricsAligner | None,
              *, concurrency: int, once: bool = False, process=None) -> None:
    """Several songs at once: a slow recording download must not hold every
    other request. Chord inference itself is serialized by the recognizer."""
    threads = [threading.Thread(target=claim_loop, args=(client, stopping, aligner),
                                kwargs={'once': once, 'process': process}, daemon=True, name=f'claim-{index}')
               for index in range(max(1, concurrency))]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--env', type=Path, default=Path(__file__).with_name('.env.worker'))
    parser.add_argument('--once', action='store_true')
    args = parser.parse_args()
    load_dotenv(args.env)
    token = os.environ.get('CHORDLYZE_WORKER_TOKEN')
    if not token or not ismir_available():
        raise SystemExit('Configure the worker token and install the pinned recognizer before starting.')
    if os.environ.get('CHORDLYZE_AUDIO_PROVIDER') == 'apify':
        ApifyAudio()  # Validate credentials and limits before claiming any jobs.
    print(f'Recognizer ready in {warm_recognizer():.0f}s', flush=True)
    client = WorkerClient(os.environ.get('CHORDLYZE_API_URL', 'https://chordlyze-api.fly.dev'), token)
    stopping = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stopping.set())
    signal.signal(signal.SIGINT, lambda *_: stopping.set())
    aligner = LyricsAligner(client, stopping)
    concurrency = 1 if args.once else int(os.environ.get('CHORDLYZE_WORKER_CONCURRENCY', '3'))
    try:
        run_loops(client, stopping, aligner, concurrency=concurrency, once=args.once)
    finally:
        close()


if __name__ == '__main__':
    main()
