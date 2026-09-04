"""Recognition capabilities and cache compatibility shared by API and ingest.

Bump ANALYSIS_VERSION for feature, segmentation or analysis changes. Change a
model revision whenever its weights, dictionary or inference settings change.
Legacy results remain readable but are queued for reanalysis by the worker.
"""
from __future__ import annotations

ANALYSIS_VERSION = 2
ISMIR_COMMIT = "481f4ce703f8822b99f4037e9104ba1760e21ea3"
MODEL_REVISIONS = {
    "madmom": "27f032e-cnn-crf-10fps-v1",
    "ismir2019": "481f4ce-ensemble5-submission-penalty30-v1",
}
MODEL_RANK = {"madmom": 0, "ismir2019": 1}
MODEL_QUALITIES = {
    "madmom": frozenset({"maj", "min"}),
    "ismir2019": frozenset({"maj", "min", "dim", "aug", "sus2", "sus4", "sus4(b7)",
                            "7", "maj7", "min7", "dim7", "hdim7", "9", "maj9", "min9", "11", "13"}),
}
ISMIR_WEIGHT_HASHES = (
    "921b42d5d1cf9ce1c0c0e45a74d409b8066e0acec46058ef74e24ee0fb540761",
    "bcb75859e0efa256696cf5da396b320093317b9b1d9560c304f46c25fe1f8b17",
    "acddf85c3fff29954c4877021177d72e2cba9f729ce80c1010f054c477bf3f61",
    "65d81a3ab73435aaaade586981b4cabdf57b8953d76052703e6968c32ef8421c",
    "5ff6b0ec85640e17a09a9b3de68c93fdd45adc24488e8fa9be5715c28d561122",
)
ISMIR_VOCABULARY_HASH = "ac68a26e87242fc58c946d476028d4e8c8d12c9e707ced7020a4d7e31c794d7b"


def model_metadata(model: str) -> dict:
    return {"model": model, "model_revision": MODEL_REVISIONS[model],
            "analysis_version": ANALYSIS_VERSION}


def is_current(entry: dict, model: str | None = None) -> bool:
    actual = entry.get("model", "madmom")
    return (actual in MODEL_REVISIONS and (model is None or actual == model)
            and entry.get("analysis_version") == ANALYSIS_VERSION
            and entry.get("model_revision") == MODEL_REVISIONS[actual])


def quality(entry: dict) -> tuple[int, int, int]:
    """Retain coverage/vocabulary upgrades and never replace a current result
    with an older revision of the same recognizer."""
    return (int(entry.get("source") != "itunes_preview"),
            MODEL_RANK.get(entry.get("model", "madmom"), 0), int(is_current(entry)))
