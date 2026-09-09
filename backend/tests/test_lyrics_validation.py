import copy
import json
from pathlib import Path

import pytest

from chordlyze_backend.lyrics_validation import mark_unreliable_words, usable_word_indices


def phrase(stamps):
    return {'time': 0, 'text': ' '.join(f'word{i}' for i in range(len(stamps))),
            'words': [{'time': start, 'end': end, 'text': f'word{i}'}
                      for i, (start, end) in enumerate(stamps)]}


@pytest.mark.parametrize(('stamps', 'boundary', 'expected'), [
    ([(1, 2), (3, 4), (5, 6)], 7, [0, 1, 2]),
    ([(1, 2), (3, 4), (5, 6)], 5, [0, 1]),
    ([(1, 2), (3, 4), (2.5, 3.5), (5, 6)], 7, [0, 3]),
    ([(1, 2), (3, 20), (5, 6)], 7, [2]),
    ([(1, 2), (40, 41)], 50, [0, 1]),
    ([(1, 2), (float('nan'), 3), (4, 5)], 6, [0, 2]),
    ([(1, 2), (3, 3), (4, 5)], 6, [0, 2]),
])
def test_failed_word_geometry_does_not_discard_unrelated_anchors(stamps, boundary, expected):
    assert usable_word_indices(phrase(stamps), boundary) == expected


def test_uncertain_flags_preserve_evidence_and_are_idempotent():
    lines = [phrase([(1, 2), (3, 4), (2.5, 3.5), (5, 6)])]
    original = copy.deepcopy(lines)
    assert mark_unreliable_words(lines, 7) == {'lines': 1, 'words': 2}
    assert lines[0]['words'][0] == original[0]['words'][0]
    assert lines[0]['words'][3] == original[0]['words'][3]
    for position in (1, 2):
        assert lines[0]['words'][position] == {**original[0]['words'][position], 'estimated': True}
    snapshot = copy.deepcopy(lines)
    assert mark_unreliable_words(lines, 7) == {'lines': 1, 'words': 2}
    assert lines == snapshot


def test_genuine_rest_and_existing_estimates_are_unchanged():
    lines = [phrase([(1, 2), (40, 41)])]
    lines[0]['words'][1]['estimated'] = True
    original = copy.deepcopy(lines)
    assert mark_unreliable_words(lines, 50) is None
    assert lines == original


CONTRACT = json.loads((Path(__file__).resolve().parents[2] / 'tests/fixtures/word-timing-contract.json').read_text())


@pytest.mark.parametrize('case', CONTRACT, ids=lambda case: case['id'])
def test_all_reported_geometries_share_the_ios_contract(case):
    assert usable_word_indices(case['line'], case['boundary']) == case['usable']
    original = copy.deepcopy(case['line'])
    marked = copy.deepcopy(original)
    mark_unreliable_words([marked], case['boundary'])
    for index, word in enumerate(marked['words']):
        expected = original['words'][index]
        assert word == (expected if index in case['usable'] else {**expected, 'estimated': True})
