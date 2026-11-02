#!/usr/bin/env python3
"""Build the game's data from Scenes/*.xml:

    python3 tools/scene/compile_scenes.py [--out DIR] [--tables-only]

Scenes/kit.xml declares every part as shapes and modifiers. Each other XML is a table: its layout and rules,
written to GameData/Tables as JSON, with its flippers, walls, plastics and ramps built from that layout.
Meshes go to Art/Models/premium as COLLADA; tools/compile_models.sh turns those into the shipped .scn.
"""
import argparse
import json
import math
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from shim import ROOT, Vector, geometry, ramp_paths  # noqa: E402
import mesher  # noqa: E402
import prefabs  # noqa: E402
import table_xml  # noqa: E402

ROLES = {
    'cabinet_shell': (.018, .035, .065, 1), 'guide_glow': (1, .32, .04, 1), 'channel_liner': (.29, .35, .40, 1), 'plate_frame': (.62, .63, .66, 1),
    'channel_entry': (.72, .6, .38, 1), 'channel_floor': (.52, .57, .61, 1), 'channel_aluminum': (.66, .71, .75, 1), 'channel_shell': (.35, .40, .44, 1),
    'channel_arrow': (1, .12, .025, 1), 'metal': (.56, .61, .65, 1), 'accent': (.72, .48, .19, 1), 'dark': (.012, .019, .027, 1),
    'rubber': (.62, .58, .47, 1), 'black_rubber': (.012, .012, .014, 1), 'skirt_lamp': (1, .2, .08, 1), 'cap_art': (.7, .2, .12, 1), 'enamel': (.86, .78, .6, 1),
    'lens': (.9, .95, 1, .18), 'glow': (.2, .8, 1, 1), 'glow_amber': (1, .65, .16, 1), 'jewel': (.2, .8, 1, 1), 'ramp_floor': (.58, .62, .66, 1),
    'sling_lens': (1, .25, .1, 1), 'sling_lens_0': (1, .25, .1, 1), 'sling_lens_1': (1, .25, .1, 1), 'target_lens': (1, .25, .1, 1), 'amber_lens': (1, .65, .16, 1), 'wall_art': (.05, .12, .14, 1), 'block_art': (.05, .18, .18, 1),
    'flipper_art': (.9, .85, .7, 1), 'target_art': (.6, .3, .15, 1), 'cover': (.3, .07, .11, 1),
}
THIN_WALL = .01  # A wall of less radius has no room for a coloured top: it is solid metal.
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


def resampled(points, spacing=.007):
    """Even steps along a ramp's line: what the mesh is lofted along."""
    pts = [Vector(p) for p in points]
    lengths = geometry.arc_lengths(pts)
    count = max(2, math.ceil(lengths[-1] / spacing))
    return [geometry.sample(pts, lengths, lengths[-1] * i / count)[0] for i in range(count + 1)]


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


def walls_part(table, centred, skip=()):
    data = mesher.MeshData()
    for wall in table['walls']:
        if wall['id'] in skip:
            continue
        if wall['style'] in ('wall', 'rail', 'rubber'):
            built = geometry.build_wall([centred(*p) for p in expand_points(wall['points'])], wall['radius'], wall['height'])
            roles = ['accent' for _ in built.roles] if wall['radius'] < THIN_WALL else built.roles
            # A wall on the second level stands on it.
            base = table['deck']['height'] if 'deck' in wall.get('layers', []) else 0
            data.add([(v[0], v[1], v[2] + base) for v in built.vertices], built.faces, roles, None, 50)
    return data


def cover_part(table, centred, skip=()):
    """Each laser-cut cover: a plate over its outline with its stencils cut out, at its height."""
    data = mesher.MeshData()
    for cover in table.get('covers', []):
        if cover['id'] in skip:
            continue
        outline = [centred(*p) for p in expand_points(cover['points'])]
        holes = [[centred(*p) for p in expand_points(s['points'])] for s in cover.get('stencils', [])]
        thickness = cover.get('thickness', cover['height'])
        mesher.slab(data, outline, holes, cover['height'] - thickness, thickness, 'cover')
    return data


def outline_text(points):
    return ' '.join(f'{p[0]:.8g},{p[1]:.8g}' for p in points)


def plastics_part(table, centred, builder, skip=()):
    """Each raised shape on the table, as a kit prefab over its outline."""
    data = mesher.MeshData()
    # Each bouncer gets its own lens, in the order of the table's slingshots, to light when it is hit.
    shapes = [(p['id'], expand_points(p['points']), 'slingshot', f'sling_lens_{i}') for i, p in enumerate(table['plastics'])]
    shapes += [(w['id'], expand_points(w['points']), w.get('part', 'docking-pod' if w['id'] == 'captiveHousing' else 'housing'), None) for w in table['walls'] if w['style'] == 'plastic']
    for name, path, prefab, lens in shapes:
        if name in skip:
            continue
        outline = mesher.ccw([centred(*p) for p in path])
        x0, x1 = min(p[0] for p in outline), max(p[0] for p in outline)
        y0, y1 = min(p[1] for p in outline), max(p[1] for p in outline)
        names = {'outline': outline_text(outline), 'tray': outline_text([(x0, y0), (x1, y0), (x1, y1 - .025), (x0, y1 - .025)]),
                 'height': next((w['height'] for w in table['walls'] if w['id'] == name), .006), 'lens': lens}
        built = builder.build(prefab, names)
        data.add(built.vertices, built.faces, built.roles, built.uvs, 0)
        data.sharp[-len(built.faces):] = built.sharp
    return data


def ramp_part(table, ramp, centred):
    spec = spec_for(ramp)
    found = ramp_paths.problems(ramp)
    if ramp_paths.measure(ramp)['drift'] > geometry.rail_geometry(spec)[0] - spec.corner_radius - table['physics']['ballRadius']:
        found.append('the ball would clip the channel walls')
    if found:
        raise ValueError(f"{table['id']}/{ramp['id']}: {found}")
    path = resampled([(*centred(p[0], p[1]), p[2]) for p in ramp_paths.ramp_path(ramp)])
    offset = (table['size'][0] * .5, table['size'][1] * .5)
    return geometry.build_track(path, spec, lambda xy, r, tight=False: geometry.clear_support(table, (xy.x + offset[0], xy.y + offset[1]), r, tight))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, default=ROOT, help='Root to write under, instead of the repository')
    parser.add_argument('--tables-only', action='store_true')
    args = parser.parse_args()
    models = args.out / 'Art/Models/premium'
    tables = args.out / 'GameData/Tables'
    tables.mkdir(parents=True, exist_ok=True)
    stats = {}
    kit = {element.get('id'): element for element in ET.parse(ROOT / 'Scenes/kit.xml').getroot()}
    builder = prefabs.Builder(kit)
    # Helpers and table-driven prefabs are not parts of their own.
    templates = {'bolt', 'bullet-lamp', 'lit-arrow', 'flipper', 'slingshot', 'docking-pod', 'housing', 'slide', 'deck'}
    parts = {name: builder.build(name) for name in kit if name not in templates}
    base = table_xml.read(ROOT / 'Scenes/base.xml')
    flipper = base['flippers'][0]
    size = base['size']
    centred = lambda x, y, s=size: (x - s[0] * .5, y - s[1] * .5)
    common = {w['id'] for w in base['walls']} | {p['id'] for p in base['plastics']} | {c['id'] for c in base.get('covers', [])}
    # Parts every table has are one model each, however many tables there are.
    parts['common-flipper'] = builder.build('flipper', {'base': flipper['baseRadius'] / flipper['length'], 'tip': flipper['tipRadius'] / flipper['length']})
    parts['common-walls'] = walls_part(base, centred)
    parts['common-plastics'] = plastics_part(base, centred, builder)
    parts['common-cover'] = cover_part(base, centred)
    for path in table_xml.table_paths():
        table = table_json(table_xml.read(path))
        (tables / f"{table['id']}.json").write_text(json.dumps(table, indent=1) + '\n')
        if args.tables_only:
            continue
        for suffix, data in (('walls', walls_part(table, centred, common)), ('plastics', plastics_part(table, centred, builder, common)), ('cover', cover_part(table, centred, common))):
            if data.faces:
                parts[f"{table['id']}-{suffix}"] = data
        for ramp in table['ramps']:
            if ramp['model'] not in parts:
                parts[ramp['model']] = ramp_part(table, ramp, centred)
    if args.tables_only:
        return
    models.mkdir(parents=True, exist_ok=True)
    for name, data in parts.items():
        stats[name] = mesher.write_collada(name, data, models / f'{name}.dae', ROLES)
        if data.metadata:
            stats[name].update(section=data.metadata['section'], arrow_count=data.metadata['arrow_count'], arrow_spacing=round(data.metadata['arrow_spacing'], 6))
    for stale in models.glob('*.dae'):
        if stale.stem not in parts:
            stale.unlink()
    (args.out / 'Art/Models/manifest.json').write_text(json.dumps({'generator': 'tools/scene/compile_scenes.py', 'assets': stats}, indent=2) + '\n')
    print(f'{len(stats)} models, {sum(s["triangles"] for s in stats.values())} triangles')


if __name__ == '__main__':
    main()
