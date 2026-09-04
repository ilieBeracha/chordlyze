"""Shared audio contract and real large-vocabulary inference regressions."""
import os
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

from chordlyze_backend.analysis import ismir
from chordlyze_backend.analysis.chord import parse_label
from chordlyze_backend.analysis.engine import AudioDecodeError, recognize_audio, validated_segments
from chordlyze_backend.analysis.provenance import is_current
from chordlyze_backend.analysis.ismir_worker import _check
from tests.test_engine_synthetic import RICH, SR, dominant_label, synth_progression


def test_decoded_duration_hash_and_boundary_clipping(tmp_path, monkeypatch):
    wav = tmp_path / "take.wav"
    sf.write(wav, np.zeros(SR + 123), SR)
    monkeypatch.setattr(ismir, "recognize", lambda _: [(0, 1.1, "Ab:maj"), (1.1, 1.2, "G:maj")])
    result = recognize_audio(wav)
    assert result.duration == (SR + 123) / SR
    assert result.segments[-1].end == result.duration
    assert result.segments[0].label == "G#:maj"
    assert len(result.audio_sha256) == 64
    assert is_current(result.metadata(), "ismir2019")
    copy = tmp_path / "another-name.wav"
    copy.write_bytes(wav.read_bytes())
    assert recognize_audio(copy).audio_sha256 == result.audio_sha256


@pytest.mark.parametrize("rows", [[(0, float("nan"), "C:maj")], [(-1, 1, "C:maj")],
                                   [(0, 2, "C:maj"), (1, 3, "G:maj")], [(0, 1, "H:maj")]])
def test_bad_recognizer_output_is_rejected(rows):
    with pytest.raises(ValueError):
        validated_segments(rows, 4)


def test_too_long_take_is_rejected_before_model_inference(tmp_path, monkeypatch):
    wav = tmp_path / "take.wav"
    sf.write(wav, np.zeros(SR * 2), SR)
    monkeypatch.setattr(ismir, "recognize", lambda _: pytest.fail("model must not run"))
    with pytest.raises(AudioDecodeError, match="exceeds"):
        recognize_audio(wav, max_duration=1)


def test_aac_frame_padding_does_not_reject_a_take_at_the_duration_limit(tmp_path, monkeypatch):
    wav, aac = tmp_path / "take.wav", tmp_path / "take.m4a"
    sf.write(wav, np.zeros(SR * 2), SR)
    subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", str(wav),
                    "-c:a", "aac", str(aac)], check=True)
    monkeypatch.setattr(ismir, "recognize", lambda _: [(0, 3, "N")])
    result = recognize_audio(aac, max_duration=2)
    assert 2 <= result.duration <= 2.05
    assert result.segments[-1].end == result.duration


def test_missing_rich_model_never_falls_back_to_triads(tmp_path, monkeypatch):
    wav = tmp_path / "take.wav"
    sf.write(wav, np.zeros(SR), SR)
    worker = ismir.IsmirProcess()
    monkeypatch.setenv("CHORDLYZE_ISMIR_DIR", str(tmp_path / "missing"))
    monkeypatch.setattr(ismir, "_worker", worker)
    with pytest.raises(ismir.RecognitionUnavailable, match="not installed"):
        recognize_audio(wav)
    assert worker._process is None


@pytest.mark.parametrize("script,message", [
    ("import time; time.sleep(10)", "timed out"),
    ("print('[]', flush=True)", "invalid response"),
    ("print('not JSON', flush=True)", "Expecting value"),
    ("pass", "stopped unexpectedly"),
    ("print('{\"error\":\"missing checkpoint\"}', flush=True)", "missing checkpoint"),
])
def test_broken_worker_protocol_is_retryable_and_process_is_cleaned_up(script, message):
    worker = ismir.IsmirProcess(timeout=1)
    proc = subprocess.Popen([sys.executable, "-u", "-c", "input(); " + script], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    worker._process = proc
    # Keep startup out of this test: exercise exactly one request/response.
    worker._start = lambda: None
    try:
        with pytest.raises(ismir.RecognitionUnavailable, match=message):
            worker.recognize(Path("audio.wav"))
        assert worker._process is None and proc.poll() is not None
        assert proc.stdin.closed and proc.stdout.closed
    finally:
        worker.close()


def test_missing_or_changed_checkpoints_are_rejected_before_loading(tmp_path):
    path = tmp_path / "network.sdict"
    with pytest.raises(RuntimeError, match="model asset"):
        _check(path, "a" * 64)
    path.write_bytes(b"different weights")
    with pytest.raises(RuntimeError, match="model asset"):
        _check(path, "a" * 64)


@pytest.fixture(scope="module")
def real_rich_result(tmp_path_factory):
    if not ismir.ismir_available():
        if os.environ.get("CHORDLYZE_REQUIRE_MODELS") == "1":
            pytest.fail("run scripts/setup_ismir.sh before the release checks")
        pytest.skip("ISMIR model not installed; CHORDLYZE_REQUIRE_MODELS=1 makes this a failure")
    wav = tmp_path_factory.mktemp("ismir") / "rich.wav"
    synth_progression(RICH, 2, str(wav))
    result = recognize_audio(wav)
    yield wav, result
    ismir.close()


@pytest.mark.parametrize("index,label", [
    pytest.param(i, label, marks=pytest.mark.xfail(
        reason="measured ISMIR limitation on this synthetic voicing", strict=True))
    if label in ("G:sus2", "G:7/b7") else (i, label)
    for i, label in enumerate(RICH)
], ids=RICH)
def test_real_rich_model_names_known_chords(real_rich_result, index, label):
    _, result = real_rich_result
    got = dominant_label(result.segments, index * 2 + .25, (index + 1) * 2 - .25)
    assert parse_label(got) == parse_label(label)
    assert result.duration == 24
    assert result.segments[-1].end <= result.duration


def test_model_process_is_reused_and_recovers_after_exit(real_rich_result):
    wav, result = real_rich_result
    pid = ismir._worker._process.pid
    assert recognize_audio(wav).segments == result.segments
    assert ismir._worker._process.pid == pid
    ismir._worker._process.terminate()
    ismir._worker._process.wait(timeout=5)
    assert recognize_audio(wav).segments == result.segments
    assert ismir._worker._process.pid != pid


def test_rich_model_silence_keeps_the_recording_duration(real_rich_result, tmp_path):
    wav = tmp_path / "silence.wav"
    sf.write(wav, np.zeros(SR * 2), SR)
    result = recognize_audio(wav)
    assert result.duration == 2
    assert all(s.label == "N" for s in result.segments)
    assert result.segments[-1].end == 2
