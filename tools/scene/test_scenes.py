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
# Actual fasteners share the centres of the rounded corner arcs, including the
# acute tip. Verify against the sampled arcs, rather than just an inset value.
kit = {part.get('id'): part for part in ET.parse(ROOT / 'Scenes/kit.xml').getroot()}
for part in table_xml.read(ROOT / 'Scenes/base.xml')['plastics']:
    outline = mesher.ccw(compile_scenes.expand_points(part['points']))
    mesh = prefabs.Builder(kit).build('slingshot', {'outline': compile_scenes.outline_text(outline), 'lens': 'sling_lens'})
    connected = {}
    for face, role in zip(mesh.faces, mesh.roles):
        if role == 'metal':
            for vertex in face:
                connected.setdefault(vertex, set()).update(face)
    centres = []
    while connected:
        pending = [next(iter(connected))]; vertices = set()
        while pending:
            vertex = pending.pop()
            if vertex not in connected:
                continue
            vertices.add(vertex); pending.extend(connected.pop(vertex))
        centres.append(tuple(sum(mesh.vertices[v][axis] for v in vertices) / len(vertices) for axis in (0, 1)))
    assert len(centres) == 3, f"{part['id']}: exactly three fastener heads"
    arcs = mesher.filleted(outline, .014)
    for corner in range(3):
        arc = arcs[corner * 9:(corner + 1) * 9]
        matches = [centre for centre in centres if all(abs(math.dist(centre, p) - .014) < 1e-7 for p in arc)]
        assert len(matches) == 1, f"{part['id']}: bolt must be concentric with rounded corner {corner}"
    normals = mesher.corner_normals(mesh)
    tops = [f for f, (face, role) in enumerate(zip(mesh.faces, mesh.roles))
            if role == 'sling_lens' and len(face) > 4]
    assert len(tops) == 1, f"{part['id']}: one uninterrupted flat top"
    for f in tops:
        top_outline = [mesh.vertices[v][:2] for v in mesh.faces[f]]
        for centre in centres:
            assert sum(abs(math.dist(centre, p) - .0115) < 1e-7 for p in top_outline) == 9, f"{part['id']}: top fillet and bolt must share the outer fillet centre"
        for v in mesh.faces[f]:
            assert abs(mesh.vertices[v][2] - .037) < 1e-9, f"{part['id']}: top must be level"
            assert math.dist(normals[(f, v)], (0, 0, 1)) < 1e-9, f"{part['id']}: top normals must not simulate a dome"
# Guides are two thin plates at half/full height, joined by exactly three tubes.
for part in table_xml.read(ROOT / 'Scenes/base.xml')['walls']:
    if part['style'] != 'rail' or not part.get('closed'):
        continue
    points = compile_scenes.expand_points(part['points'])
    original = mesher.raised_outline(points, part['radius'], part['height'])
    decorated = compile_scenes.walls_part({'walls': [part]}, lambda x, y: (x, y), prefabs.Builder(kit))
    assert all(role in decorated.roles for role in ('guide_body', 'guide_edge', 'guide_face', 'guide_inlay', 'guide_mark', 'guide_tube')), 'guide has separate plates, painted layers and tubes'
    plate_tops = [set(decorated.vertices[v][2] for v in face) for face, role in zip(decorated.faces, decorated.roles)
                  if role == 'guide_face' and len(face) > 20]
    assert any(len(z) == 1 and abs(next(iter(z)) - part['height'] * .5) < 1e-8 for z in plate_tops), 'lower plate is at 50 percent height'
    assert any(len(z) == 1 and abs(next(iter(z)) - part['height']) < 1e-8 for z in plate_tops), 'upper plate is at full height'
    for face, role in zip(decorated.faces, decorated.roles):
        heights = [decorated.vertices[v][2] for v in face]
        if role == 'guide_body':
            assert max(heights) - min(heights) <= .0035 + 1e-8, 'no monolithic side face spans the gap between plates'
    tubes = {}
    for face, role in zip(decorated.faces, decorated.roles):
        if role == 'guide_tube':
            for v in face: tubes.setdefault(v, set()).update(face)
    count = 0
    while tubes:
        count += 1; pending = [next(iter(tubes))]
        while pending:
            v = pending.pop()
            if v in tubes: pending.extend(tubes.pop(v))
    assert count == 3, 'exactly three hollow screw tubes connect the guide plates'
    for axis in range(2):
        assert min(v[axis] for v in decorated.vertices) >= min(v[axis] for v in original.vertices) - 1e-8, 'guide assembly stays inside its old footprint'
        assert max(v[axis] for v in decorated.vertices) <= max(v[axis] for v in original.vertices) + 1e-8, 'guide assembly does not narrow a channel'
    assert max(v[2] for v in decorated.vertices) <= part['height'] + .008 + 1e-8, 'small tube rims project above the upper plate'

flipper = prefabs.Builder(kit).build('flipper', {'base': .16, 'tip': .09})
for face, role in zip(flipper.faces, flipper.roles):
    if role in ('pivot_cap', 'pivot_ink'):
        assert all(math.hypot(*flipper.vertices[v][:2]) <= .16 * .34 + 1e-8 for v in face), 'small pivot detail is centred on the hinge'
assert 'metal' not in flipper.roles, 'old domed hub and tip screw are removed'
cap = [flipper.vertices[v] for face, role in zip(flipper.faces, flipper.roles) if role == 'pivot_cap' for v in face]
assert cap and max(v[2] for v in cap) < .31, 'pivot head is low and flat, not a tall dome'
assert any(all(abs(flipper.vertices[v][2] - .303) < 1e-8 for v in face) for face, role in zip(flipper.faces, flipper.roles) if role == 'pivot_cap'), 'pivot has a flat top that casts a real shadow'

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
    widths = check_spacing.lower_lane_widths(compiled)
    assert len(widths) == 4 and all(abs(w - .08125) < 1e-7 for w in widths.values()), 'all four lower lanes share the same physical clearance'
    lane_faces = {'outlaneLeft': ('outer', 'inlaneL'), 'inlaneLeft': ('inlaneL', 'slingBackL'),
                  'inlaneRight': ('slingBackR', 'inlaneR'), 'outlaneRight': ('inlaneR', 'shooterInner')}
    for lamp in compiled['lamps']:
        if lamp.get('bar') in lane_faces:
            a, b = check_spacing.lane_bounds(compiled, *lane_faces[lamp['bar']], .43)
            assert abs(lamp['x'] - (a + b) * .5) < 1e-7, f"{lamp['id']}: lamp and rollover centred in clear lane"
            assert b - a > compiled['physics']['ballRadius'] * 2 + .01, 'lower lanes have room beyond the ball diameter'
    if path.stem == 'aurora':
        assert not compiled['ramps'], 'First Light stays on one plane; ramps are deferred'
        # Three top lanes use just two short internal dividers; the outer mouths stay open.
        guides = [w for w in compiled['walls'] if w['id'].startswith('laneGuide')]
        assert len(guides) == 2 and all(math.dist(w['points'][0], w['points'][-1]) <= .09 + 1e-7 for w in guides), 'compact top dividers'
        a, b = check_spacing.lane_bounds(compiled, 'laneGuideB', 'laneGuideC', 1.765)
        assert abs(b - a - .08125) < 1e-7, 'middle top lane clear width'
        bar = next(r for r in compiled['rollovers'] if r['id'] == 'laneB')
        assert abs(bar['x'] - (a + b) * .5) < 1e-7, 'middle rollover centred in physical faces'
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
next(w for w in crooked['walls'] if w['id'] == 'inlaneL')['points'][1][1] += .02
assert any(f[1] == 'slope angles' for f in check_spacing.unmatched_angles(crooked)), 'the checker sees a line off its angle'
# The checker sees one side of the board growing wider than the other.
lanes = {'walls': [dict(id='l', points=[[0, 0], [0, 1]], radius=.01), dict(id='m', points=[[.1, 0], [.1, 1]], radius=.01), dict(id='r', points=[[.3, 0], [.3, 1]], radius=.01)]}
assert abs(check_spacing.lane_width(lanes, 'l', 'm', .5) - .08) < 1e-9 and abs(check_spacing.lane_width(lanes, 'm', 'r', .5) - .18) < 1e-9, 'lanes are measured between wall faces'
raised = check_spacing.Part('r', 'part').disc(0, 1, .03, .2)
assert check_spacing.gap(near[0], raised) > 0, 'height can visually separate parts under the tilted camera'
assert abs(raised.capsules[0][0][0]) < 1e-9 and abs(raised.capsules[0][0][1] - (1 + .2 * math.tan(check_spacing.TILT))) < 1e-9, 'orthographic height shifts up-table without sideways growth'
print('SCENES PASSED')
