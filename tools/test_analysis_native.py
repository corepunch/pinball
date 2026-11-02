"""Integration tests against real App/Core. Run on macOS, also in CI."""
import json
import subprocess
import tempfile
import time
from pathlib import Path

from analyze_table import ROOT, build, expand_suite, write_report


def main():
    exe = build()
    table = json.loads((ROOT/'GameData/Tables/aurora.json').read_text())
    suite = json.loads((ROOT/'GameData/Analysis/authoring.json').read_text())
    trials = expand_suite(suite, table)
    request = {'table': str(ROOT/'GameData/Tables/aurora.json'), 'grid': 32, 'workers': 1, 'trials': trials}
    with subprocess.Popen([str(exe)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) as process:
        def run(req):
            process.stdin.write(json.dumps(req)+'\n')
            process.stdin.flush()
            raw = json.loads(process.stdout.readline())
            assert 'error' not in raw, raw
            return raw
        first = run(request)
        warm_started = time.monotonic()
        second = run(dict(request, workers=4))
        for left, right in zip(first['trials'], second['trials']):
            for field in ('events', 'cells', 'trace', 'status', 'steps', 'sequenceMatched', 'returned'):
                assert left[field] == right[field], (field, left['id'])
        assert all(r['status'] != 'invalid' for r in first['trials'])
        write_report(second, request, ROOT/'Build/Analysis/reports/authoring')
        warm_seconds = time.monotonic()-warm_started
        print(f'Authoring: {len(trials)} trials, {second["wallSeconds"]:.3f}s native, {warm_seconds:.3f}s with transfer and report (4 workers)')
        assert warm_seconds < 5, f'Warm authoring feedback exceeded 5s budget: {warm_seconds:.3f}s' 
        # A closed fixture target must not pass. A real bumper at its fixture must.
        fixture = dict(table)
        for key in ('walls', 'posts', 'flippers', 'bumpers', 'slingshots', 'dropTargets', 'standups', 'rollovers', 'spinners', 'saucers', 'gates', 'kickbacks', 'magnets', 'captiveBalls', 'ramps'):
            fixture[key] = []
        fixture['physics'] = dict(table['physics'], gravity=0)
        fixture['bumpers'] = [{'id': 'fixture', 'x': .5, 'y': 1, 'r': .04}]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'fixture.json'
            path.write_text(json.dumps(fixture))
            positive = {'id': 'hit', 'mode': 'fixture', 'position': [.569, 1], 'velocity': [-1, 0], 'seconds': .1, 'seed': 1, 'expect': [{'event': 'bumper', 'element': 'fixture'}]}
            negative = dict(positive, id='miss', position=[.2, .2], velocity=[0, 0])
            strict = dict(negative, id='trap', seconds=4)
            raw = run({'table': str(path), 'grid': 32, 'workers': 1, 'trials': [positive, negative, strict]})
            assert [r['status'] for r in raw['trials']] == ['success', 'timeout', 'stuck'], [(r['id'], r['status']) for r in raw['trials']]
        # Coverage report for each shipping table; defects are reported, never hidden.
        for name in sorted(p.stem for p in (ROOT/'GameData/Tables').glob('*.json')):
            data = json.loads((ROOT/f'GameData/Tables/{name}.json').read_text())
            specs = expand_suite(json.loads((ROOT/'GameData/Analysis/coverage.json').read_text()), data)
            req = {'table': str(ROOT/f'GameData/Tables/{name}.json'), 'grid': 32, 'workers': 4, 'trials': specs}
            raw = run(req)
            assert all(r['status'] != 'invalid' for r in raw['trials'])
            write_report(raw, req, ROOT/f'Build/Analysis/reports/{name}')
            print(name, 'coverage wall seconds', raw['wallSeconds'])
            print(name, 'coverage', [(x['event'], x['element'], x['hits']) for x in __import__('analyze_table').summarize(raw, specs)['inventory']])
        process.stdin.close()
        assert process.wait() == 0


if __name__ == '__main__':
    main()
