"""Ramp channels, walls and their supports as plain mesh data, in pure Python. Used by compile_scenes.py."""
from dataclasses import dataclass, asdict
import math
import sys
from pathlib import Path

from vector import Vector

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ramp_paths as pathing  # noqa: E402


FLOOR_SHEEN = .55  # How far the floor's normals lean along the grain.
FLOOR_DISH = .12
LAMP_FOOTPRINT = 1.12  # PBLampFootprintScale in the layout validator.


@dataclass
class TrackSpec:
    width: float = .088
    wall_height: float = .05
    rail_width: float = .008
    corner_radius: float = .0035
    floor_thickness: float = .002
    entrance: str = 'OPEN'
    exit: str = 'OPEN'
    end_hardware: bool = True
    entrance_funnel: bool = True
    funnel_length: float = .12
    funnel_width: float = .155
    funnel_turn: float = 0
    funnel_skew: float = 0
    end_length: float = .055
    flare: float = 1.18
    trim_start: float = 0
    trim_end: float = 0
    loop_gap: float = .12
    support_spacing: float = .2
    support_radius: float = .0065
    foot_radius: float = .0125
    clamp_length: float = .026
    base_height: float = 0
    supports: bool = False
    arrow_mode: str = 'ENDS'
    arrow_offset: float = .075
    arrow_spacing: float = .08
    arrow_width: float = .03
    arrow_length: float = .036
    exit_arrow_reverse: bool = False
    entrance_lamp: bool = True
    entrance_lamp_offset: float = .065
    entrance_lamp_size: float = .0354
    max_segment: float = .028
    tolerance: float = .0002
    triangle_budget: int = 6000

    @classmethod
    def from_dict(cls, data):
        return cls(**{k: v for k, v in data.items() if k in cls.__dataclass_fields__})

    def to_dict(self):
        return asdict(self)


class MeshData:
    def __init__(self):
        self.vertices, self.faces, self.roles, self.uvs, self.sharp = [], [], [], [], []
        self.metadata = {}
        self.normals = {}  # Vertex index to authored normal: the brushed floor's sheen.

    def add(self, vertices, faces, role, uv=None, sharp=40):
        used = sorted({i for face in faces for i in face})
        start = len(self.vertices)
        remap = {v: start+i for i,v in enumerate(used)}
        self.vertices.extend(tuple(vertices[i]) for i in used)
        self.uvs.extend(uv[i] if uv else (0,0) for i in used)
        self.faces.extend(tuple(remap[i] for i in face) for face in faces)
        self.roles.extend(role if isinstance(role,list) else [role]*len(faces))
        self.sharp.extend([sharp]*len(faces))

    @property
    def triangles(self):
        return sum(len(f) - 2 for f in self.faces)

    def lathe(self, xy, profile, role, segments=12):
        vertices = [(xy[0] + r * math.cos(i * math.tau / segments), xy[1] + r * math.sin(i * math.tau / segments), z)
                    for r, z in profile for i in range(segments)]
        faces = [(row * segments + i, row * segments + (i + 1) % segments,
                  (row + 1) * segments + (i + 1) % segments, (row + 1) * segments + i)
                 for row in range(len(profile) - 1) for i in range(segments)]
        self.add(vertices, faces, role, sharp=65)

    def bar(self, a, b, radius, role, sides=8):
        """A round bar with flat ends between two points, its section upright."""
        a, b = Vector(a), Vector(b)
        side = Vector((a.y - b.y, b.x - a.x, 0)).normalized()
        up = side.cross(b - a).normalized()
        ring = [side * math.cos(i * math.tau / sides) * radius + up * math.sin(i * math.tau / sides) * radius for i in range(sides)]
        vertices = [tuple(a + r) for r in ring] + [tuple(b + r) for r in ring]
        faces = [(i, (i + 1) % sides, (i + 1) % sides + sides, i + sides) for i in range(sides)]
        faces += [tuple(reversed(range(sides))), tuple(range(sides, sides * 2))]
        self.add(vertices, faces, role, sharp=65)

    def block(self, corners, z0, z1, role, bevel=.0012):
        """A chamfered block over four counter-clockwise (x, y, z offset) corners."""
        middle = sum((Vector(c[:2]) for c in corners), Vector((0, 0))) / 4
        inset = [middle + (Vector(c[:2]) - middle) * (1 - bevel / max((Vector(c[:2]) - middle).length, 1e-6)) for c in corners]
        vertices = [(c[0], c[1], z0 + c[2]) for c in corners] + [(c[0], c[1], z1 + c[2] - bevel) for c in corners]
        vertices += [(q.x, q.y, z1 + c[2]) for q, c in zip(inset, corners)]
        faces = [(k * 4 + i, k * 4 + (i + 1) % 4, (k + 1) * 4 + (i + 1) % 4, (k + 1) * 4 + i) for k in range(2) for i in range(4)]
        self.add(vertices, faces + [(8, 9, 10, 11)], role, sharp=30)


def arc_lengths(path):
    out = [0.0]
    for a, b in zip(path, path[1:]):
        out.append(out[-1] + (Vector(b) - Vector(a)).length)
    return out


def sample(path, lengths, distance):
    distance = max(0.0, min(distance, lengths[-1]))
    i = next((i for i in range(len(path) - 1) if lengths[i + 1] >= distance - 1e-9), len(path) - 2)
    t = (distance - lengths[i]) / max(lengths[i + 1] - lengths[i], 1e-9)
    p = Vector(path[i]).lerp(Vector(path[i + 1]), t)
    before, after = Vector(path[max(0, i - 1)]), Vector(path[min(len(path) - 1, i + 2)])
    tangent = (after - before).xy.normalized()
    return p, tangent, Vector((-tangent.y, tangent.x))


def trimmed(path, start, end):
    lengths = arc_lengths(path)
    if start + end >= lengths[-1] - .02:
        raise ValueError('Entrance/exit cuts consume the whole track')
    last = lengths[-1] - end
    return [sample(path, lengths, start)[0]] + [Vector(p) for p, d in zip(path, lengths) if start < d < last] + [sample(path, lengths, last)[0]]


def rail_geometry(spec):
    """Inner wall, tube centre and tube radius, as distances from the centre line and the floor."""
    radius = spec.rail_width / 1.7
    wall = spec.width * .5 + .001
    return wall, wall + radius * .62, spec.wall_height - radius, radius


def rail_reach(spec):
    wall, centre, _, radius = rail_geometry(spec)
    return centre + radius


def funnel_rings(path, spec, count=12):
    """The ramp's walls carried on past its mouth, opening in a smooth curve, tip first.

    Each is a point, travel direction, how far each wall has moved out, and wall height scale.
    The funnel may turn to face where the ball comes from, and skew to open more on one side,
    when something stands close on the other.
    """
    lengths = arc_lengths(path)
    start = Vector(path[0]).xy
    axis = (sample(path, lengths, .03)[0].xy - start).normalized()
    base = math.atan2(axis.y, axis.x)
    rings, p = [], start.copy()
    opening = max(0, spec.funnel_width * .5 - spec.width * .5)
    step = spec.funnel_length / count
    for k in range(1, count + 1):
        a = base + math.radians(spec.funnel_turn) * (k - .5) / count
        p = p - Vector((math.cos(a), math.sin(a))) * step
        u = k / count
        tip = max(0, (u - .6) / .4)
        rings.append((p.copy(), Vector((math.cos(a), math.sin(a))), opening * u * u, 1 - .5 * tip * tip * (3 - 2 * tip)))
    return rings[::-1]


def funnel_walls(path, spec):
    """Colliders down the middle of the funnel's walls, tip to mouth, one list per side."""
    wall, centre, _, radius = rail_geometry(spec)
    middle = (wall + centre + radius) * .5
    rings = funnel_rings(path, spec)
    lengths = arc_lengths(path)
    mouth, axis, normal = sample(path, lengths, 0)
    out = []
    for side in (1, -1):
        line = [p + Vector((-t.y, t.x)) * side * (middle + extra * (1 + side * spec.funnel_skew)) for p, t, extra, _ in rings]
        out.append(line + [mouth.xy + normal * side * middle])
    return out


def section(spec):
    """One side, from the foot of the outer wall, over a round rail, down to the floor's edge."""
    wall, centre, height, radius = rail_geometry(spec)
    r = spec.corner_radius
    tube = [(-centre + radius * math.cos(math.radians(a)), height + radius * math.sin(math.radians(a)))
            for a in (232, 180, 135, 90, 45, 0, -52)]
    side = [(-centre - radius * .62, -spec.floor_thickness)] + tube + [(-wall, r), (-wall + r * .293, r * .293), (-wall + r, 0)]
    profile = side + [(-x, z) for x, z in side[::-1]]
    profile.append(profile[0])
    side_roles = ['channel_shell'] + ['accent'] * 6 + ['channel_liner'] * 3
    return profile, side_roles + ['channel_floor'] + side_roles[::-1] + ['channel_shell']


def simplify(path, spec):
    """Decimate only where both retaining walls remain subpixel-close to the input curve."""
    dirs = pathing.tangents(path)
    reach = rail_reach(spec)
    strips = [[Vector((p[0] - t[1] * d, p[1] + t[0] * d, p[2])) for p, t in zip(path, dirs)] for d in (-reach, 0, reach)]
    def deviation(p, a, b):
        v = b - a
        return (p - a - v * max(0, min(1, (p - a).dot(v) / max(v.length_squared, 1e-12)))).length
    kept = [0]
    while kept[-1] < len(path) - 1:
        first, last = kept[-1], kept[-1] + 1
        for candidate in range(first + 2, len(path)):
            if (Vector(path[first]) - Vector(path[candidate])).length > spec.max_segment:
                break
            if sum(a*b for a,b in zip(dirs[first], dirs[candidate])) < math.cos(math.radians(3)):
                break
            if max(deviation(s[i], s[first], s[candidate]) for s in strips for i in range(first+1, candidate)) > spec.tolerance:
                break
            last = candidate
        kept.append(last)
    return [Vector(path[i]) for i in kept], [Vector(dirs[i]) for i in kept]


def build_track(input_path, spec, support_filter=None):
    numeric=[v for v in spec.to_dict().values() if isinstance(v,(int,float))]
    if not all(math.isfinite(v) for v in numeric):raise ValueError('Track settings must be finite')
    if min(spec.rail_width,spec.corner_radius,spec.floor_thickness,spec.max_segment,spec.tolerance,spec.arrow_spacing,spec.support_spacing)<=0:
        raise ValueError('Profile dimensions, mesh tolerance and spacing must be positive')
    if spec.arrow_width > spec.width-spec.corner_radius*2:raise ValueError('Arrow width exceeds the flat channel floor')
    if min(spec.arrow_width,spec.arrow_length)<=0:raise ValueError('Arrow dimensions must be positive')
    if spec.supports and (spec.support_radius<=0 or spec.foot_radius<spec.support_radius):raise ValueError('Columns need a positive shaft radius and a foot at least as wide')
    if spec.corner_radius>=spec.wall_height-spec.rail_width*1.1:raise ValueError('Floor corner radius must fit below the rail')
    if min(spec.trim_start,spec.trim_end)<0:raise ValueError('Opening cuts must be positive')
    if spec.width <= spec.corner_radius * 4 or spec.wall_height <= spec.rail_width:
        raise ValueError('Channel width/height is too small for its rounded section')
    path = trimmed(input_path, spec.trim_start, spec.trim_end)
    # A retaining wall must never fold through itself on the inside of a tight bend.
    directions=pathing.tangents(path);reach=rail_reach(spec)
    for side in (-reach,reach):
        edge=[Vector((p[0]-t[1]*side,p[1]+t[0]*side,p[2])) for p,t in zip(path,directions)]
        if any((b-a).xy.dot(Vector(t))<=0 for a,b,t in zip(edge,edge[1:],directions)):
            raise ValueError('Curve bend is too tight for this channel width; widen the bend or reduce the width')
    lengths = arc_lengths(path)
    if spec.arrow_mode!='NONE' and lengths[-1]<spec.arrow_length*2.2:raise ValueError('Track is too short for these arrow dimensions')
    if spec.arrow_mode=='REPEAT' and spec.arrow_spacing<spec.arrow_length*1.15:raise ValueError('Repeated arrow spacing is too short for the arrow length')
    profile, bands = section(spec)
    rings, tangents = simplify(path, spec)
    ring_lengths = arc_lengths(rings)
    data, vertices, uv = MeshData(), [], []
    wall, rail_centre, rail_height, rail_radius = rail_geometry(spec)
    floor_edge = wall - spec.corner_radius
    floor, floor_uv, floor_normals = [], [], []
    funnel = funnel_rings(path, spec) if spec.entrance_funnel else []
    funnel_distance = [-(len(funnel) - i) * spec.funnel_length / max(len(funnel), 1) for i in range(len(funnel))]
    stations = [(p.to_3d(), t, d, extra, height) for (p, t, extra, height), d in zip(funnel, funnel_distance)]
    stations += [(p, t, d, 0.0, 1.0) for p, t, d in zip(rings, tangents, ring_lengths)]
    for p, t, distance, extra, funnel_height in stations:
        n = Vector((-t.y, t.x))
        scale, height_scale = 1.0, funnel_height
        for mode, d in ((spec.entrance, distance), (spec.exit, ring_lengths[-1] - distance)):
            blend = max(0, 1 - d / max(spec.end_length, .001)) if d >= 0 else 0
            blend = blend * blend * (3 - 2 * blend)
            if mode == 'FLARED': scale += (spec.flare - 1) * blend
            if mode == 'RUNOUT': height_scale *= 1 - .8 * blend
        # Just clear of the playfield, which would otherwise fight with a floor at height zero.
        z0 = max(p.z, .0016)
        for x, z in profile:
            x = x * scale + math.copysign(extra * (1 + math.copysign(spec.funnel_skew, x)), x)
            vertices.append((p.x + n.x*x, p.y+n.y*x, z0 + (z*height_scale if z > 0 else z)))
            uv.append((0, 0))
        # Brushed metal catches light by the direction of its grain, so the floor's sheen follows
        # the heading around a bend. The normals lean with it, and dish slightly toward the middle.
        for across in (-1, 0, 1):
            x = (floor_edge * scale + extra * (1 + across * spec.funnel_skew)) * across
            floor.append((p.x + n.x * x, p.y + n.y * x, z0))
            floor_uv.append((distance / .35, across * .5 + .5))
            floor_normals.append(Vector((t.x * FLOOR_SHEEN - n.x * across * FLOOR_DISH, t.y * FLOOR_SHEEN - n.y * across * FLOOR_DISH, 1)).normalized())
    m = len(profile)
    total = len(stations)
    faces, roles = [], []
    for i in range(total-1):
        for j,role in enumerate(bands):
            if role == 'channel_floor':
                continue
            faces.append((i*m+j,(i+1)*m+j,(i+1)*m+j+1,i*m+j+1))
            roles.append(role)
    data.add(vertices,faces,roles,uv,35)
    n = m - 1
    cut = vertices[:n] + vertices[(total-1)*m:(total-1)*m+n]
    data.add(cut, [tuple(range(n)), tuple(reversed(range(n,n*2)))], 'accent')
    # The entrance's floor is its own colour, leading onto the aluminum.
    first_ramp_ring = len(funnel)
    start = len(data.vertices)
    floor_faces = [(i*3+j,(i+1)*3+j,(i+1)*3+j+1,i*3+j+1) for i in range(total-1) for j in range(2)]
    floor_roles = ['channel_entry' if i < first_ramp_ring else 'channel_floor' for i in range(total-1) for j in range(2)]
    data.add(floor, floor_faces, floor_roles, floor_uv, 90)
    data.normals.update((start + i, tuple(v)) for i, v in enumerate(floor_normals))

    reach = rail_reach(spec)
    def clamp_and_column(distance, side, column):
        """A bracket over the rail, reaching out to a column that stands clear of the channel."""
        p, t, normal = sample(path, lengths, distance)
        half = spec.clamp_length * .5
        z = lambda along: sample(path, lengths, distance + along)[0].z
        outside = reach + spec.support_radius + .0005
        low, high = rail_centre, (outside + spec.support_radius + .001) if column else reach + .0015
        centre = p.xy + normal * side * outside
        corners = [(low, -half), (high, -half), (high, half), (low, half)]
        outline = [(*(p.xy + normal * side * a + t * b), z(b) - p.z) for a, b in (corners if side > 0 else corners[::-1])]
        top = p.z + spec.wall_height + .0025
        data.block(outline, p.z + rail_height - rail_radius * .9, top, 'accent')
        bolt = centre if column else p.xy + normal * side * (low + high) * .5
        data.lathe(bolt, [(spec.support_radius * .85, top - .001), (spec.support_radius * .62, top + .0025), (.0001, top + .004)], 'metal', 8)
        if not column:
            return None
        base = spec.base_height
        data.lathe(centre, [(spec.foot_radius, base), (spec.foot_radius, base + .003), (spec.support_radius * 1.25, base + .0055)], 'accent', 10)
        data.lathe(centre, [(spec.support_radius, base + .004), (spec.support_radius, p.z + rail_height - rail_radius * .8)], 'accent', 8)
        return (centre.x, centre.y, p.z)

    def column_fits(xy, radius, tight=False):
        # Never stand a column under the channel, or inside a bend too tight for it.
        keep = reach + spec.support_radius
        if any((Vector(q[:2]) - xy).length < keep for q in path):
            return False
        return not support_filter or support_filter(xy, radius, tight)

    def place(side, spots, tight=False):
        """The first spot where a column fits; otherwise only the bracket, at the first spot."""
        for spot in spots:
            p, t, normal = sample(path, lengths, spot)
            if p.z <= spec.base_height + .012:
                break
            xy = p.xy + normal * side * outside
            if column_fits(xy, spec.support_radius if tight else spec.foot_radius, tight):
                return clamp_and_column(spot, side, True)
        if sample(path, lengths, spots[0])[0].z > spec.base_height + .012:
            clamp_and_column(spots[0], side, False)
        return None

    # All posts and feet go into this same mesh, never separate scene objects.
    supports = []
    outside = reach + spec.support_radius + .0005
    if spec.supports:
        ends = spec.clamp_length * .5 + .002
        stations = max(1, math.ceil((lengths[-1] - ends * 2) / spec.support_spacing))
        for k in range(stations + 1):
            d = ends + (lengths[-1] - ends * 2) * k / stations
            if 0 < k < stations:
                # One side per station, alternating, so brackets do not read as a ladder.
                supports.append(place(1 if k % 2 else -1, [d + offset * .012 for offset in (0, 1, -1, 2, -2, 3, -3)]))
            else:
                # The ends need both legs. A leg there counts only its shaft and a ball's width,
                # and may look a little way along the rail for a place.
                inward = 1 if k == 0 else -1
                for side in (-1, 1):
                    supports.append(place(side, [d + inward * step * .006 for step in range(12)], tight=True))
        supports = [column for column in supports if column]

    if spec.end_hardware:
        if not spec.entrance_funnel:
            # The entrance: a broad threshold plate lying on the playfield, leading onto the floor.
            p, t, normal = sample(path, lengths, 0)
            plate = [(-reach, -.016), (reach, -.016), (reach, .006), (-reach, .006)]
            data.block([(*(p.xy + normal * -a + t * b), 0) for a, b in plate], p.z - .0005, p.z + .003, 'accent', .001)
        # The exit: the floor ends over a thick crossbar, between the rails and their two legs.
        p, t, normal = sample(path, lengths, lengths[-1])
        lip = Vector((p.x, p.y, p.z)) - Vector((t.x, t.y, 0)) * .002
        drop = spec.floor_thickness + rail_radius * .55
        side = Vector((normal.x, normal.y, 0)) * reach
        data.bar(lip + side - Vector((0, 0, drop)), lip - side - Vector((0, 0, drop)), rail_radius * .95, 'accent', 8)

    arrows = []
    offsets = []
    offset = min(max(spec.arrow_offset,spec.arrow_length*2/3+.002), lengths[-1]*.45)
    if spec.arrow_mode in ('ENDS','ENTRY'): offsets.append((offset,1))
    if spec.arrow_mode in ('ENDS','EXIT'): offsets.append((lengths[-1]-offset,-1 if spec.exit_arrow_reverse else 1))
    if spec.arrow_mode == 'REPEAT':
        count = max(1, round(lengths[-1]/spec.arrow_spacing))
        offsets = [((i+.5)*lengths[-1]/count,1) for i in range(count)]
    for distance, direction in offsets:
        p, tangent, normal = sample(path, lengths, distance)
        # Geometric centroid is precisely on the path; orient using the local tangent.
        corners = [(spec.arrow_length*2/3,0),(-spec.arrow_length/3,spec.arrow_width*.5),(-spec.arrow_length/3,-spec.arrow_width*.5)]
        if direction < 0: corners = corners[::-1]
        tri = []
        for along, across in corners:
            q = p.xy + tangent * along * direction + normal * across
            # Interpolate floor height along the same arc to seat the inset on slopes.
            z = sample(path,lengths,distance+along*direction)[0].z + .0008
            tri.append((q.x,q.y,z))
        data.add(tri,[(0,1,2)],'channel_arrow',[(.5,1),(0,0),(1,0)])
        outer = [(p.x+(v[0]-p.x)*1.4,p.y+(v[1]-p.y)*1.4,v[2]-.0004) for v in tri]
        data.add(outer+tri,[(i,(i+1)%3,(i+1)%3+3,i+3) for i in range(3)],'accent')
        arrows.append({'distance':distance,'centre':tuple(p),'direction':direction})
    data.metadata.update(arrow_count=len(arrows),arrow_spacing=spec.arrow_spacing,arrows=arrows,support_count=len(supports),support_centres=supports,
                         section='Brushed aluminum channel with round gold rails',profile=spec.to_dict())
    if data.triangles > spec.triangle_budget:
        raise ValueError(f'Track needs {data.triangles} triangles; budget is {spec.triangle_budget}. Increase mesh tolerance or reduce supports.')
    return data


def entrance_lamp(path, spec, table=None):
    """The playfield arrow that shows a ramp's shot, ahead of its entrance and pointing into it.

    It starts in line with the entrance, and swings out to the nearest place clear of other parts.
    """
    if spec.entrance_funnel:
        rings = funnel_rings(path, spec)
        start, axis = rings[0][0], rings[0][1]
    else:
        lengths = arc_lengths(path)
        start = Vector(path[0]).xy
        axis = (sample(path, lengths, .03)[0].xy - start).normalized()
    obstacles = []
    if table:
        for wall in table.get('walls', []):
            points = []
            for p in wall['points']:
                if isinstance(p, dict):
                    cx, cy, r, a0, a1, count = p['arc']
                    points.extend((cx + r * math.cos(math.radians(a0 + (a1 - a0) * i / count)), cy + r * math.sin(math.radians(a0 + (a1 - a0) * i / count))) for i in range(count + 1))
                else:
                    points.append(p)
            if wall.get('closed'):
                points.append(points[0])
            obstacles.append((points, wall.get('radius', .003)))
        obstacles.extend(([(q['x'], q['y']), (q['x'], q['y'])], q['r']) for q in table.get('posts', []))
        obstacles.extend(([(q['x'], q['y']), (q['x'], q['y'])], q.get('r', q.get('size', .03))) for key in ('bumpers', 'rollovers', 'saucers') for q in table.get(key, []))
        obstacles.extend(([(q['x'], q['y']), (q['x'], q['y'])], q['size']) for q in table.get('lamps', []) if 'ramp' not in q)
        obstacles = [(points, radius) for points, radius in obstacles if len(points) > 1]
    keep = spec.entrance_lamp_size * LAMP_FOOTPRINT + .005
    def clear(xy):
        return all(pathing.distance_to_polyline(xy, points) >= keep + radius for points, radius in obstacles)
    # A funnel widens away from the mouth, so look further out if it is too narrow here.
    for extra in (0, .012, .024, .036, .048, .06, .072):
        for swing in range(0, 61, 3):
            for sign in ((1, -1) if swing else (1,)):
                a = math.radians(swing * sign)
                ahead = Vector((-(axis.x * math.cos(a) - axis.y * math.sin(a)), -(axis.x * math.sin(a) + axis.y * math.cos(a))))
                centre = start + ahead * (spec.entrance_lamp_offset + extra)
                if clear(centre):
                    return centre, -ahead
    raise ValueError('No room for the entrance lamp ahead of this mouth; change its distance or size')


def wall_outline(points, radius, arc=8):
    """The counter-clockwise outline of a thick line with round ends."""
    pts = [Vector(p[:2]) for p in points]
    tangents = [(b - a).normalized() for a, b in zip(pts, pts[1:])]
    def side(sign):
        out = []
        for i, p in enumerate(pts):
            t0 = tangents[max(i - 1, 0)]
            t1 = tangents[min(i, len(tangents) - 1)]
            miter = (t0 + t1).normalized()
            normal = Vector((-miter.y, miter.x))
            out.append(p + normal * sign * radius / max(normal.dot(Vector((-t1.y, t1.x))), .5))
        return out
    def cap(centre, direction):
        base = math.atan2(direction.y, direction.x)
        return [centre + Vector((math.cos(base + math.pi * .5 - math.pi * i / arc), math.sin(base + math.pi * .5 - math.pi * i / arc))) * radius for i in range(1, arc)]
    outline = side(1) + cap(pts[-1], tangents[-1]) + side(-1)[::-1] + cap(pts[0], -tangents[0])
    return outline[::-1]


def build_wall(points, radius, height):
    """A plank rising out of the board along a line: plain sides and top, with round ends and a small chamfer."""
    if len(points) < 2:
        raise ValueError('A wall needs at least two points')
    if radius <= .003 or height <= .006:
        raise ValueError('Wall is too thin or too low')
    data = MeshData()
    stations = [(0, 0), (0, height - .002), (.002, height)]
    roles = ['cabinet_shell', 'cabinet_shell']
    rings = [[(*p, z) for p in wall_outline(points, radius - inset)] for inset, z in stations]
    n = len(rings[0])
    vertices = [v for ring in rings for v in ring]
    faces, face_roles = [], []
    for k, role in enumerate(roles):
        for i in range(n):
            j = (i + 1) % n
            faces.append((k * n + i, k * n + j, (k + 1) * n + j, (k + 1) * n + i))
            face_roles.append(role)
    data.add(vertices, faces, face_roles, None, 50)
    data.add(rings[-1], [tuple(range(n))], 'cabinet_shell', None, 90)
    return data


def frange(start, stop, step):
    if step <= 0: raise ValueError('Spacing must be positive')
    while start < stop:
        yield start
        start += step


def clear_support(table,xy,radius,tight=False):
    """Deterministic support placement shared by authoring previews and game exports.
    Tight placement, for a ramp's end legs, leaves only just a ball's width."""
    spots=[]
    gap=table['physics']['ballRadius']*2+(.001 if tight else .005)
    for key,field,factor in [('bumpers','r',1.1),('posts','r',1),('lamps','size',1.1),('rollovers','r',1),('decor','size',1),('saucers','r',1.15),('magnets','r',1),('captiveBalls','r',1)]:
        spots.extend((v['x'],v['y'],v.get(field,.03)*(1 if tight else factor)+(gap if key in ('bumpers','posts','saucers') else .01)) for v in table.get(key,[]))
    if any(math.hypot(xy[0]-x,xy[1]-y)<radius+r for x,y,r in spots):return False
    for wall in table.get('walls',[]):
        if 'ramp' in wall.get('layers',[]):continue
        points=[]
        for p in wall['points']:
            if isinstance(p,dict):
                cx,cy,r,a,b,count=p['arc']
                points.extend((cx+r*math.cos(math.radians(a+(b-a)*i/count)),cy+r*math.sin(math.radians(a+(b-a)*i/count))) for i in range(count+1))
            else:points.append(p)
        if wall.get('closed'):points.append(points[0])
        if pathing.distance_to_polyline(xy,points)<radius+wall.get('radius',.003)+gap:return False
    for kind in ('slingshots','dropTargets','standups','spinners','gates'):
        if any(pathing.distance_to_polyline(xy,[e['a'],e['b']])<radius+gap for e in table.get(kind,[])):return False
    # Leave a ball-wide approach beneath rollover lanes, not just the sensor's own disc.
    for lane in table.get('rollovers',[]):
        a=(lane['x'],lane['y']);b=(lane['x'],lane['y']-.20)
        if pathing.distance_to_polyline(xy,[a,b])<radius+table['physics']['ballRadius']+.008:return False
    # A column must not stand under any channel. Half its foot may tuck beneath a rail.
    for ramp in table.get('ramps',[]):
        keep=ramp['width']*.5+ramp.get('authoring',{}).get('rail_width',.008)+radius*.5
        if pathing.distance_to_polyline(xy,ramp['points'])<keep:return False
    for f in table.get('flippers',[]):
        reach=f['length']+f['baseRadius']+gap+radius
        if math.dist(xy,f['pivot'])<reach:return False
    return True
