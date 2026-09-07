"""Private JSON-lines inference protocol; checkpoint loading never uses the network."""
import contextlib
import hashlib
import json
import os
import sys
import numpy as np
from .rhythm import CHECKPOINT_SHA256, checkpoint_path


def main():
    try:
        path = checkpoint_path()
        if hashlib.sha256(path.read_bytes()).hexdigest() != CHECKPOINT_SHA256:
            raise ValueError('rhythm checkpoint hash mismatch')
        with contextlib.redirect_stdout(sys.stderr):
            import torch
            from beat_this.inference import Audio2Beats
            torch.set_num_threads(int(os.environ.get('CHORDLYZE_TORCH_THREADS', '2')))
            model = Audio2Beats(checkpoint_path=str(path), device='cpu', dbn=False)
        print(json.dumps({'ready': True}), flush=True)
        if '--check' in sys.argv: return
        for line in sys.stdin:
            try:
                request = json.loads(line)
                y = np.load(request['path'], allow_pickle=False)
                if y.ndim != 1 or not 0 < len(y) <= 22050*1201 or not np.isfinite(y).all():
                    raise ValueError('invalid rhythm audio')
                with contextlib.redirect_stdout(sys.stderr):
                    beats, downbeats = model(y, 22050)
                duration = len(y)/22050
                beats = sorted(set(round(float(t), 3) for t in beats if 0 <= t < duration))
                downbeats = sorted(set(round(float(t), 3) for t in downbeats if 0 <= t < duration))
                print(json.dumps(dict(beats=beats, downbeats=downbeats), allow_nan=False), flush=True)
            except Exception as exc:
                print(json.dumps({'error': str(exc)}), flush=True)
    except Exception as exc:
        print(json.dumps({'error': str(exc)}), flush=True)
        raise SystemExit(1)

if __name__ == '__main__': main()
