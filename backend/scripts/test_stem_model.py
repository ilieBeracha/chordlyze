"""Opt-in real-model/codec smoke test using only authored synthetic audio.
Run with the pinned stems interpreter, from backend; takes about a minute on a Mac.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import numpy as np
import soundfile as sf

backend = Path(__file__).resolve().parents[1]
os.environ.setdefault('TORCH_HOME', str(backend / '.stems/torch'))
with tempfile.TemporaryDirectory(prefix='stem-model-test-') as temporary:
    root = Path(temporary)
    rate = 44100
    time = np.arange(rate*24)/rate
    plucks = np.exp(-8*(time%.5))*(np.sin(2*np.pi*220*time)+.45*np.sin(2*np.pi*440*time)+.2*np.sin(2*np.pi*660*time))
    bass = .2*np.sin(2*np.pi*55*time)
    drums = .12*np.random.default_rng(13).normal(size=len(time))*np.exp(-40*(time%.5))
    mono = .24*plucks+bass+drums
    source = root/'source.wav'
    sf.write(source, np.column_stack((mono, mono*.93)), rate, subtype='PCM_16')
    subprocess.run([sys.executable, '-m', 'chordlyze_backend.analysis.stem_worker', str(source), str(root), 'guitar'], cwd=backend, check=True)
    parts = []
    durations = []
    for part in ('solo', 'backing'):
        path = root/f'{part}.m4a'
        output = subprocess.run(['ffmpeg', '-v', 'error', '-i', str(path), '-f', 'f32le', '-acodec', 'pcm_f32le', '-'], capture_output=True, check=True)
        parts.append(np.frombuffer(output.stdout, np.float32).reshape(-1, 2))
        metadata = subprocess.run(['ffprobe', '-v', 'error', '-show_format', '-of', 'json', str(path)], capture_output=True, check=True)
        durations.append(float(json.loads(metadata.stdout)['format']['duration']))
    assert len(parts[0]) == len(parts[1]) and abs(durations[0]-24) < .025 and durations[0] == durations[1]
    reference, _ = sf.read(source)
    combined = (parts[0]+parts[1])[:len(reference)]
    gain = float(np.sum(combined*reference)/np.sum(reference**2))
    correlation = float(np.corrcoef(combined.ravel(), reference.ravel())[0, 1])
    snr = float(10*np.log10(np.mean((gain*reference)**2)/np.mean((combined-gain*reference)**2)))
    assert correlation > .995 and snr > 25 and np.sqrt(np.mean(parts[0]**2)) > .001
    report = dict(fixture='24-second authored synthetic plucks, bass and percussion; crosses a 20-second processing boundary',
                  model='htdemucs_6s-5c90dfd2-v1', sample_rate=rate, input_frames=len(reference), decoded_aac_frames=len(parts[0]),
                  reconstructed_mix_correlation=round(correlation, 6), reconstructed_mix_snr_db=round(snr, 2), common_gain=round(gain, 6),
                  notes='Real model and codec test; not a perceptual quality evaluation. AAC decode padding is excluded from reconstruction; MP4 duration preserves playback length.')
    print(json.dumps(report, indent=2))
    if len(sys.argv) > 1:
        Path(sys.argv[1]).write_text(json.dumps(report, indent=2)+'\n')
