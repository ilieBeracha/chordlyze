import json

import numpy as np
import pytest
from fastapi.testclient import TestClient

from chordlyze_backend import auth, main
from chordlyze_backend.analysis.engine import ChordSegment, Recognition
from chordlyze_backend.analysis.provenance import model_metadata
from chordlyze_backend.synchronization import Sample, UncertainSync, align


def reference():
    rng = np.random.default_rng(42)
    names = ["C:maj", "D:min", "E:min", "F:maj", "G:7", "A:min", "B:dim"]
    result, t, previous = [], 0., None
    while t < 300:
        name = rng.choice([n for n in names if n != previous])
        end = min(300, t + float(rng.uniform(1.3, 4.1)))
        result.append({"start": t, "end": end, "label": str(name)})
        previous, t = name, end
    return result


def sample(chart, start, offset=1.3, scale=1.016, duration=20):
    segments = []
    for s in chart:
        begin, end = max(0, scale*s["start"] + offset - start), min(duration, scale*s["end"] + offset - start)
        if end > begin:
            segments.append({"start": begin, "end": end, "label": s["label"]})
    return Sample(start, duration, segments)


def test_recovers_offset_and_drift_across_passages():
    chart = reference()
    result = align(chart, [sample(chart, t) for t in [25, 125, 225]])
    assert abs(result["offset"] - 1.3) <= .15
    assert abs(result["scale"] - 1.016) <= .0021
    assert result["match_score"] > .97 and result["drift_measured"]


def test_short_span_estimates_only_offset_and_handles_wrong_chord():
    chart = reference()
    samples = [sample(chart, t, offset=-2.2, scale=1, duration=14) for t in [15, 35, 55]]
    samples[1].segments[2]["label"] = "F#:min"
    result = align(chart, samples)
    assert abs(result["offset"] + 2.2) <= .2
    assert result["scale"] == 1 and not result["drift_measured"]


def test_repetition_and_silence_are_not_confident_sync():
    names = ["C:maj", "G:maj", "A:min", "F:maj"]
    chart = [{"start": i*2., "end": (i+1)*2., "label": names[i % 4]} for i in range(150)]
    with pytest.raises(UncertainSync, match="unique"):
        align(chart, [sample(chart, t, scale=1) for t in [25, 125, 225]])
    silent = Sample(25, 20, [{"start": 0, "end": 20, "label": "N"}])
    with pytest.raises(UncertainSync, match="microphone"):
        align(reference(), [silent] * 3)


def test_different_arrangement_is_rejected():
    chart = reference()
    samples = [sample(chart, t) for t in [25, 125, 225]]
    for segment in samples[1].segments:
        segment["label"] = "F#:min"
    with pytest.raises(UncertainSync):
        align(chart, samples)


@pytest.fixture
def api(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "CACHE_DIR", tmp_path)
    monkeypatch.setattr(auth, "lookup", lambda token: token)
    auth.forget_all()
    chart = {**model_metadata("ismir2019"), "source": "youtube", "audio_duration": 300,
             "audio_sha256": "a" * 64, "chords": reference()}
    (tmp_path / "track-song.json").write_text(json.dumps(chart))
    return TestClient(main.app), chart


def test_http_saves_personal_map_and_cleans_samples(api, monkeypatch):
    client, chart = api
    headers = {"Authorization": "Bearer alice"}
    before = client.get("/song/song", headers=headers).json()
    pending = [sample(chart["chords"], t) for t in [25, 125, 225]]
    paths = []
    def recognize(path, **kwargs):
        paths.append(path)
        s = pending.pop(0)
        return Recognition([ChordSegment(**x) for x in s.segments], s.duration, "a"*64, "ismir2019")
    monkeypatch.setattr(main, "recognize_audio", recognize)
    payload = {"positions": "[25,125,225]", "chart_revision": before["analysis"]["chart_revision"],
               "timing_revision": before["timing_revision"]}
    def send():
        return client.post("/library/song/synchronize", headers=headers, data=payload,
                           files=[("files", ("sample.m4a", b"audio", "audio/mp4"))] * 3)
    response = send()
    assert response.status_code == 200, response.text
    timing = response.json()["timing"]
    assert timing["method"] == "automatic" and timing["chart_revision"] == payload["chart_revision"]
    assert response.json()["saved"] and len(paths) == 3 and all(not p.exists() for p in paths)
    assert client.get("/song/song", headers=headers).json()["timing"] == timing
    assert client.get("/song/song", headers={"Authorization": "Bearer bob"}).json()["timing"] is None
    assert send().status_code == 409, "changed timing prevents a stale sync overwrite"


def test_change_during_recognition_preserves_newer_timing(api, monkeypatch):
    client, chart = api
    headers = {"Authorization": "Bearer alice"}
    before = client.get("/song/song", headers=headers).json()
    pending = [sample(chart["chords"], t) for t in [25, 125, 225]]
    def recognize(path, **kwargs):
        main.set_timing("song", main.TimingCalibration(offset=4, scale=1), user="alice")
        s = pending.pop(0)
        return Recognition([ChordSegment(**x) for x in s.segments], s.duration, "a"*64, "ismir2019")
    monkeypatch.setattr(main, "recognize_audio", recognize)
    response = client.post("/library/song/synchronize", headers=headers,
        data={"positions": "[25,125,225]", "chart_revision": before["analysis"]["chart_revision"], "timing_revision": before["timing_revision"]},
        files=[("files", ("sample.m4a", b"audio", "audio/mp4"))] * 3)
    assert response.status_code == 409
    assert client.get("/song/song", headers=headers).json()["timing"]["offset"] == 4


def test_real_recognizer_samples_recover_known_recording_map(tmp_path):
    from chordlyze_backend.analysis.engine import recognize_audio
    from chordlyze_backend.analysis.ismir import ismir_available
    from tests.test_engine_synthetic import synth_progression
    if not ismir_available():
        pytest.skip("ISMIR model not installed")
    rng = np.random.default_rng(917)
    names = ["C:maj", "D:min", "E:min", "F:maj", "G:maj", "A:min"]
    sequence = []
    for _ in range(110):
        sequence.append(str(rng.choice([n for n in names if not sequence or n != sequence[-1]])))
    chart = [{"start": i*2.5, "end": (i+1)*2.5, "label": name} for i, name in enumerate(sequence)]
    samples = []
    for first in [8, 48, 88]:
        path = tmp_path / f"heard-{first}.wav"
        synth_progression(sequence[first:first+10], 2.5*1.012, str(path))
        recognized = recognize_audio(path, model="ismir2019", max_duration=30)
        samples.append(Sample(first*2.5*1.012 + 1.3, recognized.duration, [s.to_dict() for s in recognized.segments]))
    result = align(chart, samples)
    assert abs(result["offset"] - 1.3) <= .35
    assert abs(result["scale"] - 1.012) <= .004
