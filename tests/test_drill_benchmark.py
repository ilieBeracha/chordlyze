"""Checks that evaluation cannot hide rejections or erase wrong chord qualities."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('benchmark_drill', Path(__file__).resolve().parents[1] / 'scripts' / 'benchmark_drill.py')
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)


class BenchmarkTests(unittest.TestCase):
    def test_harte_degrees_and_enharmonics(self):
        self.assertEqual(b.pitch_set('Db:min7/b3'), b.pitch_set('C#:min7'))
        self.assertEqual(b.pitch_set('C:maj(*5)'), frozenset([0, 4]))
        self.assertEqual(b.pitch_set('C:7(#9,*5)'), frozenset([0, 3, 4, 10]))
        self.assertEqual(b.pitch_set('D:(1,5)'), frozenset([2, 9]))
        self.assertNotEqual(b.pitch_set('C:maj'), b.pitch_set('C:maj7'))
        self.assertIsNone(b.pitch_set('C:unsupported'))
        self.assertEqual(b.pitch_set('N'), frozenset())

    def test_duration_weighting_and_false_accepts(self):
        item = {'duration': 4, 'targetA': 'C', 'targetB': 'Am',
                'target_sets': [[0, 4, 7], [0, 4, 9]], 'required_sets': [[0, 4, 7], [0, 4, 9]],
                'reference': [{'time': 0, 'duration': 2, 'value': 'C:maj'},
                              {'time': 2, 'duration': 2, 'value': 'F:maj'}]}
        frames = [{'time': 0, 'accepted': None}, {'time': 1, 'accepted': 'C'},
                  {'time': 3, 'accepted': None}]
        counts = b.score(item, {'frames': frames}, interior=False)
        self.assertEqual(counts['correct_seconds'], 1)
        self.assertEqual(counts['incorrect_seconds'], 1)
        self.assertEqual(counts['target_seconds'], 2)
        result = b.metrics(counts)
        self.assertEqual(result['accepted_precision'], .5)
        self.assertEqual(result['target_time_coverage'], .5)
        self.assertEqual(result['non_target_false_accept_rate'], .5)
        dense = [frames[0], {'time': .5, 'accepted': None}, frames[1], {'time': 1.5, 'accepted': 'C'}, frames[2]]
        self.assertEqual(counts, b.score(item, {'frames': dense}, interior=False))
        rejected = b.metrics(b.score(item, {'frames': [frames[0]]}, interior=False))
        self.assertIsNone(rejected['accepted_precision'])
        self.assertEqual(rejected['target_time_coverage'], 0)

    def test_omitted_notes_are_not_promoted_to_full_triads(self):
        item = {'targetA': 'C', 'targetB': 'Dm7', 'target_sets': [[0,4,7], [0,2,5,9]],
                'required_sets': [[0,4,7], [0,2,5]]}
        self.assertIsNone(b.expected_target(item, {'value': 'C:maj(*5)'}))
        self.assertEqual(b.expected_target(item, {'value': 'D:min7(*5)'}), 'Dm7')
        self.assertIsNone(b.expected_target(item, {'value': 'C:maj7'}))


if __name__ == '__main__':
    unittest.main()
