"""Bar-synchronous acoustic sections; A/B labels describe recurrence, not song roles."""
from __future__ import annotations

import numpy as np

STRUCTURE_MODEL = "bar-chroma-mfcc-novelty-v1"


def segment_features(features: np.ndarray, *, min_bars: int = 4) -> list[tuple[int, int, str]]:
    """Return [start, end) bar indices and repeat labels from ordered bar features.

    Linear song-length memory, no quadratic self-similarity matrix. Constant
    features do not manufacture boundaries; short fragments stay one section.
    """
    x = np.asarray(features, dtype=float)
    if x.ndim != 2 or not x.shape[1] or not np.isfinite(x).all():
        raise ValueError("invalid structure features")
    n = len(x)
    if not n:
        return []
    x = x / np.maximum(np.linalg.norm(x, axis=1, keepdims=True), 1e-9)
    novelty = np.zeros(n)
    for i in range(min_bars, n - min_bars + 1):
        left, right = x[i-min_bars:i].mean(axis=0), x[i:i+min_bars].mean(axis=0)
        novelty[i] = np.linalg.norm(left - right)
    candidates = [i for i in range(min_bars, n-min_bars+1)
                  if novelty[i] >= max(.28, float(np.median(novelty) + .15))
                  and novelty[i] >= max(novelty[max(0, i-1):min(n, i+2)])]
    chosen = []
    for i in sorted(candidates, key=lambda k: (-novelty[k], k)):
        if all(abs(i-j) >= min_bars for j in chosen):
            chosen.append(i)
    boundaries = [0, *sorted(chosen), n]
    profiles, lengths, result = [], [], []
    for start, end in zip(boundaries, boundaries[1:]):
        # Ordered profiles distinguish AB from BA with the same average harmony.
        edges = np.linspace(start, end, 9)
        profile = np.vstack([x[int(a):max(int(a)+1, int(b))].mean(axis=0)
                             for a, b in zip(edges, edges[1:])])
        profile /= max(float(np.linalg.norm(profile)), 1e-9)
        match = next((i for i, p in enumerate(profiles)
                      if .75 <= (end-start) / lengths[i] <= 1.3334
                      and float(np.sum(profile * p)) >= .94), None)
        if match is None:
            match = len(profiles)
            profiles.append(profile)
            lengths.append(end-start)
        value, label = match+1, ""
        while value:
            value, digit = divmod(value-1, 26)
            label = chr(65+digit) + label
        result.append((start, end, label))
    return result


def analyze_sections(y: np.ndarray, sr: int, bars: list[dict]) -> list[dict]:
    import librosa

    if not bars:
        return []
    # Analyze one bar at a time: a 20-minute song must not allocate a whole
    # recording's complex STFT, power spectrum and mel spectrum together.
    rows = []
    for bar in bars:
        a, b = int(bar["start"]*sr), min(len(y), int(bar["end"]*sr))
        spectrum = np.abs(librosa.stft(y[a:b], n_fft=2048, hop_length=512)) ** 2
        chroma = librosa.feature.chroma_stft(S=spectrum, sr=sr, tuning=0)
        mel = librosa.feature.melspectrogram(S=spectrum, sr=sr, n_mels=40)
        mfcc = librosa.feature.mfcc(S=librosa.power_to_db(mel), n_mfcc=8)[1:]
        rows.append(np.concatenate((chroma.mean(axis=1), mfcc.mean(axis=1))))
    rows = np.asarray(rows)
    timbre = rows[:, 12:]
    rows[:, 12:] = .15 * (timbre - timbre.mean(axis=0)) / np.maximum(timbre.std(axis=0), 1)
    occurrences, sections = {}, []
    for start, end, label in segment_features(rows):
        occurrences[label] = occurrences.get(label, 0)+1
        sections.append({"start": bars[start]["start"], "end": bars[end-1]["end"],
                         "start_bar": start+1, "end_bar": end,
                         "label": label, "occurrence": occurrences[label]})
    return sections
