"""Timing plain lyrics from a word-timed transcript of the recording."""
from pathlib import Path
import threading
import urllib.error

import pytest

from chordlyze_backend import lyrics_align
from chordlyze_backend.lyrics_align import align_lyrics, language_hint, time_lines, transcribed_lines
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


def test_repeated_lines_land_on_their_own_occurrence():
    """The greedy matcher used to time "gonna" from the first chorus and
    "give" from the second, eight seconds later, because the longest common
    block won. In-order alignment with gap costs keeps each line together."""
    lines = ["I'm gonna give you my heart", 'Cause you light up the path', "I'm gonna give you my heart"]
    transcript = words("i'm gonna give you my heart", 17.4) + words('cause you light up the path', 37.6) \
        + words("i'm gonna give you my heart", 122.2)
    timed, matched, total = time_lines(lines, transcript)
    assert matched == total
    first = [w['time'] for w in timed[0]['words']]
    assert first == [17.4, 17.9, 18.4, 18.9, 19.4, 19.9], 'the first chorus stays within its own two seconds'
    assert [w['time'] for w in timed[2]['words']][0] == 122.2
    # A transcript that misses a word in the middle still keeps the line together.
    gappy = words("i'm gonna you my heart", 17.4) + words('cause you light up the path', 37.6) \
        + words("i'm gonna give you my heart", 122.2)
    timed, _, _ = time_lines(lines, gappy)
    give = next(w for w in timed[0]['words'] if w['text'] == 'give')
    assert 17.9 < give['time'] < 18.5, 'the missing word is interpolated inside its line, not fetched from the later chorus'


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
        lyrics_align.transcribe_words_local(tmp_path / 'song.mp3', None)


def test_groq_transcription_maps_words_and_waits_out_a_rate_limit(monkeypatch, tmp_path):
    audio = tmp_path / 'song.mp3'; audio.write_bytes(b'x')
    compact = tmp_path / 'song-speech.mp3'
    def fake_ffmpeg(command, **kw):
        Path(command[-1]).write_bytes(b'small')
        class Done: returncode = 0; stderr = ''
        return Done()
    monkeypatch.setattr(lyrics_align.subprocess, 'run', fake_ffmpeg)
    monkeypatch.setenv('GROQ_API_KEY', 'k')
    calls, waits = [], []
    class Response:
        def __init__(self, status, body=None, retry=None):
            self.status_code, self._body, self.headers = status, body, {'Retry-After': retry} if retry else {}
        def json(self): return self._body
    body = {'words': [{'word': ' Come', 'start': 27.4, 'end': 27.6}, {'word': 'up', 'start': 27.7, 'end': 27.9},
                      {'word': 'later', 'start': 40.0, 'end': 40.3}],
            'segments': [{'id': 0, 'start': 27.0, 'end': 30.0, 'avg_logprob': -0.1},
                         {'id': 1, 'start': 39.0, 'end': 42.0, 'avg_logprob': -2.0}]}
    responses = [Response(429, retry='2'), Response(200, body)]
    def post(url, headers, data, files, timeout):
        calls.append((url, headers['Authorization'], dict(data), files['file'][0]))
        return responses.pop(0)
    words = lyrics_align.transcribe_words_groq(audio, 'he', post=post, sleep=waits.append)
    assert waits == [2.0] and len(calls) == 2
    assert calls[0][1] == 'Bearer k' and calls[0][2]['language'] == 'he' and calls[0][3] == 'song-speech.mp3'
    assert words[0] == {'start': 27.4, 'text': 'Come', 'segment': 0, 'p': 0.905}
    assert words[2]['segment'] == 1 and words[2]['p'] == 0.135
    assert not compact.exists(), 'the compact upload copy is removed'
    monkeypatch.delenv('GROQ_API_KEY')
    with pytest.raises(lyrics_align.AlignmentUnavailable, match='GROQ_API_KEY'):
        lyrics_align.transcribe_words_groq(audio, None, post=post)
    monkeypatch.setenv('GROQ_API_KEY', 'k')
    responses[:] = [Response(401)]
    with pytest.raises(lyrics_align.AlignmentUnavailable, match='API key'):
        lyrics_align.transcribe_words_groq(audio, None, post=post)


def test_transcriber_selection(monkeypatch, tmp_path):
    monkeypatch.setattr(lyrics_align, 'TRANSCRIBER', 'nowhere')
    with pytest.raises(lyrics_align.AlignmentUnavailable, match='unknown transcriber'):
        lyrics_align.transcribe_words(tmp_path / 'song.mp3', None)
    monkeypatch.setattr(lyrics_align, 'TRANSCRIBER', 'groq')
    monkeypatch.delenv('GROQ_API_KEY', raising=False)
    with pytest.raises(lyrics_align.AlignmentUnavailable, match='GROQ_API_KEY'):
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
    # Catalog line times are not word times: synced lines are aligned too.
    synced = Client({'synced': True, 'lines': plain['lines']})
    assert song_worker.attach_lyrics(synced, SONG, tmp_path / 'a.mp3', 'gen', align=align) == 'aligned'
    assert synced.posted and synced.posted[0][1]['lines'] == aligned
    worded = Client({'synced': True, 'lines': [{'time': 12, 'text': 'Come up to meet you', 'words': [{'time': 12, 'text': 'Come'}]}]})
    assert song_worker.attach_lyrics(worded, SONG, tmp_path / 'a.mp3', 'gen', align=align) == 'synced'
    instrumental = Client({'synced': True, 'instrumental': True, 'lines': []})
    assert song_worker.attach_lyrics(instrumental, SONG, tmp_path / 'a.mp3', 'gen', align=align) == 'instrumental'
    missing = Client(urllib.error.HTTPError('u', 404, 'not found', {}, None))
    assert song_worker.attach_lyrics(missing, SONG, tmp_path / 'a.mp3', 'gen', align=align,
                                     transcribe=lambda audio: None) == 'none'
    assert not worded.posted and not instrumental.posted and not missing.posted
    disagreeing = Client({'synced': True, 'lines': [{'time': 1, 'text': 'Other words'}]})
    assert song_worker.attach_lyrics(disagreeing, SONG, tmp_path / 'a.mp3', 'gen', align=align) == 'synced unaligned matched_words=1 lyric_words=9'
    assert not disagreeing.posted, 'catalog line times stay when the recording disagrees'
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


def test_published_chart_hands_audio_to_the_aligner(monkeypatch, tmp_path, capsys):
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
    assert 'Song phases download=' in capsys.readouterr().out, 'phase timings are logged, numbers only'
    assert song_worker.process_job(Publisher(), job) == 'ready'
    assert not audio.exists(), 'without an aligner the audio is deleted as before'


def test_worker_processes_several_songs_at_once():
    import time
    jobs = [{'id': 'a'}, {'id': 'b'}, {'id': 'c'}]
    lock = threading.Lock()
    class Claims:
        def post(self, path, payload=None):
            assert path == '/internal/jobs/claim'
            with lock:
                return {'job': jobs.pop(0) if jobs else None}
    active, peak, seen = [0], [0], []
    def process(client, job, stopping, aligner):
        with lock:
            active[0] += 1; peak[0] = max(peak[0], active[0]); seen.append(job['id'])
        time.sleep(.1)
        with lock:
            active[0] -= 1
        if not jobs: stopping.set()
        return 'ready'
    stopping = threading.Event()
    song_worker.run_loops(Claims(), stopping, None, concurrency=3, process=process)
    assert sorted(seen) == ['a', 'b', 'c'] and peak[0] >= 2, 'downloads overlap instead of queueing serially'


def spoken(text, start, segment, p=0.9):
    return [{**w, 'p': p, 'segment': segment} for w in words(text, start)]


def test_transcript_becomes_lines_per_segment_with_long_ones_split():
    transcript = spoken('come up to meet you tell you i need', 27.4, 0) \
        + spoken('nobody said it was easy oh it is such a shame for us to part', 80.1, 1)
    lines = transcribed_lines(transcript)
    assert [l['text'] for l in lines] == ['come up to meet you tell you i need',
                                          'nobody said it was easy oh it is such', 'a shame for us to part']
    assert lines[0]['time'] == 27.4 and lines[1]['time'] == 80.1 and lines[2]['words'][0]['text'] == 'a'
    assert all(len(l['words']) <= 9 for l in lines)


def test_short_or_unsure_transcripts_are_not_shown_as_lyrics():
    assert transcribed_lines(spoken('just a few words here', 10, 0)) is None
    assert transcribed_lines(spoken('one two three four five six seven eight nine ten eleven twelve', 10, 0, p=.3)) is None
    assert transcribed_lines(spoken('one two three four five six seven eight nine ten eleven twelve', 10, 0)) is not None


def test_worker_keeps_the_transcript_when_the_catalog_has_nothing(tmp_path):
    missing = Client(urllib.error.HTTPError('u', 404, 'not found', {}, None))
    lines = [{'time': 27.4, 'text': 'come up to meet you', 'words': [{'time': 27.4, 'text': 'come'}]}]
    assert song_worker.attach_lyrics(missing, SONG, tmp_path / 'a.mp3', 'gen', align=lambda *a, **k: None,
                                     transcribe=lambda audio: lines) == 'transcribed'
    assert missing.posted == [('/internal/jobs/lyrics', {'track_id': 'song', 'library_generation': 'gen',
                                                          'lines': lines, 'aligner': lyrics_align.ALIGNER,
                                                          'source': 'transcribed'})]
    quiet = Client(urllib.error.HTTPError('u', 404, 'not found', {}, None))
    assert song_worker.attach_lyrics(quiet, SONG, tmp_path / 'a.mp3', 'gen', align=lambda *a, **k: None,
                                     transcribe=lambda audio: None) == 'none'
    assert not quiet.posted


def test_lyrics_job_times_words_without_re_analyzing(monkeypatch, tmp_path, capsys):
    """A lyrics job fetches the recording, aligns, finishes; it never recognizes chords."""
    audio = tmp_path / 'song.mp3'; audio.write_bytes(b'x')
    monkeypatch.setattr(song_worker, 'fetch_full_track', lambda *a, **kw: audio)
    monkeypatch.setattr(song_worker, 'recognize_audio', lambda *a, **kw: (_ for _ in ()).throw(AssertionError('no recognition')))
    posted = []
    class Client:
        def post(self, path, payload=None):
            posted.append((path, payload)); return {}
        def get(self, path, params):
            return {'synced': False, 'lines': [{'time': 1, 'text': 'Some words'}]}
    monkeypatch.setattr(song_worker, 'align_lyrics', lambda audio, lines, stats=None: [{'time': 1.2, 'text': 'Some words',
                                                                                        'words': [{'time': 1.2, 'text': 'Some'}, {'time': 1.7, 'text': 'words'}]}])
    job = {'id': 'job', 'lease': 'lease', 'generation': 'gen', 'kind': 'lyrics', 'song': dict(SONG)}
    assert song_worker.process_job(Client(), job) == 'ready'
    lyrics = [p for path, p in posted if path == '/internal/jobs/lyrics']
    assert len(lyrics) == 1 and lyrics[0]['lines'][0]['words'][1]['text'] == 'words'
    finish = [p for path, p in posted if path == '/internal/jobs/finish']
    assert finish == [{'track_id': 'song', 'job_id': 'job', 'lease': 'lease', 'library_generation': 'gen',
                       'state': 'ready', 'message': 'Lyrics aligned'}]
    assert not any(path == '/analysis/submit' for path, _ in posted), 'the chart is not re-published'
    assert not audio.exists()
    assert 'Lyrics job aligned' in capsys.readouterr().out


def test_lyrics_lookup_retries_a_503_and_lines_are_made_publishable(tmp_path):
    aligned = [{'time': 40, 'text': 'Second', 'words': [{'time': 40, 'text': 'Second'}]},
               {'time': 27.4, 'text': 'Come up', 'words': [{'time': 27.4, 'text': 'Come'}, {'time': 27.9, 'text': ''}]},
               {'time': 30, 'text': '   ', 'words': []}]
    answers = [urllib.error.HTTPError('u', 503, 'down', {}, None), urllib.error.HTTPError('u', 503, 'down', {}, None),
               {'synced': False, 'lines': [{'time': 12, 'text': 'Come up'}, {'time': 40, 'text': 'Second'}]}]
    class Flaky(Client):
        def get(self, path, params):
            answer = answers.pop(0)
            if isinstance(answer, Exception):
                raise answer
            return answer
    client = Flaky(None)
    waits = []
    outcome = song_worker.attach_lyrics(client, SONG, tmp_path / 'a.mp3', 'gen',
                                        align=lambda audio, lines, stats=None: aligned, sleep=waits.append)
    assert outcome == 'aligned' and waits == [song_worker.LYRICS_LOOKUP_PAUSE] * 2
    posted = client.posted[0][1]['lines']
    assert [line['time'] for line in posted] == [27.4, 40], 'lines are in time order and blank lines dropped'
    assert posted[0]['words'] == [{'time': 27.4, 'text': 'Come'}], 'empty words are dropped'
    assert 'words' not in posted[1] or posted[1]['words'] == [{'time': 40.0, 'text': 'Second'}]
    always_down = Flaky(None)
    answers[:] = [urllib.error.HTTPError('u', 503, 'down', {}, None)] * 3
    with pytest.raises(urllib.error.HTTPError):
        song_worker.attach_lyrics(always_down, SONG, tmp_path / 'a.mp3', 'gen',
                                  align=lambda *a, **k: aligned, sleep=waits.append)
    assert len(waits) == 4, 'three attempts, then the error surfaces'
