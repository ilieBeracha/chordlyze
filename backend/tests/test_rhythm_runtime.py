"""Runtime failures cannot turn an absent model into fabricated bar data."""
import numpy as np
import pytest
from chordlyze_backend.analysis.rhythm import RhythmProcess, RhythmUnavailable


def test_missing_runtime_is_explicit_and_leaves_no_worker(tmp_path, monkeypatch):
    monkeypatch.setenv('CHORDLYZE_RHYTHM_DIR', str(tmp_path))
    process = RhythmProcess(timeout=1)
    with pytest.raises(RhythmUnavailable, match='not installed'):
        process.predict(np.zeros(22050))
    assert process._process is None


def test_resident_model_reuses_process_and_recovers_after_exit():
    process = RhythmProcess(timeout=30)
    try:
        # Low-energy real input exercises model output without a network download.
        y = np.zeros(22050*2, dtype=np.float32)
        first = process.predict(y)
        pid = process._process.pid
        second = process.predict(y)
        assert first == second and process._process.pid == pid
        process._process.kill(); process._process.wait()
        assert process.predict(y) == first
        assert process._process.pid != pid
    finally:
        process.close()
    assert process._process is None


def test_model_timeout_terminates_process(monkeypatch):
    import subprocess
    import sys
    process = RhythmProcess(timeout=.1)
    child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(10)'],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    monkeypatch.setattr(process, '_start', lambda: None)
    process._process = child
    with pytest.raises(RhythmUnavailable, match='timed out'):
        process.predict(np.zeros(22050))
    assert child.poll() is not None and process._process is None
