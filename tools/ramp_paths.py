#!/usr/bin/env python3
"""The path a ramp's mesh is lofted along, and checks that it is smooth.

Plain Python, shared by tools/scene/compile_scenes.py and this checker:

    python3 tools/ramp_paths.py

Exits 1 if any ramp in GameData/Tables has a kink or fold in its centre line or rail edges, or
strays too far from the path the ball follows. The mesh build runs the same checks and refuses
to build a ramp that fails.
"""
import json
import math
import sys
from pathlib import Path

SPACING = .007          # Between rings of the loft, in table widths.
RELAX_PASSES = 350     # Smoothing, on points about .01 apart.
RAIL_WIDTH = .008         # From the channel wall to the rail's outer edge.
MAX_TURN = 7.0          # Degrees between neighbouring edge segments: above this, facets show.
MAX_TURN_JUMP = 1.2     # Change of that turn between neighbours: above this, it reads as a kink.
MAX_DRIFT = .012        # From the ball's path. About half a ball's radius.


def catmull_rom(points, subdivisions):
    """The table's spline. PBTableDefinition samples the ball's path with six subdivisions."""
    at = lambda i: points[max(0, min(i, len(points) - 1))]
    out = []
    for i in range(len(points) - 1):
        p0, p1, p2, p3 = at(i - 1), at(i), at(i + 1), at(i + 2)
        for step in range(subdivisions):
            t = step / subdivisions
            out.append(tuple(.5 * (2 * b + (c - a) * t + (2 * a - 5 * b + 4 * c - d) * t * t + (3 * b - a - 3 * c + d) * t * t * t)
                             for a, b, c, d in zip(p0, p1, p2, p3)))
    out.append(tuple(points[-1]))
    return out


def ramp_path(ramp):
    return [tuple(p) for p in ramp['points']] if ramp.get('authoring',{}).get('path_sampled') else loft_path(ramp['points'])


def loft_path(points, spacing=SPACING):
    """The spline, relaxed and resampled to even steps, so a loft along it bends without kinks."""
    dense = catmull_rom(points, 24)
    for _ in range(RELAX_PASSES):
        dense = [dense[0]] + [tuple(b * .5 + (a + c) * .25 for a, b, c in zip(dense[i - 1], dense[i], dense[i + 1]))
                              for i in range(1, len(dense) - 1)] + [dense[-1]]
    lengths = [math.dist(a[:2], b[:2]) for a, b in zip(dense, dense[1:])]
    total = sum(lengths)
    count = max(2, round(total / spacing))
    out, index, walked = [], 0, 0.0
    for k in range(count + 1):
        target = total * k / count
        while index < len(lengths) - 1 and walked + lengths[index] < target:
            walked += lengths[index]
            index += 1
        t = min((target - walked) / max(lengths[index], 1e-9), 1.0)
        out.append(tuple(a + (b - a) * t for a, b in zip(dense[index], dense[index + 1])))
    return out


def tangents(path):
    out = []
    for i in range(len(path)):
        a, b = path[max(i - 1, 0)], path[min(i + 1, len(path) - 1)]
        d = math.hypot(b[0] - a[0], b[1] - a[1]) or 1.0
        out.append(((b[0] - a[0]) / d, (b[1] - a[1]) / d))
    return out


def mesh_path(ramp):
    """Keep dense bend rings; merge nearly straight spans within 0.12 mm at both rail edges.

    Return original tangents with the selected stations so loft cross sections stay perpendicular
    to the reference spline even where straight spans use fewer rings.
    """
    path = ramp_path(ramp)
    directions = tangents(path)
    reach = ramp['width'] * .5 + RAIL_WIDTH
    strips = [[(p[0] - t[1] * d, p[1] + t[0] * d, p[2])
               for p, t in zip(path, directions)] for d in (-reach, 0, reach)]

    def distance(p, a, b):
        delta = [y - x for x, y in zip(a, b)]
        u = max(0, min(1, sum((x - y) * d for x, y, d in zip(p, a, delta)) /
                       max(sum(d * d for d in delta), 1e-12)))
        return math.dist(p, [x + u * d for x, d in zip(a, delta)])

    kept = [0]
    while kept[-1] < len(path) - 1:
        first = kept[-1]
        last = first + 1
        for candidate in range(first + 2, len(path)):
            dot = sum(a * b for a, b in zip(directions[first], directions[candidate]))
            if math.dist(path[first], path[candidate]) > .028 or dot < math.cos(math.radians(3)):
                break
            error = max(distance(strip[i], strip[first], strip[candidate])
                        for strip in strips for i in range(first + 1, candidate))
            if error > .00012:
                break
            last = candidate
        kept.append(last)
    return [path[i] for i in kept], [directions[i] for i in kept]


def edge(path, offset):
    return [(p[0] - t[1] * offset, p[1] + t[0] * offset) for p, t in zip(path, tangents(path))]


def turns(polyline):
    out = []
    for a, b, c in zip(polyline, polyline[1:], polyline[2:]):
        cross = (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0])
        dot = (b[0] - a[0]) * (c[0] - b[0]) + (b[1] - a[1]) * (c[1] - b[1])
        out.append(math.degrees(math.atan2(cross, dot)))
    return out


def distance_to_polyline(point, polyline):
    best = float('inf')
    for a, b in zip(polyline, polyline[1:]):
        dx, dy = b[0] - a[0], b[1] - a[1]
        t = max(0.0, min(1.0, ((point[0] - a[0]) * dx + (point[1] - a[1]) * dy) / max(dx * dx + dy * dy, 1e-12)))
        best = min(best, math.hypot(point[0] - a[0] - dx * t, point[1] - a[1] - dy * t))
    return best


def measure(ramp):
    """Worst values for one ramp, and what they break."""
    path = ramp_path(ramp)
    reach = ramp['width'] * .5 + RAIL_WIDTH
    ball_path = catmull_rom([tuple(p) for p in ramp['points']], 6)
    result = {'rings': len(path), 'turn': 0.0, 'jump': 0.0, 'fold': False,
              'drift': max(distance_to_polyline(p, ball_path) for p in path)}
    for offset in (-reach, -ramp['width'] * .5, 0, ramp['width'] * .5, reach):
        polyline = edge(path, offset) if offset else [p[:2] for p in path]
        bends = turns(polyline)
        result['turn'] = max(result['turn'], max(abs(b) for b in bends))
        result['jump'] = max(result['jump'], max(abs(a - b) for a, b in zip(bends, bends[1:])))
        centre = tangents(path)
        for i, (a, b) in enumerate(zip(polyline, polyline[1:])):
            if (b[0] - a[0]) * centre[i][0] + (b[1] - a[1]) * centre[i][1] <= 0:
                result['fold'] = True
    return result


def problems(ramp):
    m = measure(ramp)
    found = []
    if m['fold']:
        found.append('an edge folds back on itself: the bend is tighter than the channel is wide')
    if m['turn'] > MAX_TURN:
        found.append(f"edge facets turn {m['turn']:.1f} degrees, over {MAX_TURN}")
    if m['jump'] > MAX_TURN_JUMP:
        found.append(f"curvature jumps {m['jump']:.2f} degrees between segments, over {MAX_TURN_JUMP}")
    if m['drift'] > MAX_DRIFT:
        found.append(f"mesh strays {m['drift']:.4f} from the ball's path, over {MAX_DRIFT}")
    return found


def main():
    root = Path(__file__).resolve().parents[1]
    failed = False
    for file in sorted((root / 'GameData/Tables').glob('*.json')):
        table = json.loads(file.read_text())
        for ramp in table['ramps']:
            m = measure(ramp)
            mesh, _ = mesh_path(ramp)
            found = problems(ramp)
            failed = failed or bool(found)
            print(f"{table['id']}/{ramp['id']}: {'FAIL' if found else 'ok'}  rings {m['rings']} → {len(mesh)} mesh  turn {m['turn']:.2f}  "
                  f"jump {m['jump']:.3f}  drift {m['drift']:.4f}")
            for problem in found:
                print(f'  {problem}')
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
