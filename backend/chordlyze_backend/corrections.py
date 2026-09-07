"""Personal chord overlays. Callers hold library_lock while reading/writing.

Keep segment boundaries and the global analysis intact. An overlay is tied to
the original chord timeline and recording, never guessed onto a new analysis.
"""
import hashlib
import json

from .analysis.engine import ChordSegment
from .analysis.keyfinder import analyze


def revision(chart: dict) -> str:
    identity = {key: chart.get(key) for key in (
        "audio_sha256", "audio_duration", "source", "model", "model_revision", "analysis_version")}
    identity["chords"] = [[float(s["start"]), float(s["end"]), s["label"]] for s in chart.get("chords", [])]
    return hashlib.sha256(json.dumps(identity, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def raw(segments: list[dict]) -> list[dict]:
    return [{"start": s["start"], "end": s["end"], "label": s["label"]} for s in segments]


def apply(chart: dict, overlay: dict | None) -> dict:
    base = revision(chart)
    active = overlay if overlay and overlay.get("base_revision") == base else None
    stale = bool(overlay and (overlay.get("labels") or overlay.get("segments")) and active is None)
    labels = active.get("labels", {}) if active else {}
    source = active.get("segments") if active else None
    if source is None and labels:
        source = [{**s, "label": labels.get(str(i), s["label"])} for i, s in enumerate(chart["chords"])]
    result = dict(chart)
    if source is not None:
        result.update(analyze([ChordSegment(s["start"], s["end"], s["label"]) for s in source]))
        for segment in result["chords"]:
            originals = [s for s in chart["chords"] if s["start"] <= segment["start"] and s["end"] >= segment["end"]]
            if len(originals) == 1 and originals[0]["label"] != segment["label"]:
                segment["original_label"] = originals[0]["label"]
    result["chart_revision"] = revision(result)
    result["corrections_stale"] = stale
    result["can_undo"] = bool(active and active.get("history"))
    result["boundaries_edited"] = [(s["start"], s["end"]) for s in result["chords"]] != [(s["start"], s["end"]) for s in chart["chords"]]
    return result


def commit(chart: dict, current: dict, overlay: dict | None, segments: list[dict]) -> dict:
    history = list(overlay.get("history", [])) if overlay and overlay.get("base_revision") == revision(chart) else []
    if raw(current["chords"]) != raw(segments):
        history = (history + [raw(current["chords"])])[-10:]
    return {"base_revision": revision(chart), "segments": raw(segments), "history": history}
