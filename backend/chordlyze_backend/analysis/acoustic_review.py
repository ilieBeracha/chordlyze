"""Model acoustic rankings, separate from API dependencies."""
import numpy as np
from .chord import parse_label

def acoustic_review(rows, names, observations, hop_seconds):
    """Rank mean acoustic log support over each decoded span, without HMM priors.
    A small winner gap or disagreement with the temporal decoder warrants review.
    Scores are deliberately not exposed as probabilities of correctness.
    """
    result = []
    for start, end, label in rows:
        low = max(0, int(round(start / hop_seconds)))
        high = min(len(observations), max(low + 1, int(round(end / hop_seconds))))
        if high <= low:
            continue
        scores = np.nan_to_num(observations[low:high], nan=-1000, neginf=-1000, posinf=0).mean(axis=0)
        ranked = np.argsort(-scores, kind='stable')
        canonical = parse_label(str(label))
        label = canonical.label if canonical else 'N'
        choices = []
        values = []
        for index in ranked:
            parsed = parse_label(names[index])
            name = parsed.label if parsed else 'N'
            if name not in choices:
                choices.append(name); values.append(float(scores[index]))
            if len(choices) == 4:
                break
        weak = bool(choices and choices[0] != label)
        close = len(values) > 1 and values[0] - values[1] < .5
        short = end - start < .25
        reason = 'Acoustic evidence disagrees' if weak else 'Close alternatives' if close else 'Very short change' if short else 'Clearer acoustic lead'
        result.append(dict(start=float(start), end=float(end), label=label,
                           alternatives=[name for name in choices if name != label][:3],
                           needs_review=weak or close or short, reason=reason))
    return result
