"""Inspect or explicitly clear the configured active song library."""
import argparse
import json
import os
from pathlib import Path
from chordlyze_backend.song_jobs import reset_library

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true', help='Remove all active song analyses, aliases, lyrics and jobs.')
    arguments = parser.parse_args()
    directory = Path(os.environ.get('CHORDLYZE_CACHE', Path(__file__).resolve().parents[1] / 'analysis_cache'))
    print(json.dumps(reset_library(directory, apply=arguments.apply)))
