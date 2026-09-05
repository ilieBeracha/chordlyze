"""Timing plain lyrics from a word-timed transcript of the recording."""
from pathlib import Path
import threading
import urllib.error

import pytest

from chordlyze_backend import lyrics_align
from chordlyze_backend.lyrics_align import align_lyrics, language_hint, time_lines
import song_worker

LINES = ['Come up to meet you', 'Tell you I need you', 'Nobody said it was easy', 'Nobody said it was easy']


def words(text: str, start: float, step: float = 0.5) -> list[dict]:
    return [{'start': round(start + i * step, 2), 'end': round(start + i * step + .3, 2), 'text': w}
            for i, w in enumerate(text.split())]


def test_lines_take_the_time_of_their_first_sung_word_and_skip_the_intro():
    transcript = words('come up to meet you', 27.4) + words('tell you i need you', 41.0) \
        + words('nobody said it was easy', 80.1) + words('nobody said it was easy', 93.1)
    timed, matched, total = time_lines(LINES, transcript)
    assert [line['time'] for line in timed] == [27.4, 41.0, 80.1, 93.1]
    assert matched == total == 20
    assert timed[0]['words'][1] == {'time': 27.9, 'text': 'up'}
    assert timed[0]['text'] == LINES[0]


def test_punctuation_case_and_transcript_errors_do_not_break_matching():
    transcript = words("come up to meat you, tell you I'm sorry", 27.4) + words('nobody said it was easy', 80.1) \
        + words('nobody said it was easy', 93.1) + [{'start': 303.0, 'end': 303.2, 'text': 'you'}]
    timed, matched, total = time_lines(LINES, transcript)
    assert [line['time'] for line in timed] == [27.4, pytest.approx(29.9, abs=.5), 80.1, 93.1]
    assert matched < total
    unmatched = [w for w in timed[1]['words'] if w['text'] == 'need']
    assert unmatched and 29.9 <= unmatched[0]['time'] <= 80.1, 'unmatched words are interpolated between neighbours'


def test_lines_never_go_backwards_and_unplaced_edges_are_dropped():
    transcript = words('nobody said it was easy', 80.1) + words('nobody said it was easy', 93.1)
    timed, _, _ = time_lines(LINES, transcript)
    assert [line['text'] for line in timed] == LINES[2:]
    assert all(a['time'] <= b['time'] for a, b in zip(timed, timed[1:]))


def test_language_hint_from_script():
    assert language_hint(['שלום עולם']) == 'he'
    assert language_hint(['مرحبا']) == 'ar'
    assert language_hint(['Hello there']) is None


def test_alignment_refuses_a_poor_match_instead_of_guessing(tmp_path):
    audio = tmp_path / 'song.mp3'
    poor = lambda path, language: words('something completely different here', 10)
    stats = {}
    assert align_lyrics(audio, LINES, transcribe=poor, stats=stats) is None
    assert stats == {'matched_words': 0, 'lyric_words': 20, 'transcript_words': 4, 'placed_lines': 0, 'lines': 4}
    good = lambda path, language: words('come up to meet you tell you i need you nobody said it was easy nobody said it was easy', 27.4)
    timed = align_lyrics(audio, LINES, transcribe=good)
    assert timed and len(timed) == 4 and timed[0]['time'] == 27.4
    assert align_lyrics(audio, [], transcribe=good) is None


def test_transcript_process_failure_is_explicit(monkeypatch, tmp_path):
    class Failed:
        returncode = 1
        stdout = ''
        stderr = 'boom'
    monkeypatch.setattr(lyrics_align.subprocess, 'run', lambda *a, **kw: Failed())
    with pytest.raises(lyrics_align.AlignmentUnavailable, match='transcription failed'):
        lyrics_align.transcribe_words(tmp_path / 'song.mp3', None)


class Client:
    def __init__(self, lookup):
        self.lookup = lookup
        self.posted = []

    def get(self, path, params):
        assert path == '/lyrics' and params['title'] == 'Song' and params['duration'] == 200
        if isinstance(self.lookup, Exception):
            raise self.lookup
        return self.lookup

    def post(self, path, payload):
        self.posted.append((path, payload))
        return {'ok': True}


SONG = {'track_id': 'song', 'title': 'Song', 'artist': 'Band', 'duration': 200}


def test_worker_times_only_untimed_catalog_lyrics(tmp_path):
    aligned = [{'time': 27.4, 'text': 'Come up to meet you', 'words': [{'time': 27.4, 'text': 'Come'}]}]
    def align(audio, lines, stats=None):
        if stats is not None: stats.update(matched_words=1, lyric_words=9)
        return aligned if lines == ['Come up to meet you', 'Tell you I need you'] else None
    plain = {'synced': False, 'lines': [{'time': 12, 'text': 'Come up to meet you'}, {'time': 40, 'text': 'Tell you I need you'}]}
    client = Client(plain)
    assert song_worker.attach_lyrics(client, SONG, tmp_path / 'a.mp3', 'gen', align=align) == 'aligned'
    assert client.posted == [('/internal/jobs/lyrics', {'track_id': 'song', 'library_generation': 'gen',
                                                         'lines': aligned, 'aligner': lyrics_align.ALIGNER})]
    synced = Client({'synced': True, 'lines': plain['lines']})
    assert song_worker.attach_lyrics(synced, SONG, tmp_path / 'a.mp3', 'gen', align=align) == 'synced'
    missing = Client(urllib.error.HTTPError('u', 404, 'not found', {}, None))
    assert song_worker.attach_lyrics(missing, SONG, tmp_path / 'a.mp3', 'gen', align=align) == 'none'
    assert not synced.posted and not missing.posted
    stopping = threading.Event(); stopping.set()
    assert song_worker.attach_lyrics(Client(plain), SONG, tmp_path / 'a.mp3', 'gen', stopping, align=align) == 'skipped'
    poor = Client({'synced': False, 'lines': [{'time': 1, 'text': 'Other words'}]})
    assert song_worker.attach_lyrics(poor, SONG, tmp_path / 'a.mp3', 'gen', align=align) == 'unaligned matched_words=1 lyric_words=9'
    assert not poor.posted


def test_aligner_runs_in_the_background_and_deletes_audio_when_done(tmp_path):
    done = threading.Event()
    def align(audio, lines, stats=None):
        assert Path(audio).exists(), 'audio must survive until alignment runs'
        done.set()
        return None
    client = Client({'synced': False, 'lines': [{'time': 1, 'text': 'Some words'}]})
    aligner = song_worker.LyricsAligner(client, align=align, limit=1)
    audio = tmp_path / 'a.mp3'; audio.write_bytes(b'x')
    assert aligner.submit(SONG, audio, 'gen')
    assert done.wait(5)
    aligner.pending.join()
    assert not audio.exists()


def test_full_alignment_queue_drops_lyrics_not_charts(tmp_path):
    started, release = threading.Event(), threading.Event()
    def align(audio, lines, stats=None):
        started.set(); release.wait(5); return None
    aligner = song_worker.LyricsAligner(Client({'synced': False, 'lines': [{'time': 1, 'text': 'Some words'}]}),
                                        align=align, limit=1)
    first = tmp_path / 'first.mp3'; first.write_bytes(b'x')
    second = tmp_path / 'second.mp3'; second.write_bytes(b'x')
    third = tmp_path / 'third.mp3'; third.write_bytes(b'x')
    assert aligner.submit(SONG, first, 'gen') and started.wait(5)  # being aligned
    assert aligner.submit(SONG, second, 'gen')     # queued
    assert not aligner.submit(SONG, third, 'gen')  # queue full: caller keeps ownership
    release.set()
    aligner.pending.join()
    assert not first.exists() and not second.exists() and third.exists()


def test_published_chart_hands_audio_to_the_aligner(monkeypatch, tmp_path):
    import types
    audio = tmp_path / 'song.mp3'; audio.write_bytes(b'x')
    monkeypatch.setattr(song_worker, 'fetch_full_track', lambda *a, **kw: audio)
    monkeypatch.setattr(song_worker, 'recognize_audio', lambda *a, **kw: types.SimpleNamespace(
        duration=200.0, segments=[], metadata=lambda: {'model': 'ismir2019'}))
    monkeypatch.setattr(song_worker, 'track_beats', lambda path: None)
    handed = []
    class Aligner:
        def submit(self, song, path, generation):
            handed.append((song['track_id'], path, generation)); return True
    class Publisher:
        def post(self, path, payload=None): return {}
    job = {'id': 'job', 'lease': 'lease', 'generation': 'gen', 'song': dict(SONG)}
    assert song_worker.process_job(Publisher(), job, aligner=Aligner()) == 'ready'
    assert handed == [('song', audio, 'gen')] and audio.exists(), 'audio is kept for the aligner'
    assert song_worker.process_job(Publisher(), job) == 'ready'
    assert not audio.exists(), 'without an aligner the audio is deleted as before'
