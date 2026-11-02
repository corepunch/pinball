"""Part operations, normals and COLLADA. Parts are geometry.MeshData:
vertices, faces, a surface role per face, UVs, and the crease angle that keeps an edge sharp."""
import math
from xml.etree.ElementTree import Element, SubElement, ElementTree

from shim import Vector, geometry

MeshData = geometry.MeshData


def lathe(data, profile, role, segments=48, xy=(0, 0), planar=None, sharp=38):
    """Turn a (radius, height) line about an upright axis, running up the outside and in over the top."""
    vertices, faces, uvs = [], [], []
    for radius, z in profile:
        for s in range(segments):
            a = s * math.tau / segments
            vertices.append((xy[0] + radius * math.cos(a), xy[1] + radius * math.sin(a), z))
            uvs.append((.5 + radius * math.cos(a) / planar, .5 + radius * math.sin(a) / planar) if planar else (0, 0))
    for row in range(len(profile) - 1):
        for s in range(segments):
            a, b = row * segments + s, row * segments + (s + 1) % segments
            faces.append((a, b, b + segments, a + segments))
    data.add(vertices, faces, role, uvs, sharp)


def wheel(data, radius, width, z, role, xy=(0, 0), segments=32):
    """A wheel on an axle along x, centred at height z, with a crowned tread that catches the light."""
    half = width * .5
    profile = [(.001, -half), (radius * .8, -half), (radius * .95, -half * .8), (radius, -half * .35), (radius, half * .35), (radius * .95, half * .8), (radius * .8, half), (.001, half)]
    turned = MeshData()
    lathe(turned, profile, role, segments, sharp=70)
    # A quarter turn about y lays the upright axis along x.
    data.add([(xy[0] + v[2], xy[1] + v[1], z - v[0]) for v in turned.vertices], turned.faces, role, None, 70)


def ring(data, major, minor, z, role, xy=(0, 0), segments=48, sides=8):
    profile = [(major + minor * math.cos(a), z + minor * math.sin(a)) for a in (-math.pi + i * math.tau / sides for i in range(sides + 1))]
    lathe(data, profile, role, segments, xy, sharp=80)


def bolt(data, radius, z, xy=(0, 0)):
    lathe(data, [(radius, z), (radius, z + radius * .2), (radius * .84, z + radius * .36), (radius * .62, z + radius * .36)], 'accent', 20, xy, sharp=70)
    lathe(data, [(radius * .64, z + radius * .28), (radius * .58, z + radius * .56), (radius * .34, z + radius * .84), (.0001, z + radius * .94)], 'metal', 16, xy, sharp=80)


def sweep(data, path, section, role, closed=False, band_roles=None, sharp=38):
    """Run a section along a path. Section points are (offset left of travel, height), from the right foot over the top."""
    n = len(path)
    pts = [Vector((p[0], p[1], p[2] if len(p) > 2 else 0)) for p in path]
    vertices = []
    along = 0
    uvs = []
    for i, p in enumerate(pts):
        before = pts[(i - 1) % n] if closed or i else p
        after = pts[(i + 1) % n] if closed or i + 1 < n else p
        incoming, outgoing = (p - before).xy, (after - p).xy
        t0 = incoming.normalized() if incoming.length > 1e-7 else outgoing.normalized()
        t1 = outgoing.normalized() if outgoing.length > 1e-7 else t0
        miter = t0 + t1
        miter = miter.normalized() if miter.length > 1e-4 else t1
        normal = Vector((-miter.y, miter.x))
        stretch = 1 / max(miter.dot(t1), .45)
        if i:
            along += (p - pts[i - 1]).length
        for j, (offset, z) in enumerate(section):
            vertices.append((p.x + normal.x * offset * stretch, p.y + normal.y * offset * stretch, p.z + z))
            uvs.append((along, j / max(len(section) - 1, 1)))
    m = len(section)
    faces, roles = [], []
    for i in range(n if closed else n - 1):
        k = (i + 1) % n
        for j in range(m - 1):
            faces.append((i * m + j, k * m + j, k * m + j + 1, i * m + j + 1))
            roles.append(band_roles[j] if band_roles else role)
    data.add(vertices, faces, roles, uvs, sharp)


def signed_area(outline):
    return sum(outline[i][0] * outline[(i + 1) % len(outline)][1] - outline[(i + 1) % len(outline)][0] * outline[i][1] for i in range(len(outline))) * .5


def ccw(outline):
    return outline if signed_area(outline) > 0 else outline[::-1]


def flat(data, outline, z, role, sharp=90, uv=None):
    """A flat polygon facing up, its UVs filling the outline's bounding box, or the rectangle uv = (u0, v0, u1, v1)."""
    outline = ccw(outline)
    low = (min(p[0] for p in outline), min(p[1] for p in outline))
    high = (max(p[0] for p in outline), max(p[1] for p in outline))
    u0, v0, u1, v1 = uv or (0, 0, 1, 1)
    uvs = [(u0 + (u1 - u0) * (p[0] - low[0]) / max(high[0] - low[0], 1e-5), v0 + (v1 - v0) * (p[1] - low[1]) / max(high[1] - low[1], 1e-5)) for p in outline]
    data.add([(p[0], p[1], z) for p in outline], [tuple(range(len(outline)))], role, uvs, sharp)


def inset_polygon(outline, distance):
    """A convex counter-clockwise polygon moved in by distance."""
    out = []
    n = len(outline)
    for i in range(n):
        p, a, b = Vector(outline[i]), Vector(outline[i - 1]), Vector(outline[(i + 1) % n])
        t0, t1 = (p - a).normalized(), (b - p).normalized()
        miter = (t0 + t1).normalized()
        normal = Vector((-miter.y, miter.x))
        q = p + normal * (distance / max(normal.dot(Vector((-t1.y, t1.x))), .3))
        out.append((q.x, q.y))
    return out


def raised_outline(outline, radius, height):
    """A plate rising out of the board: an outline, which may be concave, grown by the collider's radius, with a small chamfer."""
    # Arcs share their end points with what follows them.
    outline = [p for i, p in enumerate(outline) if math.dist(p, outline[i - 1]) > 1e-5]
    rim = inset_polygon(ccw(outline), -radius)
    data = MeshData()
    rings = [[(*p, z) for p in inset_polygon(rim, inset)] for inset, z in ((0, 0), (0, height - .002), (.002, height))]
    n = len(rim)
    faces = [(k * n + i, k * n + (i + 1) % n, (k + 1) * n + (i + 1) % n, (k + 1) * n + i) for k in range(2) for i in range(n)]
    data.add([v for ring in rings for v in ring], faces, ['cabinet_shell'] * len(faces), None, 50)
    data.add(rings[-1], [tuple(range(n))], 'cabinet_shell', None, 90)
    return data


def filleted(outline, radius, arc=8):
    """A convex counter-clockwise polygon with round corners."""
    out = []
    n = len(outline)
    for i in range(n):
        p, a, b = Vector(outline[i]), Vector(outline[i - 1]), Vector(outline[(i + 1) % n])
        t0, t1 = (p - a).normalized(), (b - p).normalized()
        turn = math.acos(max(-1, min(1, t0.dot(t1))))
        reach = radius * math.tan(turn * .5)
        start = p - t0 * reach
        centre = start + Vector((-t0.y, t0.x)) * radius
        a0 = math.atan2((start - centre).y, (start - centre).x)
        for k in range(arc + 1):
            q = centre + Vector((math.cos(a0 + turn * k / arc), math.sin(a0 + turn * k / arc))) * radius
            out.append((q.x, q.y))
    return out


def plate(data, outline, base, height, role, corner=0, chamfer=0, sharp=40, uv=None):
    """Thicken an outline upward, with optional round corners and a chamfered top edge."""
    outline = ccw(outline)
    if corner:
        outline = filleted(outline, corner, 4)
    stations = [(0, base), (0, base + height - chamfer)] + ([(chamfer, base + height)] if chamfer else [])
    sweep(data, outline, stations, role, closed=True, sharp=sharp)
    flat(data, inset_polygon(outline, chamfer) if chamfer else outline, base + height, role, sharp, uv)


def dome(data, outline, rings, apex, role, sharp=60, centre=None):
    """A moulded lens: rings of (scale about the centre, height) over an outline, closed at an apex height."""
    n = len(outline)
    cx = sum(p[0] for p in outline) / n if centre is None else centre[0]
    cy = sum(p[1] for p in outline) / n if centre is None else centre[1]
    low = (min(p[0] for p in outline), min(p[1] for p in outline))
    span = (max(p[0] for p in outline) - low[0], max(p[1] for p in outline) - low[1])
    vertices = [(cx + (p[0] - cx) * k, cy + (p[1] - cy) * k, z) for k, z in rings for p in outline] + [(cx, cy, apex)]
    faces = []
    for r in range(len(rings) - 1):
        for i in range(n):
            j = (i + 1) % n
            faces.append((r * n + i, r * n + j, (r + 1) * n + j, (r + 1) * n + i))
    last = (len(rings) - 1) * n
    for i in range(n):
        faces.append((last + i, last + (i + 1) % n, last + n))
    uvs = [((v[0] - low[0]) / span[0], (v[1] - low[1]) / span[1]) for v in vertices]
    data.add(vertices, faces, role, uvs, sharp)


# ---------------------------------------------------------------------- Triangles and normals

def _newell(points):
    nx = ny = nz = 0.0
    for a, b in zip(points, points[1:] + points[:1]):
        nx += (a[1] - b[1]) * (a[2] + b[2])
        ny += (a[2] - b[2]) * (a[0] + b[0])
        nz += (a[0] - b[0]) * (a[1] + b[1])
    return nx, ny, nz


def triangulate(vertices, face):
    """Ear clipping, for the concave outlines of walls and ramp ends."""
    if len(face) == 3:
        return [tuple(face)]
    if len(face) == 4:
        pts = [vertices[i] for i in face]
        n = _newell(pts)
        keep = [i for i in range(3) if i != max(range(3), key=lambda k: abs(n[k]))]
        sign = 1 if n[3 - sum(keep)] * (1 if sum(keep) != 2 else -1) >= 0 else -1
        def cross(a, b, c):
            return ((b[keep[0]] - a[keep[0]]) * (c[keep[1]] - a[keep[1]]) - (b[keep[1]] - a[keep[1]]) * (c[keep[0]] - a[keep[0]])) * sign
        if cross(pts[0], pts[1], pts[2]) >= -1e-12 and cross(pts[0], pts[2], pts[3]) >= -1e-12:
            return [(face[0], face[1], face[2]), (face[0], face[2], face[3])]
        return [(face[1], face[2], face[3]), (face[1], face[3], face[0])]
    points = [vertices[i] for i in face]
    n = _newell(points)
    drop = max(range(3), key=lambda k: abs(n[k]))
    keep = [i for i in range(3) if i != drop]
    if (keep == [0, 2]) != (n[drop] < 0):
        keep = keep[::-1]
    flat_points = {i: (vertices[i][keep[0]], vertices[i][keep[1]]) for i in face}
    def area(a, b, c):
        return (flat_points[b][0] - flat_points[a][0]) * (flat_points[c][1] - flat_points[a][1]) - (flat_points[b][1] - flat_points[a][1]) * (flat_points[c][0] - flat_points[a][0])
    def inside(p, a, b, c):
        q = flat_points[p]
        for u, v in ((a, b), (b, c), (c, a)):
            if (flat_points[v][0] - flat_points[u][0]) * (q[1] - flat_points[u][1]) - (flat_points[v][1] - flat_points[u][1]) * (q[0] - flat_points[u][0]) < -1e-12:
                return False
        return True
    remaining = list(face)
    triangles = []
    guard = 0
    while len(remaining) > 3 and guard < len(face) ** 2:
        guard += 1
        for i in range(len(remaining)):
            a, b, c = remaining[i - 1], remaining[i], remaining[(i + 1) % len(remaining)]
            if area(a, b, c) <= 1e-14:
                continue
            if any(inside(p, a, b, c) for p in remaining if p not in (a, b, c) and flat_points[p] not in (flat_points[a], flat_points[b], flat_points[c])):
                continue
            triangles.append((a, b, c))
            del remaining[i]
            break
        else:
            # Only degenerate corners left: drop the flattest one.
            remaining.pop(min(range(len(remaining)), key=lambda i: abs(area(remaining[i - 1], remaining[i], remaining[(i + 1) % len(remaining)]))))
    if len(remaining) == 3:
        triangles.append(tuple(remaining))
    return triangles


def corner_normals(data):
    """A normal per face corner: smooth across edges under each face's crease angle, sharp over it."""
    face_normals = []
    for face in data.faces:
        n = _newell([data.vertices[i] for i in face])
        size = math.sqrt(sum(c * c for c in n)) or 1
        face_normals.append(((n[0] / size, n[1] / size, n[2] / size), size))
    around = {}
    edges = {}
    for f, face in enumerate(data.faces):
        for k, v in enumerate(face):
            around.setdefault(v, []).append(f)
            edges.setdefault(tuple(sorted((v, face[(k + 1) % len(face)]))), []).append(f)
    result = {}
    for v, faces in around.items():
        if v in data.normals:
            for f in faces:
                result[(f, v)] = data.normals[v]
            continue
        parent = {f: f for f in faces}
        def find(f):
            while parent[f] != f:
                parent[f] = parent[parent[f]]
                f = parent[f]
            return f
        for f in faces:
            face = data.faces[f]
            k = face.index(v)
            for other in (face[(k + 1) % len(face)], face[k - 1]):
                for g in edges[tuple(sorted((v, other)))]:
                    if g != f and g in parent:
                        dot = sum(a * b for a, b in zip(face_normals[f][0], face_normals[g][0]))
                        limit = min(data.sharp[f], data.sharp[g])
                        if math.degrees(math.acos(max(-1, min(1, dot)))) <= limit:
                            parent[find(f)] = find(g)
        groups = {}
        for f in faces:
            groups.setdefault(find(f), []).append(f)
        for members in groups.values():
            total = [0.0, 0.0, 0.0]
            for f in members:
                n, weight = face_normals[f]
                for i in range(3):
                    total[i] += n[i] * weight
            size = math.sqrt(sum(c * c for c in total)) or 1
            normal = tuple(c / size for c in total)
            for f in members:
                result[(f, v)] = normal
    return result


# --------------------------------------------------------------------------------- COLLADA

NS = 'http://www.collada.org/2005/11/COLLADASchema'


def _child(parent, tag, attributes=None, text=None):
    e = SubElement(parent, tag, attributes or {})
    if text is not None:
        e.text = text
    return e


def _floats(values):
    return ' '.join(format(v, '.6g') for v in values)


def write_collada(name, data, path, colors):
    """Y-up, one mesh per surface role, with explicit normals and UVs. The game rebinds materials by role name."""
    normals = corner_normals(data)
    grouped = {}
    triangle_count = 0
    reach = 0.0
    for f, face in enumerate(data.faces):
        role = data.roles[f]
        group = grouped.setdefault(role, {'positions': [], 'normals': [], 'uvs': [], 'lookup': {}, 'indices': []})
        for triangle in triangulate(data.vertices, face):
            triangle_count += 1
            for v in triangle:
                p, n, t = data.vertices[v], normals[(f, v)], data.uvs[v]
                key = (round(p[0], 6), round(p[2], 6), round(-p[1], 6), round(n[0], 3), round(n[2], 3), round(-n[1], 3), round(t[0], 4), round(t[1], 4))
                index = group['lookup'].get(key)
                if index is None:
                    index = len(group['positions']) // 3
                    group['lookup'][key] = index
                    group['positions'].extend(key[:3])
                    group['normals'].extend(key[3:6])
                    group['uvs'].extend(key[6:])
                group['indices'].append(index)
                reach = max(reach, math.hypot(p[0], p[1]))
    doc = Element('COLLADA', {'xmlns': NS, 'version': '1.4.1'})
    meta = _child(doc, 'asset')
    _child(meta, 'contributor')
    _child(meta, 'created', text='2026-11-01T00:00:00Z')
    _child(meta, 'modified', text='2026-11-01T00:00:00Z')
    _child(meta, 'unit', {'name': 'meter', 'meter': '1'})
    _child(meta, 'up_axis', text='Y_UP')
    effects = _child(doc, 'library_effects')
    materials = _child(doc, 'library_materials')
    for role in grouped:
        effect = _child(effects, 'effect', {'id': role + '-fx'})
        tech = _child(_child(effect, 'profile_COMMON'), 'technique', {'sid': 'common'})
        _child(_child(_child(tech, 'lambert'), 'diffuse'), 'color', text=_floats(colors[role]))
        material = _child(materials, 'material', {'id': role + '-mat', 'name': role})
        _child(material, 'instance_effect', {'url': '#' + role + '-fx'})
    geometries = _child(doc, 'library_geometries')
    scene = _child(_child(doc, 'library_visual_scenes'), 'visual_scene', {'id': 'Scene', 'name': name})
    for number, (role, group) in enumerate(grouped.items()):
        gid = f'mesh{number}'
        mesh = _child(_child(geometries, 'geometry', {'id': gid, 'name': role}), 'mesh')
        for suffix, values, stride, axes in (('pos', group['positions'], 3, 'XYZ'), ('norm', group['normals'], 3, 'XYZ'), ('uv', group['uvs'], 2, 'ST')):
            source = _child(mesh, 'source', {'id': gid + '-' + suffix})
            array = gid + '-' + suffix + '-array'
            _child(source, 'float_array', {'id': array, 'count': str(len(values))}, _floats(values))
            accessor = _child(_child(source, 'technique_common'), 'accessor', {'source': '#' + array, 'count': str(len(values) // stride), 'stride': str(stride)})
            for axis in axes:
                _child(accessor, 'param', {'name': axis, 'type': 'float'})
        _child(_child(mesh, 'vertices', {'id': gid + '-verts'}), 'input', {'semantic': 'POSITION', 'source': '#' + gid + '-pos'})
        triangles = _child(mesh, 'triangles', {'material': role, 'count': str(len(group['indices']) // 3)})
        for semantic, suffix, offset in (('VERTEX', 'verts', 0), ('NORMAL', 'norm', 1), ('TEXCOORD', 'uv', 2)):
            attributes = {'semantic': semantic, 'source': '#' + gid + '-' + suffix, 'offset': str(offset)}
            if semantic == 'TEXCOORD':
                attributes['set'] = '0'
            _child(triangles, 'input', attributes)
        _child(triangles, 'p', text=' '.join(f'{i} {i} {i}' for i in group['indices']))
        node = _child(scene, 'node', {'id': gid + '-node', 'name': role, 'type': 'NODE'})
        instance = _child(node, 'instance_geometry', {'url': '#' + gid})
        binding = _child(_child(instance, 'bind_material'), 'technique_common')
        _child(binding, 'instance_material', {'symbol': role, 'target': '#' + role + '-mat'})
    _child(_child(doc, 'scene'), 'instance_visual_scene', {'url': '#Scene'})
    ElementTree(doc).write(path, encoding='utf-8', xml_declaration=True)
    return {'objects': 1, 'triangles': triangle_count, 'radius': round(reach, 4), 'bytes': path.stat().st_size}
