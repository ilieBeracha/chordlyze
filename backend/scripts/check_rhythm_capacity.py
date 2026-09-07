"""Exercise the maximum supported song length with real rhythm/structure models."""
import argparse
import json
from pathlib import Path
import resource
import sys
import tempfile
import time
import numpy as np
import soundfile as sf
from chordlyze_backend.analysis.beats import track_beats, validate_tempo
from chordlyze_backend.analysis.rhythm import worker

parser = argparse.ArgumentParser()
parser.add_argument('--seconds', type=int, default=1200)
parser.add_argument('--with-chords', action='store_true', help='Keep the production chord model resident during rhythm inference')
args = parser.parse_args()
if not 1 <= args.seconds <= 1200: parser.error('seconds must be 1..1200')
sr=22050
# Repeated pitched pulses ensure the real feature and model paths execute.
t=np.arange(sr)/sr
bar=sum(.08*np.sin(2*np.pi*f*t) for f in (261.63, 329.63, 392))*np.exp(-(t % .5)*5)
with tempfile.TemporaryDirectory() as temp:
    path=Path(temp)/'capacity.wav'
    sf.write(path,np.tile(bar,args.seconds),sr)
    if args.with_chords:
        from chordlyze_backend.analysis.ismir import warm
        warm()
    started=time.monotonic(); result=track_beats(path); elapsed=time.monotonic()-started
    validate_tempo(result,args.seconds)
    worker.close()
    if args.with_chords:
        from chordlyze_backend.analysis.ismir import close
        close()
    unit=1 if sys.platform=='darwin' else 1024
    cgroup_peak = Path('/sys/fs/cgroup/memory.peak')
    print(json.dumps(dict(audio_seconds=args.seconds,elapsed_seconds=elapsed,
        chord_model_resident=args.with_chords,
        container_peak_bytes=int(cgroup_peak.read_text()) if cgroup_peak.exists() else None,
        parent_peak_rss_bytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss*unit,
        child_peak_rss_bytes=resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss*unit,
        beat_count=len((result or {}).get('beats',[])),bar_count=len((result or {}).get('bars',[]))),indent=2))
