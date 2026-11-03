#!/usr/bin/env python3
"""Checks for the scene format: run by `make test`, with no Xcode needed."""
import ast
import json
import math
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from shim import ROOT  # noqa: E402
import shapes  # noqa: E402
import table_xml  # noqa: E402
import compile_scenes  # noqa: E402
import check_spacing  # noqa: E402


# Expressions in scene XML stay arithmetic.
assert abs(shapes.evaluate(ast.parse('180+slope*2', mode='eval'), {'slope': 25}) - 230) < 1e-9, 'named angles evaluate'
try:
    shapes.evaluate(ast.parse('__import__', mode='eval'), {})
    raise AssertionError('expressions must stay arithmetic')
except (KeyError, ValueError):
    pass
try:
    shapes.evaluate(ast.parse('open("x")', mode='eval'), {})
    raise AssertionError('only whitelisted functions may be called')
except ValueError:
    pass
# Rounded convex outlines keep each arc at its radius from one centre.
square = shapes.filleted(shapes.ccw([(0, 0), (0, 1), (1, 1), (1, 0)]), .1, 8)
assert len(square) == 36 and all(-1e-9 <= x <= 1 + 1e-9 and -1e-9 <= y <= 1 + 1e-9 for x, y in square), 'fillets stay inside the outline'
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
    # A slingshot's sprite is its collider: a convex body wall, whose points are the corner-arc centres
    # (and bolt positions), swept by its corner radius, with the kicker capsule on the long face.
    walls = {w['id']: w for w in compiled['walls']}
    for sling in compiled['slingshots']:
        body = walls[sling['body']]
        p, r = body['points'], body['radius']
        assert len(p) == 3 and r >= .012 - 1e-9, f"{sling['id']}: rounded triangle body large enough for bolts"
        long_face = (p[2][0] - p[0][0], p[2][1] - p[0][1])
        normal = (long_face[1], -long_face[0]) if long_face[1] < 0 else (-long_face[1], long_face[0])
        normal = (normal[0] / math.hypot(*normal), normal[1] / math.hypot(*normal))
        if (p[1][0] - p[0][0]) * normal[0] + (p[1][1] - p[0][1]) * normal[1] > 0:
            normal = (-normal[0], -normal[1])
        for end, corner in ((sling['a'], p[0]), (sling['b'], p[2])) if sling['a'][1] > sling['b'][1] else ((sling['b'], p[0]), (sling['a'], p[2])):
            offset = ((end[0] - corner[0]) * normal[0] + (end[1] - corner[1]) * normal[1], math.dist(end, corner))
            assert abs(offset[0] - (r - .008)) < 2e-6 and abs(offset[1] - (r - .008)) < 2e-6, \
                f"{sling['id']}: kicker face coincides with the body face and its caps stay within the corner arcs"
    lane_faces = {'outlaneLeft': ('outer', 'inlaneL'), 'inlaneLeft': ('inlaneL', 'slingBackL'),
                  'inlaneRight': ('slingBackR', 'inlaneR'), 'outlaneRight': ('inlaneR', 'shooterInner')}
    for lamp in compiled['lamps']:
        if lamp.get('bar') in lane_faces:
            a, b = check_spacing.lane_bounds(compiled, *lane_faces[lamp['bar']], .43)
            assert abs(lamp['x'] - (a + b) * .5) < 1e-7, f"{lamp['id']}: lamp and rollover centred in clear lane"
            assert b - a > compiled['physics']['ballRadius'] * 2 + .01, 'lower lanes have room beyond the ball diameter'
    if path.stem in ('aurora', 'meridian', 'tide'):
        assert compiled['size'] == [1.0, 1.6], 'compact sprite board'
        assert not compiled['ramps'] and compiled['rules']['locksForMultiball'] == 0, 'campaign stays on one plane, without locks'
        assert all(abs(p['r'] - .068) < 1e-7 for p in compiled['bumpers']), 'match-3 bumper scale'
        assert all(abs(math.dist(p['a'], p['b']) - .085) < 1e-6 for p in compiled['dropTargets']), 'large readable drop faces (six-decimal compiler precision)'
        # Three top lanes use just two short internal dividers; the outer mouths stay open.
        guides = [w for w in compiled['walls'] if w['id'].startswith('laneGuide')]
        assert len(guides) == 2 and all(math.dist(w['points'][0], w['points'][-1]) <= .09 + 1e-7 for w in guides), 'compact top dividers'
        a, b = check_spacing.lane_bounds(compiled, 'laneGuideB', 'laneGuideC', 1.485)
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
assert check_spacing.gap(near[0], raised) < 0, 'flat sprites overlap regardless of legacy elevation'
assert abs(raised.capsules[0][0][0]) < 1e-9 and abs(raised.capsules[0][0][1] - (1 + .2 * math.tan(check_spacing.TILT))) < 1e-9, 'orthographic height shifts up-table without sideways growth'
# Campaign progression: each level introduces its own elements and keeps those taught before it.
levels = json.loads((ROOT / 'GameData/Levels.json').read_text())['levels']
INTRODUCES = {'l01': {'bumpers', 'standups', 'rollovers'}, 'l02': {'dropTargets', 'spinners'}, 'l03': {'saucers', 'kickbacks'}}
GOALS = {'l01': 'bumpers', 'l02': 'drops', 'l03': 'saucers'}
taught = set()
for level in levels:
    shipped = json.loads((ROOT / 'GameData/Tables' / f"{level['table']}.json").read_text())
    present = {k for k in ('bumpers', 'standups', 'rollovers', 'dropTargets', 'spinners', 'saucers', 'kickbacks', 'magnets', 'captiveBalls', 'stoppers', 'ramps') if shipped.get(k)}
    new = INTRODUCES.get(level['id'], set())
    assert new <= present, f"{level['id']}: introduces {sorted(new - present)} but does not contain them"
    assert present <= taught | new, f"{level['id']}: uses {sorted(present - taught - new)} before they are introduced"
    assert level['goal'] == GOALS.get(level['id'], level['goal']), f"{level['id']}: the goal is the new element"
    taught |= new
print('SCENES PASSED')
