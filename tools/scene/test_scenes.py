#!/usr/bin/env python3
"""Checks for the scene format: run by `make test`, with no Xcode needed."""
import json
import math
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from shim import ROOT, geometry  # noqa: E402
import mesher  # noqa: E402
import prefabs  # noqa: E402
import table_xml  # noqa: E402
import compile_scenes  # noqa: E402
import check_spacing  # noqa: E402


def built(xml, names=None):
    kit = {e.get('id'): e for e in ET.fromstring(f'<kit>{xml}</kit>')}
    return prefabs.Builder(kit).build(next(iter(kit)), names)


# A button is a circle with modifiers: extruded, bevelled, and every normal points outward.
button = built('<prefab id="b"><let name="R" value=".5"/><circle radius="{R*2}" role="accent" segments="16"><extrude amount=".2"/><bevel amount=".02"/></circle></prefab>')
assert abs(max(math.hypot(v[0], v[1]) for v in button.vertices) - 1) < 1e-6, 'expressions size shapes'
assert abs(max(v[2] for v in button.vertices) - .2) < 1e-6, 'extrude sets height'
normals = mesher.corner_normals(button)
for (face, vertex), normal in normals.items():
    v = button.vertices[vertex]
    assert normal[0] * v[0] + normal[1] * v[1] + normal[2] * v[2] > 0, 'faces point outward'
# Modifiers run in order, and prefabs nest with their own variables.
nested = built('<prefab id="a"><use prefab="c" r="2" at="1,0"/></prefab><prefab id="c"><lathe role="metal" segments="8" points="{r},0 {r},1"/></prefab>')
assert abs(max(v[0] for v in nested.vertices) - 3) < 1e-6, '<use> passes variables and position'
try:
    built('<prefab id="x"><blob role="metal"/></prefab>')
    raise AssertionError('unknown elements must fail')
except ValueError:
    pass
try:
    built('<prefab id="x"><circle radius="{__import__}" role="metal"/></prefab>')
    raise AssertionError('expressions must stay arithmetic')
except (KeyError, ValueError):
    pass
# Concave polygons triangulate into the same area.
ell = [(0, 0, 0), (2, 0, 0), (2, 1, 0), (1, 1, 0), (1, 2, 0), (0, 2, 0)]
area = sum(abs((ell[b][0] - ell[a][0]) * (ell[c][1] - ell[a][1]) - (ell[b][1] - ell[a][1]) * (ell[c][0] - ell[a][0])) * .5 for a, b, c in mesher.triangulate(ell, list(range(6))))
assert abs(area - 3) < 1e-9, 'concave triangulation covers the outline'
# Tables survive XML both ways, and the checked-in JSON is what the scenes compile to.
base = table_xml.read(ROOT / 'Scenes/base.xml')
for path in table_xml.table_paths():
    table = table_xml.read(path)
    with tempfile.TemporaryDirectory() as temporary:
        copy = Path(temporary) / 'table.xml'
        table_xml.write(table, copy)
        assert table_xml.read(copy) == table, f'{path.stem}: XML round trip'
    compiled = compile_scenes.table_json(table)
    shipped = json.loads((ROOT / f"GameData/Tables/{table['id']}.json").read_text())
    assert json.dumps(compiled, sort_keys=True) == json.dumps(shipped, sort_keys=True), f"{path.stem}: run `make scenes`: GameData/Tables is out of date"
    # What the base declares, every table has, unchanged.
    for key, parts in base.items():
        if isinstance(parts, list) and parts and isinstance(parts[0], dict) and 'id' in parts[0]:
            found = {item['id']: item for item in table[key]}
            for part in parts:
                assert found.get(part['id']) == part, f"{path.stem}: base part {part['id']} was changed or removed"
    # Nothing crowds anything else on the phone's screen, and the checker can see crowding.
    assert not (crowded := check_spacing.problems(compiled)), f'{path.stem}: run tools/scene/check_spacing.py: {crowded}'
    # Every rollover bar sits the same distance from the lamp that owns it.
    lamps = {lamp['bar']: lamp for lamp in compiled['lamps'] if 'bar' in lamp}
    for rollover in compiled['rollovers']:
        assert rollover['id'] in lamps, f"{path.stem}/{rollover['id']}: a rollover belongs to a lamp"
        assert rollover['x'] == lamps[rollover['id']]['x'] and abs(lamps[rollover['id']]['y'] - rollover['y'] - compile_scenes.BAR_BELOW_LAMP) < 1e-6, f"{path.stem}/{rollover['id']}: bar out of place"
    # An arrow under a part is generated there, centred on the part and clear of it, so it cannot drift.
    for kind in ('spinners', 'saucers', 'kickbacks', 'standups', 'bumpers'):
        for part in compiled.get(kind, []):
            if 'arrow' in part:
                lamp = next(l for l in compiled['lamps'] if l.get('arrowFor') == part['id'])
                x, bottom = compile_scenes.footprint(kind, part, compiled)
                assert lamp['x'] == round(x, 6) and lamp['y'] + lamp['size'] * .8 < bottom, f"{path.stem}/{part['id']}: arrow out of place"
# A cover is its outline with its stencils cut out: what is left on top is exactly that much board.
plate = mesher.MeshData()
mesher.slab(plate, [(0, 0), (4, 0), (4, 4), (0, 4)], [[(1, 1), (2, 1), (2, 2), (1, 2)], [(3, 3), (3.5, 3), (3.5, 3.5), (3, 3.5)]], 0, .1, 'cover')
top = sum(abs(mesher.signed_area([plate.vertices[i][:2] for i in t])) for face in plate.faces if all(abs(plate.vertices[i][2] - .1) < 1e-9 for i in face) for t in mesher.triangulate(plate.vertices, face))
assert abs(top - (16 - 1 - .25)) < 1e-9, 'stencils cut holes in the cover'
# A cover along a wall is that wall's shape: a straight bar's outline is a stadium.
bar = mesher.outline_along([(0, 0), (2, 0)], .5, 16)
assert abs(abs(mesher.signed_area(bar)) - (2 + math.pi * .25)) < .01 and mesher.signed_area(bar) > 0, 'outline_along is a round-ended, counter-clockwise bar'
bent = mesher.outline_along([(0, 0), (1, 0), (1, 1)], .1, 16)
# Two bars less the square they share at the inside of the bend, plus a quarter disc outside it and the two end caps.
assert abs(mesher.signed_area(bent) - (2 * .2 - .01 + math.pi * .01 / 4 + math.pi * .01)) < .002, 'a bend is mitred inside and rounded outside'
try:
    mesher.slab(mesher.MeshData(), [(0, 0), (1, 0), (1, 1), (0, 1)], [[(2, 2), (3, 2), (3, 3)]], 0, .1, 'cover')
    raise AssertionError('a stencil outside the cover must fail')
except ValueError:
    pass
arrowed = {'id': 't', 'physics': {'ballRadius': .03}, 'lamps': [], 'spinners': [{'id': 'spin', 'a': [0, 1], 'b': [.1, 1], 'arrow': 'cyan', 'arrowBind': 'orbitHot'}]}
compile_scenes.place_arrows(arrowed)
assert arrowed['lamps'][0]['id'] == 'lampSpin' and arrowed['lamps'][0]['x'] == .05 and arrowed['lamps'][0]['y'] < 1 - .008 - compile_scenes.ARROW_GAP and arrowed['lamps'][0]['bind'] == 'orbitHot', 'arrow="colour" makes an arrow lamp under the part'
loose = {'id': 't', 'lamps': [], 'rollovers': [{'id': 'r', 'r': .03}]}
try:
    compile_scenes.place_bars(loose)
    raise AssertionError('a rollover with no lamp and no position must fail')
except ValueError:
    pass
near = [check_spacing.Part(name, 'part').disc(x, 1, .03) for name, x in (('a', 0), ('b', .065), ('c', .2))]
assert check_spacing.gap(near[0], near[1]) * check_spacing.POINTS < check_spacing.MIN_GAP <= check_spacing.gap(near[0], near[2]) * check_spacing.POINTS, 'spacing measures clear board'
# A line can be a point, a rotation and a length, with rotations shared by name.
named = {'angles': {'slope': 30}, 'walls': [{'id': 'w', 'points': [[1, 1], {'dir': ['180-slope', 2]}]}], 'gates': [{'id': 'g', 'a': [0, 0], 'rotation': '-slope', 'length': 2}], 'flippers': [{'id': 'f', 'restAngle': '180+slope'}]}
table_xml.finished(named)
assert named['walls'][0]['points'][1] == [round(1 - math.sqrt(3), 6), 2.0] and named['gates'][0]['b'] == [round(math.sqrt(3), 6), -1.0] and named['flippers'][0]['restAngle'] == 210, 'named rotations and dir() resolve'
assert 'dir' not in json.dumps(table_xml.read(ROOT / 'Scenes/base.xml')['walls']), 'the game reads plain points'
crooked = compile_scenes.table_json(table_xml.read(table_xml.table_paths()[0]))
next(w for w in crooked['walls'] if w['id'] == 'inlaneL')['points'][2][1] += .02
assert any(f[1] == 'slope angles' for f in check_spacing.unmatched_angles(crooked)), 'the checker sees a line off its angle'
# The checker sees one side of the board growing wider than the other.
lanes = {'walls': [dict(id='l', points=[[0, 0], [0, 1]], radius=.01), dict(id='m', points=[[.1, 0], [.1, 1]], radius=.01), dict(id='r', points=[[.3, 0], [.3, 1]], radius=.01)]}
assert abs(check_spacing.lane_width(lanes, 'l', 'm', .5) - .08) < 1e-9 and abs(check_spacing.lane_width(lanes, 'm', 'r', .5) - .18) < 1e-9, 'lanes are measured between wall faces'
raised = check_spacing.Part('r', 'part').disc(0, 1, .03, .2)
assert check_spacing.gap(near[0], raised) > .03, 'spacing is measured through the camera: height moves a part up the screen'
print('SCENES PASSED')
