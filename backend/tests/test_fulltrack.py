from chordlyze_backend.fulltrack import pick_candidate


def _e(duration, title, channel="Someone", id="x"):
    return {"duration": duration, "title": title, "channel": channel, "id": id}


def test_picks_duration_match_and_prefers_topic_channel():
    entries = [
        _e(273, "Highline - Believe Me I'll Run (Live Session)", "Highline", "live"),
        _e(261, "Believe Me I'll Run", "Highline", "official"),
        _e(262, "Believe Me I'll Run", "Highline - Topic", "topic"),
        _e(148, "Something else", "Other", "wrong"),
    ]
    assert pick_candidate(entries, "Believe Me I'll Run", "Highline", 261)["id"] == "topic"


def test_rejects_variants_unless_requested():
    entries = [_e(200, "Song (Acoustic)", "Band", "ac")]
    assert pick_candidate(entries, "Song", "Band", 200) is None
    assert pick_candidate(entries, "Song (Acoustic)", "Band", 200)["id"] == "ac"


def test_none_when_no_duration_within_tolerance():
    entries = [_e(215, "Song", "Band"), _e(190, "Song", "Band")]
    assert pick_candidate(entries, "Song", "Band", 200) is None
    assert pick_candidate(entries, "Song", "Band", 214)["duration"] == 215
