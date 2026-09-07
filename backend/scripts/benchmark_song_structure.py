"""Compare downbeats on all GuitarSet comp takes for players 04/05.

Legacy receives annotated chord changes (optimistic) for its 4/4 phase vote.
No section ground truth or pretrained-model independence is claimed.
"""
import argparse
import hashlib
import json
from pathlib import Path
import time
import numpy as np
import librosa
from chordlyze_backend.analysis.beats import track_beats


def counts(reference, estimated, tolerance=.07):
    i = j = hits = 0
    while i < len(reference) and j < len(estimated):
        if abs(reference[i]-estimated[j]) <= tolerance:
            hits += 1; i += 1; j += 1
        elif reference[i] < estimated[j]: i += 1
        else: j += 1
    return dict(hits=hits, reference=len(reference), estimated=len(estimated))


def summarize(rows):
    h, r, e = (sum(row[k] for row in rows) for k in ('hits', 'reference', 'estimated'))
    p, recall = h/e if e else 0, h/r if r else 0
    return dict(precision=p, recall=recall, f1=2*p*recall/(p+recall) if p+recall else 0,
                hits=h, reference=r, estimated=e)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--dataset', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    paths = sorted((args.dataset/'annotation').glob('0[45]_*_comp.jams'))
    if len(paths) != 60: raise RuntimeError(f'Expected all 60 comp takes, found {len(paths)}')
    rows = []
    for path in paths:
        audio = args.dataset/'audio_mono-mic'/f'{path.stem}_mic.wav'
        if not audio.exists(): raise FileNotFoundError(audio)
        annotation = json.loads(path.read_text())
        beat_ref = next(a['data'] for a in annotation['annotations'] if a['namespace'] == 'beat_position')
        chords = [a for a in annotation['annotations'] if a['namespace'] == 'chord'][-1]['data']
        reference = [b['time'] for b in beat_ref if b['value']['position'] == 1]
        started = time.monotonic()
        result = track_beats(audio)
        elapsed = time.monotonic()-started
        y, sr = librosa.load(audio, sr=22050)
        _, old_beats = librosa.beat.beat_track(y=y, sr=sr, units='time')
        votes = np.zeros(4)
        period = float(np.median(np.diff(old_beats))) if len(old_beats) > 1 else .5
        for chord in chords:
            if chord['value'] == 'N' or not len(old_beats): continue
            i = int(np.argmin(abs(old_beats-chord['time'])))
            if abs(old_beats[i]-chord['time']) <= period*.34: votes[i%4] += 1
        phase = int(np.argmax(votes))
        old = list(old_beats[phase::4]) if len(old_beats) >= 8 else []
        new = [t for t, p in zip((result or {}).get('beats', []), (result or {}).get('beat_positions', [])) if p == 1]
        rows.append(dict(take=path.stem, duration=len(y)/sr, seconds=elapsed,
                         annotation_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                         audio_sha256=hashlib.sha256(audio.read_bytes()).hexdigest(),
                         legacy=counts(reference, old), detected=counts(reference, new),
                         bars=len((result or {}).get('bars', [])), sections=len((result or {}).get('sections', []))))
        print(f'{len(rows)}/60 {path.stem}', flush=True)
    output = dict(dataset='GuitarSet microphone comp, players 04/05, all 60 takes', tolerance_seconds=.07,
                  limitations='Metronomic references, no section annotations, pretraining overlap not established; legacy uses annotated chords.',
                  legacy=summarize([r['legacy'] for r in rows]), detected=summarize([r['detected'] for r in rows]),
                  audio_seconds=sum(r['duration'] for r in rows), runtime_seconds=sum(r['seconds'] for r in rows),
                  source_sha256={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in
                      [Path('chordlyze_backend/analysis/beats.py'), Path('chordlyze_backend/analysis/structure.py'), Path('chordlyze_backend/analysis/rhythm.py'), Path('chordlyze_backend/analysis/rhythm_worker.py')]}, tracks=rows)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(output, indent=2)+'\n')
    print(json.dumps({k:v for k,v in output.items() if k != 'tracks'}, indent=2))

if __name__ == '__main__': main()
