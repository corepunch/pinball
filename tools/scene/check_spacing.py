#!/usr/bin/env python3
"""Spot parts that look crowded on the phone, with no Xcode needed:

    python3 tools/scene/check_spacing.py [--list N] [--svg DIR]

Measures what the player sees, not the table's floor plan: everything is projected through the
game's 30 degree camera, so a raised ramp is checked where it appears. Gaps are in points on a
393 point wide phone. Run by `make test`; exits 1 if a pair is too close, a row is not level, or the two sides of the board no longer mirror each other.
"""
import argparse
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from shim import ROOT  # noqa: E402
import compile_scenes  # noqa: E402
import mesher  # noqa: E402
import table_xml  # noqa: E402

# The camera: straight down from above the middle of the visible board, as PBLayoutValidator has it.
FOV = math.radians(70)   # PBTableCameraFOV
BAND = .35               # PBTableCameraBand
PHONE_ASPECT = 2.17      # PBTablePhoneAspect
VIEW = {'size': (1, 2.286), 'padding': (0, 0)}


def set_view(table):
    VIEW.update(size=tuple(table['size']), padding=tuple(table.get('padding', (0, 0))))


def visible_height():
    size, padding = VIEW['size'], VIEW['padding']
    return max(size[1] + padding[1] + BAND, (size[0] + 2 * padding[0]) * PHONE_ASPECT)
POINTS = 393  # A table's width on the phone.
MIN_GAP = 5  # Points of clear board between two parts. Below this they read as touching.

# Parts built as one assembly: they touch on purpose, so gaps inside a group are not measured.
ASSEMBLIES = (
    {'dropHousing', 'drop1', 'drop2', 'drop3'},
    {'captiveHousing', 'captiveTarget', 'captive'},
    {'scoopHood', 'scoop'},
    {'scoop2Hood', 'scoop2'},
    {'dropHousingL', 'drop4', 'drop5', 'drop6'},
    # The floors under the flippers meet the board's sides.
    {'outer', 'apronL'},
    {'shooterInner', 'apronR'},
    {'flipperL', 'inlaneL', 'plasticSlingL'},
    {'flipperR', 'inlaneR', 'plasticSlingR'},
    {'rampL', 'lampRampL'},
    {'rampR', 'lampRampR'},
    # The older tables' left ramps run close along the board's edge since the centre moved. Their layouts get redone.
    {'outer', 'rampL'},
    # The deck's ramp runs up its side and over its edge.
    {'deck', 'rampDeck', 'guideOrbitL'},
    # Corner flashers stand high over the cabinet's edge.
    {'outer', 'flashTL', 'flashTR'},
)
# The board's axis: the middle of the play area, between the left wall and the shooter lane.
AXIS = .461
MAX_UNMIRRORED = 2  # Points of difference between the two sides.
# Each part's twin on the other side of the axis.
MIRRORED = (('flipperL', 'flipperR'), ('inlaneL', 'inlaneR'), ('plasticSlingL', 'plasticSlingR'), ('lampOutlaneL', 'lampSpecial'),
            ('lampInlaneL', 'lampInlaneR'), ('outlaneLeft', 'outlaneRight'), ('inlaneLeft', 'inlaneRight'))
# Lanes a ball falls through, as the walls either side of each, and a height they are measured at.
MIRRORED_LANES = {'outlanes': ((('outer', 'inlaneL'), ('inlaneR', 'shooterInner')), .35)}
# Lines meant to be parallel, mirrored or not: a part's name and which of its segments.
MAX_ANGLE_OFF = .25  # Degrees.
MATCHED_ANGLES = {
    'slope': (('flipperL', 0), ('flipperR', 0), ('inlaneL', 0), ('inlaneR', 0), ('slingBackL', 1), ('slingBackR', 1),
              ('plasticSlingL', 1), ('plasticSlingR', 1), ('apronL', 0), ('apronR', 0)),
    'guide': (('orbitGateL', 0), ('orbitGateR', 0)),
}


def project(x, y, z=0.0):
    """Where a point at height z lands on the floor as the phone sees it: raised parts lean away from the centre."""
    visible = visible_height()
    distance = visible / (2 * math.tan(FOV / 2))
    cx, cy = VIEW['size'][0] / 2, visible / 2 - VIEW['padding'][1]
    k = distance / max(distance - z, .01)
    return cx + (x - cx) * k, cy + (y - cy) * k


class Part:
    """What a part covers on screen: rounded segments and, for a ramp, its mesh's triangles."""

    def __init__(self, name, kind):
        self.name, self.kind = name, kind
        self.capsules, self.triangles = [], []
        self.owns = None
        self.top = None  # How far up the board the part's footprint reaches, before the camera.

    def line(self, points, radius, z0=0.0, z1=None):
        """A rounded line, swept from its height z0 to z1: tall parts cover more of the screen."""
        reach = max(p[1] for p in points) + radius
        self.top = reach if self.top is None else max(self.top, reach)
        for z in (z0,) if z1 is None else (z0, z1):
            flat = [project(*p, z) for p in points]
            self.capsules += [(a, b, radius) for a, b in zip(flat, flat[1:] or flat)]
        if z1 is not None:
            self.capsules += [(project(*p, z0), project(*p, z1), radius) for p in points]
        return self

    def disc(self, x, y, radius, z0=0.0, z1=None):
        return self.line([(x, y)], radius, z0, z1)

    def bounds(self):
        xs = [v for a, b, r in self.capsules for v in (a[0] - r, b[0] - r, a[0] + r, b[0] + r)] + [p[0] for t in self.triangles for p in t]
        ys = [v for a, b, r in self.capsules for v in (a[1] - r, b[1] - r, a[1] + r, b[1] + r)] + [p[1] for t in self.triangles for p in t]
        return min(xs), min(ys), max(xs), max(ys)


def point_to_segment(p, a, b):
    dx, dy = b[0] - a[0], b[1] - a[1]
    length = dx * dx + dy * dy
    t = max(0, min(1, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / length)) if length else 0
    return math.hypot(p[0] - a[0] - t * dx, p[1] - a[1] - t * dy)


def segments_distance(a, b, c, d):
    def side(p, q, r):
        return (q[0] - p[0]) * (r[1] - p[1]) - (q[1] - p[1]) * (r[0] - p[0])
    if side(a, b, c) * side(a, b, d) < 0 and side(c, d, a) * side(c, d, b) < 0:
        return 0.0
    return min(point_to_segment(a, c, d), point_to_segment(b, c, d), point_to_segment(c, a, b), point_to_segment(d, a, b))


def inside_triangle(p, t):
    signs = [(t[(i + 1) % 3][0] - t[i][0]) * (p[1] - t[i][1]) - (t[(i + 1) % 3][1] - t[i][1]) * (p[0] - t[i][0]) for i in range(3)]
    return all(s >= 0 for s in signs) or all(s <= 0 for s in signs)


def capsule_to_triangles(capsule, triangles, limit):
    a, b, radius = capsule
    x0, x1 = min(a[0], b[0]) - radius - limit, max(a[0], b[0]) + radius + limit
    y0, y1 = min(a[1], b[1]) - radius - limit, max(a[1], b[1]) + radius + limit
    best = limit
    for t in triangles:
        if max(p[0] for p in t) < x0 or min(p[0] for p in t) > x1 or max(p[1] for p in t) < y0 or min(p[1] for p in t) > y1:
            continue
        if inside_triangle(a, t) or inside_triangle(b, t):
            return -radius
        best = min(best, *(segments_distance(a, b, t[i], t[(i + 1) % 3]) - radius for i in range(3)))
    return best


def gap(p, q, limit=.08):
    """Clear board between two parts, in table units. Below zero they overlap on screen."""
    px0, py0, px1, py1 = p.bounds()
    qx0, qy0, qx1, qy1 = q.bounds()
    if px0 - qx1 > limit or qx0 - px1 > limit or py0 - qy1 > limit or qy0 - py1 > limit:
        return limit
    best = limit
    for a, b, r in p.capsules:
        for c, d, s in q.capsules:
            best = min(best, segments_distance(a, b, c, d) - r - s)
    for capsule in p.capsules:
        best = min(best, capsule_to_triangles(capsule, q.triangles, best))
    for capsule in q.capsules:
        best = min(best, capsule_to_triangles(capsule, p.triangles, best))
    return best


def parts_of(table):
    """Every visible part, sized as PBTableScene places the kit's models."""
    set_view(table)
    parts = []

    def add(name, kind='part'):
        parts.append(Part(name, kind))
        return parts[-1]
    def upstairs(part):
        return 'deck' in part.get('layers', [])
    for wall in table['walls']:
        if upstairs(wall):
            continue
        points = compile_scenes.expand_points(wall['points'])
        if wall['style'] in ('wall', 'rail', 'rubber'):
            add(wall['id'], 'wall').line(points + points[:1] if wall.get('closed') else points, wall['radius'], 0, wall['height'])
        elif wall['style'] == 'plastic':
            add(wall['id']).line(points + points[:1], .0042, 0, wall['height'])
        elif wall['id'] == 'outer':
            add(wall['id'], 'wall').line(points, wall['radius'])
    for plastic in table['plastics']:
        # Rounded as the slingshot prefab rounds it: its corners reach less far than its outline's.
        points = mesher.filleted(mesher.ccw(compile_scenes.expand_points(plastic['points'])), .014, 8)
        add(plastic['id']).line(points + points[:1], .002, 0, .037)
    for flipper in table['flippers']:
        if upstairs(flipper):
            continue
        tip = (flipper['pivot'][0] + flipper['length'] * math.cos(math.radians(flipper['restAngle'])),
               flipper['pivot'][1] + flipper['length'] * math.sin(math.radians(flipper['restAngle'])))
        add(flipper['id']).line([tuple(flipper['pivot']), tip], (flipper['baseRadius'] + flipper['tipRadius']) * .5, 0, .03)
    for bumper in table['bumpers']:
        add(bumper['id']).disc(bumper['x'], bumper['y'], bumper['r'], bumper['r'] * .98, bumper['r'] * 1.15)
    for edge in table['standups']:
        if upstairs(edge):
            continue
        a, b = edge['a'], edge['b']
        radius = math.dist(a, b) * .5 + .003
        add(edge['id']).disc((a[0] + b[0]) * .5, (a[1] + b[1]) * .5, radius, 0, radius * .32)
    for edge in table['dropTargets']:
        add(edge['id']).line([tuple(edge['a']), tuple(edge['b'])], .008, 0, .03)
    for edge in table['spinners']:
        add(edge['id'], 'span').line([tuple(edge['a']), tuple(edge['b'])], .006, .062)
    for edge in table['gates']:
        add(edge['id'], 'span').line([tuple(edge['a']), tuple(edge['b'])], .004, .02)
    for rollover in table['rollovers']:
        if rollover.get('plate'):
            add(rollover['id']).line([(rollover['x'], rollover['y'] - .0162), (rollover['x'], rollover['y'] + .0162)], .0138)
    for saucer in table['saucers']:
        if upstairs(saucer):
            continue
        add(saucer['id']).disc(saucer['x'], saucer['y'], saucer['r'] * 1.12)
    for kick in table['kickbacks']:
        add(kick['id']).disc(kick['x'], kick['y'] - .035, .018, 0, .018)
    for ball in table['captiveBalls']:
        add(ball['id']).disc(ball['x'], ball['y'], table['physics']['ballRadius'], .03)
    for lamp in table['lamps']:
        if lamp.get('shape') == 'arrow':
            # A narrowed triangle, as the kit's arrowhead is: wide at the back, coming to a point.
            size, turn = lamp['size'], math.radians(lamp.get('angle', 0))
            along = (math.cos(turn) * size, math.sin(turn) * size)
            back = (lamp['x'] - along[0] * .1, lamp['y'] - along[1] * .1)
            add(lamp['id']).disc(*back, size * .556)
            parts[-1].line([back, (lamp['x'] + along[0] * .8, lamp['y'] + along[1] * .8)], size * .2)
        else:
            add(lamp['id']).disc(lamp['x'], lamp['y'], lamp['size'] * 1.1)
        parts[-1].owns = lamp.get('bar') or lamp.get('arrowFor')
    for flasher in table['flashers']:
        add(flasher['id']).disc(flasher['x'], flasher['y'], .034 * 1.05, .11, .15)
    offset = (table['size'][0] * .5, table['size'][1] * .5)
    centred = lambda x, y: (x - offset[0], y - offset[1])
    for ramp in table['ramps']:
        mesh = compile_scenes.ramp_part(table, ramp, centred)
        flat = [project(v[0] + offset[0], v[1] + offset[1], v[2]) for v in mesh.vertices]
        part = add(ramp['id'], 'ramp')
        for face in mesh.faces:
            part.triangles += [(flat[face[0]], flat[face[i]], flat[face[i + 1]]) for i in range(1, len(face) - 1)]
    return parts


def assembled(a, b):
    return a.owns == b.name or b.owns == a.name or any(a.name in group and b.name in group for group in ASSEMBLIES)


def measured(a, b):
    """A pair worth measuring. Walls meet each other and carry gates and spinners on purpose,
    and a ramp may cross a wall, as it floats above the board."""
    kinds = {a.kind, b.kind}
    return not (assembled(a, b) or kinds <= {'ramp'} or kinds <= {'span', 'wall'})


def problems(table, parts=None):
    parts = parts if parts is not None else parts_of(table)
    found = []
    for i, a in enumerate(parts):
        for b in parts[i + 1:]:
            if not measured(a, b):
                continue
            clear = gap(a, b) * POINTS
            if clear < MIN_GAP and not ({a.kind, b.kind} == {'wall', 'ramp'} and clear < 0):
                found.append((clear, a.name, b.name))
    found += unmirrored(table, parts)
    return sorted(found, key=lambda f: (f[0] is None, f[0] if f[0] is not None else 0))


def lane_width(table, left, right, y):
    """Clear floor between two walls at a height, on the table rather than through the camera."""
    walls = {wall['id']: wall for wall in table['walls']}

    def crossings(wall):
        points = compile_scenes.expand_points(wall['points'])
        if wall.get('closed'):
            points = points + points[:1]
        return [a[0] + (b[0] - a[0]) * (y - a[1]) / (b[1] - a[1]) for a, b in zip(points, points[1:]) if a[1] != b[1] and min(a[1], b[1]) <= y <= max(a[1], b[1])]
    # A wall may cross the height twice, as the board's outer wall does: use its nearer side.
    inner, outer = crossings(walls[right]), crossings(walls[left])
    return min(b - a for a in outer for b in inner if b > a) - walls[right]['radius'] - walls[left]['radius']


def line_angle(table, name, segment):
    """A line's angle from level, from 0 to 90, so that a line and its mirror image read the same."""
    for flipper in table['flippers']:
        if flipper['id'] == name:
            turn = flipper['restAngle']
            return min(turn % 180, 180 - turn % 180)
    edges = {e['id']: [e['a'], e['b']] for e in table['gates']}
    edges.update({part['id']: compile_scenes.expand_points(part['points']) for part in table['walls'] + table['plastics'] if 'points' in part})
    if name not in edges:
        return None
    a, b = edges[name][segment], edges[name][segment + 1]
    turn = math.degrees(math.atan2(b[1] - a[1], b[0] - a[0])) % 180
    return min(turn, 180 - turn)


def unmatched_angles(table):
    found = []
    for name, lines in MATCHED_ANGLES.items():
        angles = {f'{part}[{segment}]': line_angle(table, part, segment) for part, segment in lines}
        angles = {line: angle for line, angle in angles.items() if angle is not None}
        if angles and max(angles.values()) - min(angles.values()) > MAX_ANGLE_OFF:
            found.append((None, f'{name} angles', ', '.join(f'{line} {angle:.1f}' for line, angle in angles.items())))
    return found


def unmirrored(table, parts):
    found = unmatched_angles(table)
    named = {p.name: p for p in parts}
    for a, b in MIRRORED:
        if a in named and b in named:
            left, right = named[a].bounds(), named[b].bounds()
            off = max(abs(left[0] + right[2] - 2 * AXIS), abs(left[2] + right[0] - 2 * AXIS), abs(left[1] - right[1]), abs(left[3] - right[3]))
            if off * POINTS > MAX_UNMIRRORED:
                found.append((None, f'{a} / {b}', f'not mirrored around x = {AXIS}: {off * POINTS:.1f} pt out'))
    for name, ((left, right), y) in MIRRORED_LANES.items():
        widths = [lane_width(table, *walls, y) for walls in (left, right)]
        if abs(widths[0] - widths[1]) * POINTS > MAX_UNMIRRORED:
            found.append((None, name, f'{widths[0] * POINTS:.0f} pt wide on the left, {widths[1] * POINTS:.0f} pt on the right'))
    return found


def write_svg(table, parts, found, path):
    """The measured shapes, with offenders in red, to compare against a screenshot."""
    set_view(table)
    scale, height = 600, visible_height() * 600
    named = {n for f in found if f[0] is not None for n in f[1:]}
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {scale} {height:.0f}"><rect width="100%" height="100%" fill="#111"/>']
    for part in parts:
        colour = '#f44' if part.name in named else '#8cf' if part.kind != 'ramp' else '#667'
        for t in part.triangles:
            points = ' '.join(f'{p[0] * scale:.1f},{height - p[1] * scale:.1f}' for p in t)
            out.append(f'<polygon points="{points}" fill="{colour}"/>')
        for a, b, r in part.capsules:
            out.append(f'<line x1="{a[0] * scale:.1f}" y1="{height - a[1] * scale:.1f}" x2="{b[0] * scale:.1f}" y2="{height - b[1] * scale:.1f}" stroke="{colour}" stroke-opacity=".7" stroke-linecap="round" stroke-width="{2 * r * scale:.1f}"/>')
    path.write_text('\n'.join(out) + '</svg>\n')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--list', type=int, default=0, metavar='N', help='Also print the N tightest pairs that pass')
    parser.add_argument('--svg', type=Path, help='Write what was measured to DIR/<table>.svg')
    args = parser.parse_args()
    failed = False
    for path in table_xml.table_paths():
        table = compile_scenes.table_json(table_xml.read(path))
        parts = parts_of(table)
        found = problems(table, parts)
        failed = failed or bool(found)
        print(f"{table['id']}: {len(found)} problem(s) across {len(parts)} parts (minimum gap {MIN_GAP} pt)")
        for clear, a, b in found:
            print(f'  {a}: {b}' if clear is None else f'  {clear:6.1f} pt  {a} / {b}' + ('  (overlap)' if clear < 0 else ''))
        if args.list:
            pairs = [(gap(a, b) * POINTS, a.name, b.name) for i, a in enumerate(parts) for b in parts[i + 1:] if measured(a, b)]
            for clear, a, b in sorted(p for p in pairs if p[0] >= MIN_GAP)[:args.list]:
                print(f'  ok {clear:6.1f} pt  {a} / {b}')
        if args.svg:
            args.svg.mkdir(parents=True, exist_ok=True)
            write_svg(table, parts, found, args.svg / f"{table['id']}.svg")
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
