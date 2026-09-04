"""Measure a full-length take in the deployment runtime.

Run from backend with PYTHONPATH=. after installing both recognizers.
This uses generated audio and temporary files; it does not call the live API.
"""
import argparse
import json
import tempfile
import time
from pathlib import Path

import numpy as np
import soundfile as sf

from chordlyze_backend.analysis.engine import recognize_audio
from chordlyze_backend.analysis.ismir import close


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=int, default=600, choices=range(1, 601), metavar="1..600")
    args = parser.parse_args()
    sr = 44100
    t = np.arange(sr) / sr
    strike = np.zeros(sr)
    # Cmaj7 with bass, upper notes and decaying harmonics; repeat each second.
    for note in (48, 60, 64, 67, 71):
        frequency = 440 * 2 ** ((note - 69) / 12)
        for harmonic in range(1, 5):
            strike += np.sin(2 * np.pi * frequency * harmonic * t) / harmonic
    strike *= np.exp(-3 * t)
    strike *= .8 / np.max(np.abs(strike))
    with tempfile.TemporaryDirectory() as temp:
        wav = Path(temp) / "take.wav"
        sf.write(wav, np.tile(strike, 8), sr)
        # Keep the legacy preview model resident, as on a busy API instance.
        recognize_audio(wav, model="madmom")
        with sf.SoundFile(wav, "w", samplerate=sr, channels=1, subtype="PCM_16") as audio:
            for _ in range(args.seconds):
                audio.write(strike)
        start = time.monotonic()
        try:
            result = recognize_audio(wav, max_duration=600)
            assert result.duration == args.seconds and result.segments
            assert result.segments[-1].end <= args.seconds
            assert all(a.end <= b.start for a, b in zip(result.segments, result.segments[1:]))
            metrics = {"audio_seconds": result.duration,
                       "inference_seconds": round(time.monotonic() - start, 2),
                       "segments": len(result.segments), **result.metadata()}
            peak = Path("/sys/fs/cgroup/memory.peak")
            if peak.is_file():
                metrics["container_peak_mib"] = round(int(peak.read_text()) / 1024**2, 1)
            swap = Path("/sys/fs/cgroup/memory.swap.peak")
            if swap.is_file():
                metrics["container_swap_peak_mib"] = round(int(swap.read_text()) / 1024**2, 1)
            print(json.dumps(metrics, indent=2))
        finally:
            close()


if __name__ == "__main__":
    main()
