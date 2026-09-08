"""Acoustic review cues, not calibrated confidence probabilities."""
from pydantic import BaseModel, Field
from .chord import parse_label


class ChordReview(BaseModel):
    start: float = Field(ge=0, allow_inf_nan=False)
    end: float = Field(gt=0, allow_inf_nan=False)
    label: str = Field(max_length=40)
    alternatives: list[str] = Field(default_factory=list, max_length=3)
    needs_review: bool
    reason: str = Field(max_length=100)



def matching_review(items, segments):
    """Never attach old evidence to a manually changed label or boundary."""
    result = []
    for item in items or []:
        value = ChordReview.model_validate(item).model_dump()
        parse_label(value['label'])
        for label in value['alternatives']: parse_label(label)
        if value['end'] <= value['start']:
            raise ValueError('empty review interval')
        if any(value['label'] == s['label'] and abs(value['start']-s['start']) < 1e-6
               and abs(value['end']-s['end']) < 1e-6 for s in segments):
            if value not in result: result.append(value)
    return result
