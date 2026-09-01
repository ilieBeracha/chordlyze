"""Practice-take scoring against a reference chart."""
from chordlyze_backend.practice import score_take


def _seg(start, end, label):
    return {"start": start, "end": end, "label": label}


REF = [_seg(0, 4, "G:maj"), _seg(4, 8, "D:maj"), _seg(8, 12, "E:min"),
       _seg(12, 16, "C:maj")]


def test_perfect_take():
    out = score_take(REF, REF)
    assert out["accuracy"] == 1.0
    assert out["per_chord"][0]["accuracy"] == 1.0
    assert all(t["misses"] == 0 for t in out["transitions"])


def test_late_changes():
    det = [_seg(0, 4.8, "G:maj"), _seg(4.8, 8.8, "D:maj"),
           _seg(8.8, 12.8, "E:min"), _seg(12.8, 16, "C:maj")]
    out = score_take(REF, det)
    assert 0.7 < out["accuracy"] < 1.0
    assert out["avg_lag"] is not None and 0.5 < out["avg_lag"] <= 1.0


def test_wrong_chord_flagged():
    det = [_seg(0, 4, "G:maj"), _seg(4, 8, "D:maj"), _seg(8, 12, "E:maj"),
           _seg(12, 16, "C:maj")]  # E major instead of E minor
    out = score_take(REF, det)
    worst = out["per_chord"][0]
    assert worst["name"] == "Em"
    assert worst["accuracy"] == 0.0
    assert any(t["to"] == "Em" and t["misses"] == 1 for t in out["transitions"])


def test_partial_take_covers_only_overlap():
    det = [_seg(0, 4, "G:maj"), _seg(4, 8, "D:maj")]
    out = score_take(REF, det)
    assert out["covered_end"] <= 8.5
    assert out["accuracy"] == 1.0


def test_offset_shifts_take():
    det = [_seg(0, 4, "E:min"), _seg(4, 8, "C:maj")]
    out = score_take(REF, det, offset=8.0)
    assert out["accuracy"] == 1.0


def test_no_overlap_errors():
    out = score_take(REF, [_seg(100, 104, "G:maj")])
    assert "error" in out

