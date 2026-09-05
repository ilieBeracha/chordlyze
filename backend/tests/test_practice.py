"""Practice-take scoring against a reference chart."""
import pytest

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


def test_partial_take_inside_one_chord_scores_only_recorded_time():
    out = score_take([_seg(0, 8, "C:maj")], [_seg(0, 4, "C:maj")],
                     offset=2, take_duration=4)
    assert out["accuracy"] == 1.0
    assert (out["covered_start"], out["covered_end"]) == (2, 6)
    assert all(s["accuracy"] == 1.0 for s in out["sections"])


def test_silence_at_take_edges_counts_as_missed_playing():
    ref = [_seg(0, 4, "C:maj"), _seg(4, 8, "G:maj"), _seg(8, 12, "C:maj")]
    det = [_seg(0, 4, "N"), _seg(4, 8, "G:maj"), _seg(8, 12, "N")]
    out = score_take(ref, det, take_duration=12)
    assert out["accuracy"] == 0.333
    assert (out["covered_start"], out["covered_end"]) == (0, 12)
    assert any(t["to"] == "C" and t["misses"] == 1 for t in out["transitions"])


def test_empty_detection_with_known_duration_scores_zero():
    out = score_take(REF, [], take_duration=16)
    assert out["accuracy"] == 0.0
    assert all(t["misses"] == t["count"] for t in out["transitions"])


def test_short_chords_and_sections_stay_within_take():
    ref = [_seg(0, 0.5, "C:maj"), _seg(0.5, 1, "G:maj")]
    out = score_take(ref, ref, take_duration=1)
    assert out["accuracy"] == 1.0
    assert out["transitions"][0]["misses"] == 0
    assert [(s["start"], s["end"]) for s in out["sections"]] == [
        (0, .25), (.25, .5), (.5, .75), (.75, 1)]


def test_an_old_chord_is_not_a_successful_later_change():
    ref = [_seg(0, 4, "C:maj"), _seg(4, 8, "G:maj")]
    det = [_seg(0, 3.7, "G:maj"), _seg(3.7, 8, "C:maj")]
    out = score_take(ref, det)
    assert out["transitions"][0]["misses"] == 1
    assert out["avg_lag"] is None


def test_a_later_repeat_cannot_rescue_a_missed_chord():
    ref = [_seg(0, 1, "C:maj"), _seg(1, 2, "G:maj"),
           _seg(2, 3, "C:maj"), _seg(3, 4, "G:maj")]
    det = [_seg(0, 3, "C:maj"), _seg(3, 4, "G:maj")]
    out = score_take(ref, det)
    cg = next(t for t in out["transitions"] if t["from"] == "C")
    assert cg["count"] == 2 and cg["misses"] == 1
    gc = next(t for t in out["transitions"] if t["from"] == "G")
    assert gc["misses"] == 1


def test_early_changes_retain_timing_error():
    ref = [_seg(0, 4, "C:maj"), _seg(4, 8, "G:maj")]
    det = [_seg(0, 3.8, "C:maj"), _seg(3.8, 8, "G:maj")]
    out = score_take(ref, det)
    assert out["avg_lag"] == 0
    assert out["avg_early"] == .2
    assert out["avg_timing_error"] == .2
    assert out["transitions"][0]["avg_offset"] == -.2


def test_no_transition_across_reference_silence_or_missing_coverage():
    for middle in ([], [_seg(2, 4, "N")]):
        ref = [_seg(0, 2, "C:maj"), *middle, _seg(4, 6, "G:maj")]
        out = score_take(ref, ref, take_duration=6)
        assert out["accuracy"] == 1.0
        assert out["transitions"] == []


def test_enharmonic_and_bass_only_changes_are_not_transitions():
    ref = [_seg(0, 2, "Ab:maj"), _seg(2, 4, "G#:maj/3")]
    out = score_take(ref, [_seg(0, 4, "G#:maj")])
    assert out["accuracy"] == 1.0
    assert out["transitions"] == []


def test_rich_detection_can_be_scored_at_legacy_chart_resolution():
    out = score_take([_seg(0, 4, "C:maj")], [_seg(0, 4, "C:maj7")],
                     comparison="major_minor")
    assert out["accuracy"] == 1.0
    assert out["comparison"] == "major_minor"
    assert score_take([_seg(0, 4, "C:maj")], [_seg(0, 4, "C:min7")],
                      comparison="major_minor")["accuracy"] == 0.0
    assert score_take([_seg(0, 4, "C:maj7")], [_seg(0, 4, "C:maj")])["accuracy"] == 0.0


def test_unsupported_reference_quality_is_not_graded_as_wrong():
    out = score_take([_seg(0, 4, "C:maj6")], [_seg(0, 4, "C:maj")],
                     supported_qualities={"maj", "min", "maj7"})
    assert "unsupported" in out["error"]
    assert "C6" in out["error"]


@pytest.mark.parametrize("duration,offset", [(0, 0), (-1, 0), (float("nan"), 0),
                                              (4, float("inf"))])
def test_invalid_recording_span_is_rejected(duration, offset):
    with pytest.raises(ValueError):
        score_take(REF, REF, offset=offset, take_duration=duration)


def test_overlapping_detection_is_rejected_instead_of_double_counted():
    with pytest.raises(ValueError):
        score_take(REF, [_seg(0, 4, "G:maj"), _seg(2, 8, "G:maj")], take_duration=8)


@pytest.mark.parametrize("shift,label", [(2, "D:maj7"), (-2, "A#:maj7"), (12, "C:maj7")])
def test_transposed_performance_scores_in_sounding_key(shift, label):
    reference = [_seg(0, 8, "C:maj7/3")]
    out = score_take(reference, [_seg(0, 4, label)], offset=2, take_duration=4, transpose=shift)
    assert out["accuracy"] == 1
    assert out["transpose"] == shift
    assert reference[0]["label"] == "C:maj7/3", "never mutate the cached chart"
    if shift % 12:
        assert score_take(reference, [_seg(0, 4, label)], take_duration=4)["accuracy"] == 0


def test_half_speed_section_uses_song_offsets_and_real_timing_error():
    reference = [_seg(0, 8, "C:maj"), _seg(8, 12, "G:7")]
    # Start at song second 4; the change at song second 8 happens 8 real
    # seconds later at half speed. A late change is still 0.4 real seconds.
    detected = [_seg(0, 8.4, "D:maj"), _seg(8.4, 16, "A:7")]
    out = score_take(reference, detected, offset=4, take_duration=16,
                     transpose=2, playback_rate=0.5)
    assert out["avg_timing_error"] == 0.4
    assert out["covered_start"] == 4 and out["covered_end"] == 12
    assert out["scored_duration"] == 16
    assert out["sections"][0]["start"] == 4 and out["sections"][-1]["end"] == 12
    assert out["accuracy"] == 0.975
    assert out["transitions"][0]["from"] == "D" and out["transitions"][0]["to"] == "A7"


def test_slow_practice_silence_and_partial_recording_remain_in_denominator():
    out = score_take([_seg(10, 20, "C:maj")], [_seg(0, 2, "C:maj"), _seg(2, 4, "N")],
                     offset=10, take_duration=4, playback_rate=0.5)
    assert out["accuracy"] == 0.5
    assert (out["covered_start"], out["covered_end"]) == (10, 12)


@pytest.mark.parametrize("kwargs", [dict(transpose=13), dict(transpose=-13), dict(transpose=0.5),
    dict(transpose=True), dict(playback_rate=0), dict(playback_rate=1.1),
    dict(playback_rate=float("nan")), dict(playback_rate=float("inf"))])
def test_invalid_practice_settings_rejected(kwargs):
    with pytest.raises(ValueError):
        score_take(REF, REF, **kwargs)
