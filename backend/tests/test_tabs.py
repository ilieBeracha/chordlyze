import pytest
from fastapi import HTTPException

from chordlyze_backend import main, tabs

# A synthetic Songsterr song: 4/4 at 120 bpm, so each measure lasts 2 s.
# Measures 0-1 are an intro; measures 2-7 sing one four-word line each.
WORDS = ["alpha bravo charlie delta", "echo foxtrot golf hotel", "india juliet kilo lima",
         "mike november oscar papa", "quebec romeo sierra tango", "uniform victor whiskey xray"]
CHORDS = ["G", "Cadd9", "D/F#", "Em"]


def quarter(fret=0, chord=None, tie=False):
    beat = {"duration": [1, 4], "type": 4, "notes": [{"fret": fret, "string": 0, **({"tie": True} if tie else {})}]}
    if chord:
        beat["chord"] = {"text": chord, "width": 20}
    return beat


def rest_measure():
    return {"voices": [{"beats": [{"duration": [1, 1], "type": 1, "rest": True, "notes": [{"rest": True}]}]}]}


def guitar_part(measures=8):
    out = []
    for m in range(measures):
        out.append({"voices": [{"beats": [quarter(3, CHORDS[m % 4])] + [quarter(3) for _ in range(3)]}]})
    out[0]["signature"] = [4, 4]
    out[0]["marker"] = {"text": "Intro", "width": 30}
    return {"name": "Rhythm", "tuning": [64, 59, 55, 50, 45, 40], "capo": 0, "measures": out,
            "automations": {"tempo": [{"measure": 0, "position": 0, "bpm": 120, "type": 4}]}}


def vocal_part(text="\n".join(["[Verse]"] + WORDS)):
    measures = [rest_measure(), rest_measure()] + [
        {"voices": [{"beats": [quarter(5) for _ in range(4)]}]} for _ in range(6)]
    measures[0]["signature"] = [4, 4]
    return {"name": "Vocals", "tuning": [64], "measures": measures,
            "newLyrics": [{"line": 1, "offset": 1, "text": text}, {"line": 2, "offset": 1, "text": ""}]}


META = {"songId": 7, "artist": "Band", "title": "Song", "revisionId": 70, "image": "img",
        "popularTrackGuitar": 1, "popularTrackVocals": 0,
        "tracks": [{"instrumentId": 52, "name": "Vocals", "isVocalTrack": True},
                   {"instrumentId": 25, "name": "Rhythm"},
                   {"instrumentId": 34, "name": "Bass"}]}


def recording_lines(shift=5.0, stray=None):
    lines = [{"time": shift + 4 + 2 * i, "text": text.title()} for i, text in enumerate(WORDS)]
    if stray is not None:
        lines[stray] = {**lines[stray], "time": lines[stray]["time"] + 2.5}
    return lines


def fake_songsterr(guitar=None, vocal=None, calls=None):
    guitar, vocal = guitar or guitar_part(), vocal or vocal_part()

    def get(url):
        if calls is not None:
            calls.append(url)
        if url.startswith(tabs.SEARCH_URL):
            return [{"songId": 7, "artist": "Band", "title": "Song"}]
        if url == tabs.META_URL.format(song_id=7):
            return META
        if url == tabs.PART_URL.format(song_id=7, revision=70, image="img", part=1):
            return guitar
        if url == tabs.PART_URL.format(song_id=7, revision=70, image="img", part=0):
            return vocal
        raise AssertionError(f"unexpected request {url}")
    return get


def test_match_needs_title_and_artist_to_agree():
    results = [{"songId": 9, "artist": "Oasis Tribute Band", "title": "Wonderwall"},
               {"songId": 2, "artist": "Oasis", "title": "Wonderwall"}]
    assert tabs.best_match(results, "Wonderwall - Remastered", "Oasis")["songId"] == 2
    assert tabs.best_match(results, "Champagne Supernova", "Oasis") is None
    assert tabs.best_match(results, "Wonderwall", "Ryan Adams") is None


def test_chord_names_outside_the_vocabulary_reduce_to_triads():
    assert [tabs._label(n) for n in ["Em7", "Cadd9", "E5", "Fmadd9", "Gadd9/B", "x", "A7sus4"]] == [
        "E:min7", "C:maj", "E:maj", "F:min", "G:maj/3", "N", "A:sus4(b7)"]


def test_repeats_are_unrolled_and_alternate_endings_refused():
    part = guitar_part(5)
    part["measures"][1]["repeatStart"] = True
    part["measures"][2]["repeat"] = 3
    assert tabs.play_order(part) == [0, 1, 2, 1, 2, 1, 2, 3, 4]
    part["measures"][3]["alternateEnding"] = [1]
    with pytest.raises(tabs.NotFound):
        tabs.play_order(part)


def test_clock_follows_tempo_marks_and_linear_ramps():
    part = guitar_part(3)
    order = tabs.play_order(part)
    assert tabs.clock(part, order, part["automations"]) == [(0, 2), (2, 4), (4, 6)]
    marks = {"tempo": [{"measure": 0, "position": 0, "bpm": 60, "type": 4, "linear": True},
                       {"measure": 1, "position": 0, "bpm": 120, "type": 4}]}
    spans = tabs.clock(part, order, marks)
    # 60 -> 120 bpm over one 4/4 measure takes 4·ln(2) s; then 2 s per measure.
    assert spans[0][1] == pytest.approx(4 * 0.6931, abs=1e-3)
    assert spans[2][1] - spans[1][1] == pytest.approx(2)


def test_syllables_take_sung_notes_and_ties_hold_them():
    order = list(range(8))
    spans = tabs.clock(guitar_part(), order, guitar_part()["automations"])
    # Sung notes every 0.5 s from 4.0 s. '+' holds a note, '(u)' sings one wordlessly.
    words = tabs.sung_words(vocal_part("To-day + is (u) the day\nnext"), order, spans)
    assert [(w["text"], w["time"], w["end"], w["line_start"]) for w in words] == [
        ("Today", 4.0, 5.0, True), ("is", 5.5, 6.0, False), ("the", 6.5, 7.0, False),
        ("day", 7.0, 7.5, False), ("next", 7.5, 8.0, True)]
    held = vocal_part("one two")
    held["measures"][2]["voices"][0]["beats"][1] = quarter(5, tie=True)
    one, two = tabs.sung_words(held, order, spans)
    assert (one["time"], one["end"], two["time"]) == (4.0, 5.0, 5.0)


def test_line_up_drops_a_stray_line_and_rejects_another_tempo():
    order = list(range(8))
    spans = tabs.clock(guitar_part(), order, guitar_part()["automations"])
    words = tabs.sung_words(vocal_part(), order, spans)
    fitted = tabs.line_up(words, recording_lines(stray=3))
    assert len(fitted["anchors"]) == 5 and fitted["found"] == 6 and fitted["basis"] == "lyrics"
    assert tabs.warp(fitted)(4.0) == pytest.approx(9.0)
    stretched = [{**line, "time": line["time"] * 1.2} for line in recording_lines()]
    with pytest.raises(tabs.NotFound):
        tabs.line_up(words, stretched)
    with pytest.raises(tabs.NotFound):
        tabs.line_up(words, [{"time": 3, "text": "nothing in common at all"}])


def test_build_puts_chords_lyrics_and_bars_on_the_recording_clock(monkeypatch):
    monkeypatch.setattr(tabs, "_get", fake_songsterr())
    result = tabs.build("Song", "Band", 30.0, recording_lines())
    chart = result["analysis"]
    assert chart["source"] == "songsterr" and chart["songsterr"]["part"] == 1
    assert [(c["start"], c["end"], c["label"]) for c in chart["chords"][:4]] == [
        (0.0, 5.0, "N"), (5.0, 7.0, "G:maj"), (7.0, 9.0, "C:maj"), (9.0, 11.0, "D:maj/3")]
    assert chart["chords"][-1]["end"] == 21.0 and chart["key"]
    assert chart["tempo"]["bpm"] == 120 and chart["tempo"]["bars"][0] == {"start": 5.0, "end": 7.0, "beats": 4}
    assert chart["tempo"]["beats"][-1] == 21.0 and chart["tempo"]["beat_positions"][:5] == [1, 2, 3, 4, 1]
    lines = result["lyrics"]["lines"]
    assert result["lyrics"]["synced"] and lines[0]["time"] == 9.0 and lines[0]["text"] == "alpha bravo charlie delta"
    assert lines[0]["words"][1] == {"time": 9.5, "end": 10.0, "text": "bravo", "estimated": False}
    assert result["tab"]["bars"][0] == {"measure": 0, "start": 5.0, "end": 7.0}
    assert result["tab"]["measures"][0]["marker"] == "Intro"


def test_build_needs_named_chords_and_lyrics(monkeypatch):
    bare = guitar_part()
    for m in bare["measures"]:
        m["voices"][0]["beats"][0].pop("chord")
    monkeypatch.setattr(tabs, "_get", fake_songsterr(guitar=bare))
    with pytest.raises(tabs.NotFound, match="name chords"):
        tabs.build("Song", "Band", 30.0, recording_lines())
    unsung = vocal_part()
    unsung["newLyrics"] = []
    monkeypatch.setattr(tabs, "_get", fake_songsterr(vocal=unsung))
    with pytest.raises(tabs.NotFound, match="no lyrics"):
        tabs.build("Song", "Band", 30.0, recording_lines())


def shifted_chart(shift=5.0, labels=("G:maj", "C:maj", "D:maj/3", "E:min")):
    """The synthetic song's chords as an analysis would place them, `shift` s in."""
    return [{"start": shift + 2 * m, "end": shift + 2 * m + 2, "label": labels[m % 4]} for m in range(8)]


def test_chords_heard_from_notes_name_clear_triads_only():
    def strum(*notes):
        return {"duration": [1, 2], "type": 2,
                "notes": [{"string": s, "fret": f} for s, f in notes]}
    part = guitar_part(1)
    # G major (G B D) then E minor (E B E G), from standard tuning, low strings.
    part["measures"][0]["voices"][0]["beats"] = [strum((5, 3), (4, 2), (3, 0)), strum((5, 0), (4, 2), (3, 2), (2, 0))]
    spans = tabs.clock(part, [0], part["automations"])
    assert tabs.heard_chords(part, [0], spans) == [(0.0, 1.0, 7), (1.0, 2.0, 4 + 12)]
    part["capo"] = 2
    assert [s for _, _, s in tabs.heard_chords(part, [0], spans)] == [9, 6 + 12]
    # A single repeated note fits several triads equally: nothing is named.
    assert tabs.heard_chords(guitar_part(1), [0], spans) == []


def test_chord_line_up_follows_the_chart_and_rejects_other_chords():
    order = list(range(8))
    guitar = guitar_part()
    spans = tabs.clock(guitar, order, guitar["automations"])
    named = tabs.named_chords(tabs.chord_events(guitar, order, spans), spans[-1][1])
    fitted = tabs.chord_line_up(named, shifted_chart(), 24.0)
    assert fitted["basis"] == "chords" and fitted["agreement"] == 1.0
    assert tabs.warp(fitted)(0.0) == pytest.approx(5.0, abs=0.1)
    with pytest.raises(tabs.NotFound):
        tabs.chord_line_up(named, shifted_chart(labels=("A:maj", "F:maj", "B:min", "C#:min")), 24.0)


def test_tab_for_an_analyzed_chart_prefers_lyrics_then_chords(monkeypatch):
    monkeypatch.setattr(tabs, "_get", fake_songsterr())
    by_lyrics = tabs.tab_for_chart("Song", "Band", 24.0, recording_lines(), shifted_chart(7.0))
    assert by_lyrics["songsterr"]["basis"] == "lyrics" and by_lyrics["tab"]["bars"][0]["start"] == 5.0
    by_chords = tabs.tab_for_chart("Song", "Band", 24.0, None, shifted_chart(7.0))
    assert by_chords["songsterr"]["basis"] == "chords"
    assert by_chords["tab"]["bars"][0]["start"] == pytest.approx(7.0, abs=0.1)
    # A tab without chord names still lines up by lyrics.
    bare = guitar_part()
    for m in bare["measures"]:
        m["voices"][0]["beats"][0].pop("chord")
    monkeypatch.setattr(tabs, "_get", fake_songsterr(guitar=bare))
    assert tabs.tab_for_chart("Song", "Band", 30.0, recording_lines(), [])["songsterr"]["basis"] == "lyrics"


def song_request(duration=30.0):
    return main.SongsterrRequest(title="Song", artist="Band", duration=duration)


def write_analysis(tmp_path, track, chords):
    from chordlyze_backend.analysis.provenance import model_metadata
    main._write_analysis(tmp_path / f"track-{track}.json",
                         {"track_id": track, "title": "Song", "artist": "Band", "chords": chords,
                          "source": "youtube", "audio_duration": 24.0, **model_metadata("ismir2019")})


def test_endpoint_adds_a_tab_to_an_analyzed_song(monkeypatch, tmp_path):
    monkeypatch.setattr(main, "CACHE_DIR", tmp_path)
    monkeypatch.setattr(tabs, "_get", fake_songsterr())

    def no_lyrics(*a, **k):
        raise HTTPException(404, "lyrics not found")
    monkeypatch.setattr(main, "lyrics", no_lyrics)
    write_analysis(tmp_path, "analyzed", shifted_chart(5.0))
    assert main.song_status("analyzed", user="tester")["tab_available"] is False
    status = main.songsterr_chart("analyzed", song_request(24.0), user="tester")
    assert status["analysis"]["source"] == "youtube" and status["tab_available"] is True
    assert main._songsterr_entry("analyzed")["basis"] == "chords"
    assert main.song_tab("analyzed", user="tester")["bars"][0]["start"] == pytest.approx(5.0, abs=0.1)
    # A new analysis invalidates a tab fitted to the old chart's chords.
    write_analysis(tmp_path, "analyzed", shifted_chart(7.0))
    assert main.song_status("analyzed", user="tester")["tab_available"] is False
    with pytest.raises(HTTPException):
        main.song_tab("analyzed", user="tester")
    main.songsterr_chart("analyzed", song_request(24.0), user="tester")
    assert main.song_tab("analyzed", user="tester")["bars"][0]["start"] == pytest.approx(7.0, abs=0.1)


def test_endpoint_serves_the_chart_until_an_analysis_exists(monkeypatch, tmp_path):
    monkeypatch.setattr(main, "CACHE_DIR", tmp_path)
    calls = []
    monkeypatch.setattr(tabs, "_get", fake_songsterr(calls=calls))
    monkeypatch.setattr(main, "lyrics", lambda *a, **k: {"synced": True, "lines": recording_lines()})
    status = main.songsterr_chart("track1", song_request(), user="tester")
    assert status["job"]["state"] == "ready" and status["analysis"]["source"] == "songsterr"
    assert status["analysis"]["chart_revision"] and status["lyrics"]["matched"] == "songsterr"
    assert status["lyrics_job"]["state"] == "ready" and status["song"]["title"] == "Song"
    looked_up = len(calls)
    assert main.songsterr_chart("track1", song_request(), user="tester")["analysis"] == status["analysis"]
    assert main.song_status("track1", user="tester")["analysis"] == status["analysis"]
    assert len(calls) == looked_up
    assert main.song_tab("track1", user="tester")["bars"][0]["start"] == 5.0
    # A Songsterr-charted song can be saved and is listed with its chart.
    assert main.save_song("track1", user="tester")["saved"]
    item = next(i for i in main.library(user="tester")["items"] if i["track_id"] == "track1")
    assert item["source"] == "songsterr" and item["title"] == "Song" and item["key"] == status["analysis"]["key"]
    # Asking for analysis does not queue a job over a served chart.
    assert main.request_song(main.SongRequest(track_id="track1", title="Song"), user="tester")["job"]["state"] == "ready"


def test_endpoint_caches_a_miss_and_never_an_outage(monkeypatch, tmp_path):
    monkeypatch.setattr(main, "CACHE_DIR", tmp_path)
    monkeypatch.setattr(main, "lyrics", lambda *a, **k: {"synced": True, "lines": recording_lines()})

    def down(url):
        raise tabs.Unavailable("tab service unreachable")
    monkeypatch.setattr(tabs, "_get", down)
    with pytest.raises(HTTPException) as outage:
        main.songsterr_chart("track2", song_request(), user="tester")
    assert outage.value.status_code == 503 and main._songsterr_entry("track2") is None

    monkeypatch.setattr(tabs, "_get", lambda url: [])
    status = main.songsterr_chart("track2", song_request(), user="tester")
    assert status["analysis"] is None and status["job"]["state"] == "missing"
    assert main._songsterr_entry("track2")["missing"] == "Songsterr has no tab for this song"
    with pytest.raises(HTTPException) as no_tab:
        main.song_tab("track2", user="tester")
    assert no_tab.value.status_code == 404

    def missing_lyrics(*a, **k):
        raise HTTPException(404, "lyrics not found")
    monkeypatch.setattr(main, "lyrics", missing_lyrics)
    assert main.songsterr_chart("track3", song_request(), user="tester")["analysis"] is None
    assert "time-synced lyrics" in main._songsterr_entry("track3")["missing"]
