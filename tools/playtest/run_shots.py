#!/usr/bin/env python3
"""Fires real flipper shots at a table and shows what each flipper can reach: `make shots`.

    python3 tools/playtest/run_shots.py [--fan] [table...]   (default: aurora; --fan lists every shot)

Runs on this Mac from the game's core code, with no Xcode or iOS build. The autopilot in `make playtest`
doesn't aim, so this is the check that a layout's shots can be made, and of where misses end up.
Exits 1 if a table has a ramp, hole or orbit that no flipper can reach.
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BINARY = ROOT / 'Build/shots'


def build():
    sources = sorted(str(p) for p in (ROOT / 'App/Core').glob('*.m'))
    BINARY.parent.mkdir(exist_ok=True)
    subprocess.run(['clang', '-O2', '-fobjc-arc', '-framework', 'Foundation', f'-I{ROOT}/App/Core', '-o', str(BINARY), str(ROOT / 'tools/playtest/shots.m'), *sources], check=True, stderr=subprocess.DEVNULL)


def wanted(table):
    """Every shot a table offers from the board: its ramps, playfield holes and both orbits."""
    shots = {'orbit left', 'orbit right'} | {f"ramp {r['id']}" for r in table['ramps']}
    return shots | {f"hole {s['id']}" for s in table['saucers'] if 'deck' not in s.get('layers', [])}


def main():
    build()
    failed = False
    for name in [a for a in sys.argv[1:] if a != '--fan'] or ['aurora']:
        path = ROOT / f'GameData/Tables/{name}.json'
        report = json.loads(subprocess.run([str(BINARY), str(path)], capture_output=True, text=True, check=True).stdout)
        print(name)
        made = set()
        for flipper, fan in sorted(report.items()):
            total = fan['shots']
            print(f'  {flipper}, {total} shots')
            for key, title in (('reached', 'reached first'), ('ended', 'ended')):
                parts = sorted(fan[key].items(), key=lambda kv: -kv[1])
                print(f'    {title}: ' + ', '.join(f'{k} {v * 100 // total}%' for k, v in parts))
            made |= set(fan['reached'])
            if '--fan' in sys.argv:
                for shot in sorted(fan['fan'], key=lambda s: s['heading']):
                    if shot['speed']:
                        print(f"      heading {shot['heading']:5.0f}  speed {shot['speed']:.1f}  bounced {shot['bounceX']:.2f},{shot['bounceY']:.2f}  {shot['reached']} -> {shot['ended']}")
        missing = sorted(wanted(json.loads(path.read_text())) - made)
        if missing:
            failed = True
            print(f'  NO FLIPPER REACHES: {", ".join(missing)}')
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
