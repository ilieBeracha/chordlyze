"""Real multipart upload through Uvicorn, decoding and the installed ensemble.

Uses a private localhost socket and temporary cache; never contacts the live API.
"""
import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

from chordlyze_backend.analysis.ismir import ismir_available
from chordlyze_backend.analysis.provenance import model_metadata
from tests.test_engine_synthetic import SR, synth_progression


@pytest.fixture(scope="module")
def server(tmp_path_factory):
    if not ismir_available():
        if os.environ.get("CHORDLYZE_REQUIRE_MODELS") == "1":
            pytest.fail("install the ISMIR model before release checks")
        pytest.skip("ISMIR model not installed")
    temp = tmp_path_factory.mktemp("practice-http")
    backend = Path(__file__).resolve().parents[1]
    env = {**os.environ, "CHORDLYZE_CACHE": str(temp / "cache"), "PYTHONPATH": str(backend)}
    with socket.socket() as listener, (temp / "server.log").open("w+") as log:
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        url = f"http://127.0.0.1:{listener.getsockname()[1]}"
        proc = subprocess.Popen([sys.executable, "-m", "uvicorn", "chordlyze_backend.main:app",
                                 "--fd", str(listener.fileno()), "--log-level", "warning"],
                                cwd=backend, env=env, pass_fds=(listener.fileno(),),
                                stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 30
            while True:
                try:
                    with urllib.request.urlopen(url + "/health", timeout=.5) as response:
                        assert json.load(response)["status"] == "ok"
                        break
                except (OSError, urllib.error.URLError):
                    if proc.poll() is not None or time.monotonic() > deadline:
                        log.seek(0)
                        pytest.fail("test server did not start: " + log.read())
                    time.sleep(.1)
            yield url, temp
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()


def post_json(url, payload):
    request = urllib.request.Request(url, data=json.dumps(payload).encode(),
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def upload(url, wav, *, track="rich", offset="2", transpose="0", playback_rate="1"):
    boundary = "chordlyze-regression"
    body = bytearray()
    for name, value in (("track_id", track), ("offset", offset), ("transpose", transpose), ("playback_rate", playback_rate)):
        body.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
    body.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="take.wav"\r\n'
                'Content-Type: audio/wav\r\n\r\n'.encode())
    body.extend(wav.read_bytes())
    body.extend(f"\r\n--{boundary}--\r\n".encode())
    request = urllib.request.Request(url + "/practice_take", data=body,
                                     headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    with urllib.request.urlopen(request, timeout=600) as response:
        return json.load(response)


def test_real_seventh_chord_upload_and_silent_take(server):
    url, temp = server
    chart = post_json(url + "/analysis/submit", {
        "track_id": "rich", **model_metadata("ismir2019"), "audio_duration": 8,
        "audio_sha256": "a" * 64, "segments": [{"start": 0, "end": 8, "label": "C:maj7"}],
    })
    assert chart["analysis_stale"] is False
    wav = temp / "take.wav"
    synth_progression(["C:maj7"], 4, str(wav))
    report = upload(url, wav)
    assert report["model"] == "ismir2019" and report["scoring_version"] == 2
    assert report["comparison"] == "root_quality"
    assert report["per_chord"][0]["name"] == "Cmaj7" and report["accuracy"] > .9
    assert (report["covered_start"], report["covered_end"], report["audio_duration"]) == (2, 6, 4)
    sf.write(wav, np.zeros(SR * 4), SR)
    silence = upload(url, wav)
    assert silence["accuracy"] == 0 and silence["scored_duration"] == 4
    assert silence["audio_sha256"] != report["audio_sha256"]


@pytest.mark.parametrize("offset", ["nan", "inf", "-inf"])
def test_nonfinite_sync_offset_rejected_at_http_boundary(server, offset):
    url, temp = server
    wav = temp / "invalid-offset.wav"
    wav.write_bytes(b"unused")
    with pytest.raises(urllib.error.HTTPError) as exc:
        upload(url, wav, offset=offset)
    assert exc.value.code == 422


@pytest.mark.parametrize("settings", [dict(transpose="13"), dict(transpose="1.5"),
    dict(playback_rate="0"), dict(playback_rate="1.1"), dict(playback_rate="nan")])
def test_invalid_practice_settings_rejected_at_http_boundary(server, settings):
    url, temp = server
    wav = temp / "invalid-settings.wav"
    wav.write_bytes(b"unused")
    with pytest.raises(urllib.error.HTTPError) as exc:
        upload(url, wav, **settings)
    assert exc.value.code == 422


def test_real_transposed_slow_section_upload(server):
    url, temp = server
    post_json(url + "/analysis/submit", {
        "track_id": "transpose-test", **model_metadata("ismir2019"), "audio_duration": 8,
        "audio_sha256": "b" * 64, "segments": [{"start": 0, "end": 8, "label": "C:maj7"}],
    })
    wav = temp / "transposed.wav"
    synth_progression(["D:maj7"], 4, str(wav))
    report = upload(url, wav, track="transpose-test", offset="2", transpose="2", playback_rate="0.5")
    assert report["accuracy"] > .9
    assert report["per_chord"][0]["name"] == "Dmaj7"
    assert (report["covered_start"], report["covered_end"]) == (2, 4)
    assert report["transpose"] == 2 and report["playback_rate"] == 0.5
