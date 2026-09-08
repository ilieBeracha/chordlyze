"""Decode once, verify full recording PCM identity, infer only a contextual crop."""
import hashlib
from pathlib import Path
import tempfile
import wave
from .engine import _decode_to_wav, recognize_audio, AudioDecodeError


class RecordingMismatch(AudioDecodeError):
    pass


def recognize_passage(audio, job):
    with tempfile.TemporaryDirectory(prefix='chordlyze-passage-') as temporary:
        root = Path(temporary); full = root/'full.wav'; crop = root/'passage.wav'
        _decode_to_wav(Path(audio), full)
        with wave.open(str(full), 'rb') as source:
            rate = source.getframerate(); frames = source.getnframes()
            digest = hashlib.sha256()
            while chunk := source.readframes(65536): digest.update(chunk)
            if digest.hexdigest() != job['audio_sha256']:
                raise RecordingMismatch('The recording does not match the analyzed song. No chords were changed.')
            start, end = job['start'], job['end']
            lo, hi = max(0, int((start-4)*rate)), min(frames, int((end+4)*rate))
            source.setpos(lo)
            with wave.open(str(crop), 'wb') as target:
                target.setparams(source.getparams()); target.writeframes(source.readframes(hi-lo))
        recognized = recognize_audio(crop, max_duration=38.1, review=True, passage=True)
        offset = lo/rate
        segments = [dict(start=max(start,s.start+offset), end=min(end,s.end+offset), label=s.label)
                    for s in recognized.segments if s.start+offset < end and s.end+offset > start]
        review = [{**r, 'start': max(start,r['start']+offset), 'end': min(end,r['end']+offset)}
                  for r in recognized.review or [] if r['start']+offset < end and r['end']+offset > start]
        return {'audio_sha256': digest.hexdigest(), 'segments': segments, 'chord_review': review}
