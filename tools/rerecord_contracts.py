#!/usr/bin/env python3
"""Re-record real-flipper route contracts after a deliberate lower-kit geometry change.

    python3 tools/rerecord_contracts.py <table> [--write]

Each flipper fixture in GameData/Analysis/<table>.json starts the ball resting on a flipper at a
fraction of its length, optionally rolling along it, then flips. When the geometry changes, those
exact starting points stop reproducing their routes. For every scenario that now fails its own
`require` thresholds, this searches the same grid the shot playtest fires (40 contact points,
roll 0/0.5/1/1.5 along the flipper) with the scenario's flipper, controls, expected events,
return box, seeds and thresholds unchanged, and keeps the passing start nearest the old one.
A scenario with no passing start is reported and left as it was, so the suite still fails: the
layout, not the contract, must then change. Runs production physics; requires macOS.
"""
import json
import math
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ROLLS = (0.0, 0.5, 1.0, 1.5)
CONTACTS = [i / 39 for i in range(40)]  # The shot playtest's 40 contact points (tools/playtest/shots.m).



def analyze(table_path, suite):
    with tempfile.TemporaryDirectory() as work:
        suite_path = Path(work) / 'suite.json'
        suite_path.write_text(json.dumps(suite))
        out = Path(work) / 'report'
        subprocess.run([sys.executable, str(ROOT / 'tools/analyze_table.py'), str(table_path), '--suite', str(suite_path),
                        '--out', str(out), '--workers', '4'], check=True, stdout=subprocess.DEVNULL)
        return json.loads((out / 'report.json').read_text())


def passes(group, require):
    actual = {'successesAtLeast': group['outcomes'].get('success', 0), 'returnsAtLeast': group['returns'],
              'stuckAtMost': group['outcomes'].get('stuck', 0)}
    return all(actual[k] <= v if k == 'stuckAtMost' else actual[k] >= v for k, v in require.items())


def flipper_of(scenario, table):
    first = (scenario.get('controls') or [{}])[0]
    side = 'left' if first.get('left') else 'right' if first.get('right') else None
    if side is None or first.get('at') != 0:
        return None
    return next(f for f in table['flippers'] if f['side'] == side)


def start(flipper, ball, contact, roll):
    angle = math.radians(flipper['restAngle'])
    along = (math.cos(angle), math.sin(angle))
    normal = (-along[1], along[0])
    if normal[1] < 0:
        normal = (-normal[0], -normal[1])
    radius = flipper['baseRadius'] + (flipper['tipRadius'] - flipper['baseRadius']) * contact
    lift = radius + ball + 0.002
    p = [flipper['pivot'][i] + along[i] * flipper['length'] * contact + normal[i] * lift for i in range(2)]
    return p, [along[0] * roll, along[1] * roll]


def main():
    name = sys.argv[1]
    write = '--write' in sys.argv
    table_path = ROOT / f'GameData/Tables/{name}.json'
    suite_path = ROOT / f'GameData/Analysis/{name}.json'
    table, suite = json.loads(table_path.read_text()), json.loads(suite_path.read_text())
    report = analyze(table_path, suite)
    changed, unresolved = [], []
    for index, scenario in enumerate(suite['scenarios']):
        require = scenario.get('require', {})
        if passes(report['scenarios'][scenario['id']], require):
            continue
        flipper = flipper_of(scenario, table)
        if flipper is None:
            unresolved.append(scenario['id'] + ' (not a flipper fixture)')
            continue
        candidates = []
        for contact in CONTACTS:
            for roll in ROLLS:
                position, velocity = start(flipper, table['physics']['ballRadius'], contact, roll)
                trial = dict(scenario, id=f'c{len(candidates)}', position=position, velocity=velocity)
                candidates.append((trial, contact, roll))
        result = analyze(table_path, {'scenarios': [c[0] for c in candidates]})
        old = scenario['position']
        good = [(math.dist(t['position'], old) + abs(math.hypot(*t['velocity']) - math.hypot(*scenario['velocity'])) * .1, t, c, r)
                for t, c, r in candidates if passes(result['scenarios'][t['id']], require)]
        if not good:
            unresolved.append(scenario['id'])
            continue
        _, best, contact, roll = min(good, key=lambda g: g[0])
        suite['scenarios'][index] = dict(scenario, position=best['position'], velocity=best['velocity'])
        changed.append(f"{scenario['id']}: contact {contact:.2f} roll {roll:.1f} ({len(good)} passing starts)")
    for line in changed:
        print(f'{name} re-recorded {line}')
    for line in unresolved:
        print(f'{name} UNRESOLVED {line}')
    if write and changed:
        suite_path.write_text(json.dumps(suite, indent=2) + '\n')
    sys.exit(1 if unresolved else 0)


if __name__ == '__main__':
    main()
