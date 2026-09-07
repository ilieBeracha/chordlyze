"""Pinned Demucs subprocess. Context windows bound memory independently of song length."""
from __future__ import annotations
import argparse
from pathlib import Path
import subprocess
import tempfile


def separate(source: Path, destination: Path, instrument: str):
    import numpy as np
    import soundfile as sf
    import torch
    from demucs.pretrained import get_model
    from demucs.apply import apply_model

    torch.set_num_threads(2)
    model = get_model('htdemucs_6s').eval()
    index = model.sources.index(instrument)
    rate = 44100
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='stem-inference-') as directory:
        directory = Path(directory)
        decoded = directory / 'input.wav'
        subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-y', '-i', str(source), '-vn',
                        '-ac', '2', '-ar', str(rate), '-c:a', 'pcm_f32le', str(decoded)], check=True, timeout=120)
        with sf.SoundFile(decoded) as audio:
            if not 0 < len(audio) <= rate * 1200:
                raise ValueError('Audio exceeds duration limit')
            # Write each central 20 seconds once, with 4 seconds of model context
            # on both sides. Crossfade overlapping predictions at every boundary.
            block, context = rate * 20, rate * 4
            solo_path, backing_path = directory / 'solo.wav', directory / 'backing.wav'
            peak = 1.0
            previous = None
            with sf.SoundFile(solo_path, 'w', samplerate=rate, channels=2, subtype='FLOAT') as solo_file, \
                 sf.SoundFile(backing_path, 'w', samplerate=rate, channels=2, subtype='FLOAT') as backing_file:
                for start in range(0, len(audio), block):
                    left, right = max(0, start-context), min(len(audio), start+block+context)
                    audio.seek(left)
                    mix = audio.read(right-left, dtype='float32', always_2d=True)
                    tensor = torch.from_numpy(mix.T.copy())
                    reference = tensor.mean(0)
                    mean, std = reference.mean(), reference.std().clamp(min=1e-6)
                    with torch.inference_mode():
                        predictions = apply_model(model, ((tensor-mean)/std)[None], shifts=1,
                                                  split=True, segment=7, overlap=.25, progress=False)
                        part = (predictions[0, index] * std + mean).T.numpy().copy()
                    del predictions, tensor
                    offset = start-left
                    end = min(block, len(audio)-start)
                    output = part[offset:offset+end].copy()
                    if previous is not None:
                        overlap = min(len(previous), len(output))
                        fade = np.linspace(0, 1, overlap, dtype=np.float32)[:, None]
                        output[:overlap] = previous[:overlap]*(1-fade) + output[:overlap]*fade
                    previous = part[offset+end:].copy()
                    original = mix[offset:offset+end]
                    backing = original-output
                    peak = max(peak, float(np.abs(output).max()), float(np.abs(backing).max()), float(np.abs(original).max()))
                    solo_file.write(output); backing_file.write(backing)
                    print(f'processed {start+end}/{len(audio)} samples', flush=True)
        # Identical gain and timestamps preserve the full mix when summed.
        gain = .95 / peak
        for name in ('solo', 'backing'):
            subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-y', '-i', str(directory / f'{name}.wav'),
                            '-af', f'volume={gain:.12f}', '-c:a', 'aac', '-b:a', '256k',
                            '-movflags', '+faststart', str(destination / f'{name}.m4a')], check=True, timeout=120)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    parser.add_argument('instrument', choices=['guitar', 'bass', 'drums', 'vocals', 'piano'])
    arguments = parser.parse_args()
    separate(arguments.source, arguments.destination, arguments.instrument)
