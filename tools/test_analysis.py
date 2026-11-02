import copy
import json
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

from analyze_table import ROOT, expand_suite, summarize, svg_map, svg_paths, wilson, write_report


class AnalysisTests(unittest.TestCase):
    def setUp(self):
        # The old level 1, kept as a fixture: a full board with bumpers for the contracts below.
        self.table = json.loads((ROOT/'Tests/Fixtures/features.json').read_text())
        self.spec = {'id': 'shot', 'position': [.4, .3], 'velocity': [0, -1], 'seconds': 2,
                     'controls': [{'at': .1, 'left': True}],
                     'expect': [{'event': 'bumper', 'element': self.table['bumpers'][0]['id']}]}

    def test_shipping_suites_resolve_ids_for_every_table(self):
        for path in sorted((ROOT/'GameData/Tables').glob('*.json')):
            data = json.loads(path.read_text())
            for suite in ('authoring', 'coverage'):
                trials = expand_suite(json.loads((ROOT/f'GameData/Analysis/{suite}.json').read_text()), data)
                self.assertTrue(trials)
                self.assertEqual(len({t['id'] for t in trials}), len(trials))

    def test_timing_sweep_preserves_seed_and_other_controls(self):
        self.spec.update(seeds=[17, 41], sweep={'control': 0, 'at': [0, .05]})
        trials = expand_suite({'scenarios': [self.spec]}, self.table)
        self.assertEqual([t['seed'] for t in trials], [17, 17, 41, 41])
        self.assertEqual([t['controls'][0]['at'] for t in trials], [0, .05, 0, .05])
        self.assertEqual(self.spec['controls'][0]['at'], .1)

    def test_rejects_impossible_contracts_and_nonfinite_inputs(self):
        mutations = [dict(velocity=[float('nan'), 0]), dict(seconds=-1), dict(seeds=[0]),
                     dict(returnBox=[1, 1, 0, 0]), dict(sweep={'control': 5, 'at': [0]}),
                     dict(expect=[{'event': 'bumper', 'element': 'not-real'}]),
                     dict(expect=[{'event': 'fictional'}]), dict(controls=[{'at': 0, 'left': 'yes'}])]
        for mutation in mutations:
            spec = dict(self.spec, **mutation)
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                expand_suite({'scenarios': [spec]}, self.table)

    def raw(self):
        return {'table': '<test>', 'grid': 8, 'height': 16, 'size': [1, 2], 'workers': 1,
                'wallSeconds': .01, 'sampling': 'fixture:960Hz',
                'inventory': [{'event': 'bumper', 'element': 'a'}, {'event': 'bumper', 'element': 'b'}],
                'trials': [{'id': 'shot:0', 'seed': 1, 'steps': 960, 'status': 'success',
                            'returned': False, 'returnMeasured': False,
                            'events': [{'event': 'bumper', 'element': 'a'}],
                            'cells': [[0, .2, .1, -.1], [128, .1, .1, .1]],
                            'trace': [[8, 0, .1, .2, 0, 1], [16, 0, .2, .3, 0, 1],
                                      [24, 1, .8, .9, 0, 1], [32, 1, .9, 1, 0, 1]]}]}

    def test_coverage_is_per_id_and_timeout_is_not_a_miss(self):
        raw = self.raw()
        raw['trials'].append(dict(raw['trials'][0], id='shot:1', status='timeout', events=[], cells=[], trace=[]))
        trials = [{'id': r['id'], 'scenario': 'shot'} for r in raw['trials']]
        result = summarize(raw, trials)
        self.assertEqual([x['hits'] for x in result['inventory']], [1, 0])
        self.assertEqual(result['scenarios']['shot']['outcomes'], {'success': 1, 'timeout': 1})
        self.assertGreater(wilson(0, 10)[1], 0)

    def test_requirements_fail_for_missing_success_and_traps(self):
        raw = self.raw()
        specs = [{'id': 'shot:0', 'scenario': 'shot', 'require': {'successesAtLeast': 2, 'stuckAtMost': 0}}]
        report = summarize(raw, specs)
        self.assertFalse(report['passed'])
        self.assertIn('observed 1', report['failures'][0])
        raw['trials'][0]['status'] = 'stuck'
        self.assertEqual(len(summarize(raw, specs)['failures']), 2)
        raw['layoutIssues'] = [{'first': 'bumper', 'second': 'ramp'}]
        self.assertEqual(len(summarize(raw, specs)['failures']), 3)

    def test_maps_keep_layers_separate_and_paths_do_not_connect_balls(self):
        raw = self.raw()
        ground, ramp = svg_map(raw, 0), svg_map(raw, 1)
        self.assertIn('0.2000s', ground)
        self.assertNotIn('0.1000s', ground)
        self.assertIn('0.1000s', ramp)
        self.assertEqual(svg_paths(raw).count('<polyline'), 2)
        for svg in (ground, ramp, svg_paths(raw)):
            ET.fromstring(svg)

    def test_report_is_self_contained_and_saves_exact_replay(self):
        raw = self.raw()
        request = {'trials': [{'id': 'shot:0', 'scenario': 'shot', 'seed': 1}]}
        with tempfile.TemporaryDirectory() as directory:
            write_report(raw, request, directory)
            p = Path(directory)
            self.assertEqual(json.loads((p/'replay.json').read_text()), request)
            self.assertIn('&lt;test&gt;', (p/'index.html').read_text())
            self.assertEqual(len(list(p.glob('*.svg'))), 5)


if __name__ == '__main__':
    unittest.main()
