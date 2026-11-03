#!/usr/bin/env python3
"""Build the game's data from Scenes/*.xml:

    python3 tools/scene/compile_scenes.py [--out DIR] [--tables-only]

Each XML under Scenes/tables is a table built on Scenes/base.xml: its layout and rules, written to
GameData/Tables as JSON with the parts generated from that layout (rollover bars, arrow lamps, ramp
funnel walls). The sprites are drawn from that JSON at run time.
"""
import argparse
import json
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from shim import ROOT, Vector, geometry, ramp_paths  # noqa: E402
import table_xml  # noqa: E402

BAR_BELOW_LAMP = .075  # From a lamp's centre to the centre of the rollover bar it owns.
ARROW_GAP = .03        # Clear board between a part's footprint and the point of the arrow under it: what a lamp leaves to its bar.
ARROW_SIZE = .026
ARROW_ICON = 7


# ------------------------------------------------------------------------------- Table

def expand_points(points):
    out = []
    for entry in points:
        if isinstance(entry, dict):
            cx, cy, r, a0, a1, n = entry['arc']
            out.extend((cx + r * math.cos(math.radians(a0 + (a1 - a0) * i / n)), cy + r * math.sin(math.radians(a0 + (a1 - a0) * i / n))) for i in range(n + 1))
        else:
            out.append(tuple(entry))
    return out


def rounded(values):
    return [round(float(v), 6) for v in values]


def spec_for(ramp):
    spec = geometry.TrackSpec.from_dict({'width': ramp['width'], **ramp.get('authoring', {})})
    spec.triangle_budget = min(6000, spec.triangle_budget)
    return spec


def place_bars(table):
    """A lamp's `bar` names the rollover it owns: the switch goes on the bar, a fixed distance below the lamp."""
    rollovers = {r['id']: r for r in table['rollovers']}
    for lamp in table['lamps']:
        if 'bar' in lamp:
            if lamp['bar'] not in rollovers:
                raise ValueError(f"{table['id']}/{lamp['id']}: no rollover named {lamp['bar']}")
            rollovers[lamp['bar']].update(x=lamp['x'], y=round(lamp['y'] - BAR_BELOW_LAMP, 6), plate=True)
    for rollover in table['rollovers']:
        if 'x' not in rollover:
            raise ValueError(f"{table['id']}/{rollover['id']}: needs a lamp with bar=\"{rollover['id']}\", or its own x and y")
        rollover.setdefault('plate', False)


def footprint(kind, part, table):
    """A part's centre and the lowest point of what is drawn for it, as check_spacing sizes the kit."""
    if kind in ('spinners', 'standups', 'dropTargets', 'gates'):
        a, b = part['a'], part['b']
        # A spinner's framed plate hangs 0.092 long on its axle, so its frame reaches well past its line.
        return (a[0] + b[0]) * .5, min(a[1], b[1]) - (.046 if kind == 'spinners' else .008)
    x, y = part['x'], part['y']
    if kind == 'kickbacks':
        return x, y - .035 - .018
    if kind == 'rollovers':
        return x, y - .03
    if kind == 'captiveBalls':
        return x, y - table['physics']['ballRadius']
    return x, y - part['r'] * (1.15 if kind == 'bumpers' else 1.12 if kind == 'saucers' else 1)


def place_arrows(table):
    """A part's `arrow` names a colour: an arrow lamp goes under the part, centred on it and pointing
    at it, so it is always aligned. `arrowBind` lights it from the rules, as a lamp's `bind` does."""
    for kind in ('spinners', 'standups', 'dropTargets', 'gates', 'kickbacks', 'rollovers', 'captiveBalls', 'bumpers', 'saucers', 'posts', 'stoppers', 'magnets'):
        for part in table.get(kind, []):
            if 'arrow' not in part:
                continue
            if kind == 'rollovers' and 'x' not in part:
                raise ValueError(f"{table['id']}/{part['id']}: a rollover on a bar cannot carry an arrow")
            x, bottom = footprint(kind, part, table)
            lamp = {'id': 'lamp' + part['id'][0].upper() + part['id'][1:], 'x': round(x, 6), 'y': round(bottom - ARROW_GAP - ARROW_SIZE * .8, 6),
                    'size': ARROW_SIZE, 'color': part['arrow'], 'icon': ARROW_ICON, 'shape': 'arrow', 'angle': 90, 'arrowFor': part['id']}
            if 'arrowBind' in part:
                lamp['bind'] = part['arrowBind']
            if 'layers' in part:
                lamp['layers'] = part['layers']
            table['lamps'].append(lamp)


def table_json(scene):
    """The scene's layout plus what it generates: rollover bars, arrows under parts, and the ramps' funnel walls and entrance lamps."""
    table = json.loads(json.dumps(scene))
    place_bars(table)
    place_arrows(table)
    for ramp in table['ramps']:
        ramp.setdefault('model', f"{table['id']}-{ramp['id']}")
        # A ramp may be a few control points: the game gets the same smooth line as the mesh.
        if not ramp.get('authoring', {}).get('path_sampled'):
            ramp['points'] = [rounded(p) for p in ramp_paths.loft_path(ramp['points'])]
            ramp['authoring']['path_sampled'] = True
    for ramp in table['ramps']:
        ramp['plasticUntil'] = len(ramp['points']) - 1
        spec = spec_for(ramp)
        path = [Vector(p) for p in ramp['points']]
        p, _, n = geometry.sample(path, geometry.arc_lengths(path), 0)
        half = spec.width * .5 * (spec.flare if spec.entrance == 'FLARED' else 1)
        ramp['mouth'] = [rounded(p.xy - n * half), rounded(p.xy + n * half)]
        if spec.entrance_funnel:
            for line, side in zip(geometry.funnel_walls(path, spec), 'LR'):
                table['walls'].append({'id': ramp['id'] + 'Funnel' + side, 'ramp': ramp['id'], 'style': 'none', 'radius': .006,
                                       'height': spec.wall_height, 'layers': ['playfield'], 'points': [rounded(q) for q in line]})
    for ramp in table['ramps']:
        spec = spec_for(ramp)
        if spec.entrance_lamp:
            centre, heading = geometry.entrance_lamp([Vector(p) for p in ramp['points']], spec, table)
            table['lamps'].append({'id': 'lamp' + ramp['id'][0].upper() + ramp['id'][1:], 'ramp': ramp['id'], 'x': round(centre.x, 6), 'y': round(centre.y, 6),
                                   'size': round(spec.entrance_lamp_size, 6), 'color': 'magenta', 'icon': 7, 'bind': 'rampHot', 'shape': 'arrow',
                                   'angle': round(math.degrees(math.atan2(heading.y, heading.x)), 6)})
    for ramp in table['ramps']:
        built = geometry.build_track([Vector(p) for p in ramp['points']], spec_for(ramp), lambda xy, r, tight=False: geometry.clear_support(table, xy, r, tight))
        ramp['authoring']['columns'] = [rounded(p) for p in built.metadata['support_centres']]
    return table


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, default=ROOT, help='Root to write under, instead of the repository')
    parser.add_argument('--tables-only', action='store_true', help='Accepted for older scripts; tables are all this writes')
    args = parser.parse_args()
    tables = args.out / 'GameData/Tables'
    tables.mkdir(parents=True, exist_ok=True)
    for path in table_xml.table_paths():
        table = table_json(table_xml.read(path))
        (tables / f"{table['id']}.json").write_text(json.dumps(table, indent=1) + '\n')


if __name__ == '__main__':
    main()
