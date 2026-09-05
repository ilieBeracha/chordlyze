"""Private transcript process: prints word timestamps for one audio file as
JSON. Run by lyrics_align.transcribe_words; not a public entry point."""
from __future__ import annotations

import json
import os
import sys


def main() -> None:
    audio = sys.argv[1]
    language = sys.argv[2] if len(sys.argv) > 2 else None
    from faster_whisper import WhisperModel

    model = WhisperModel(os.environ.get('CHORDLYZE_WHISPER_MODEL', 'small'), device='cpu', compute_type='int8',
                         cpu_threads=int(os.environ.get('CHORDLYZE_TORCH_THREADS', '2')),
                         download_root=os.environ.get('CHORDLYZE_WHISPER_DIR') or None)
    segments, _ = model.transcribe(audio, language=language, word_timestamps=True, vad_filter=False,
                                   beam_size=1, condition_on_previous_text=False)
    words = [{'start': round(word.start, 2), 'end': round(word.end, 2), 'text': word.word.strip()}
             for segment in segments for word in segment.words or []]
    json.dump(words, sys.stdout)


if __name__ == '__main__':
    main()
