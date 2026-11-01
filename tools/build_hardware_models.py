"""Editable Blender hardware master and SceneKit-ready COLLADA, executed via Blender MCP.

No downloads, simulation caches or external Python packages. Round kit parts are built to
unit radius and scaled by the table; elongated decor to unit half length. Each table in
GameData/Tables gets its own assets (flipper, ramps, walls, plastics) in
the JSON's coordinates, so they follow the physics exactly: rebuild after moving walls or ramps.
"""
import bmesh
import bpy
import json
import math
from pathlib import Path
from mathutils import Vector
from xml.etree.ElementTree import Element, SubElement, ElementTree

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "Art/Models/premium"  # tools/compile_models.sh turns these into the shipped .scn files.
OUT.mkdir(parents=True, exist_ok=True)
(ROOT / "Art/Models").mkdir(parents=True, exist_ok=True)
if not bpy.app.background:
    raise RuntimeError('Run this generator in the dedicated background Blender MCP session')
for previous in list(bpy.data.scenes):
    if previous.get('workflow', '').startswith('Authored through the installed Blender MCP bridge'):
        for obj in list(previous.objects):
            bpy.data.objects.remove(obj, do_unlink=True)
        if len(bpy.data.scenes) > 1:
            bpy.data.scenes.remove(previous)
scene = bpy.data.scenes.new("Pinball • machined hardware")
bpy.context.window.scene = scene
scene.unit_settings.system = 'METRIC'
scene['source_reference'] = 'Art/Concepts/premium-directions.png'
scene['workflow'] = 'Authored through the installed Blender MCP bridge; tools/build_hardware_models.py'

# Each role is a material slot the game rebinds per skin; see PBTableScene's skinModel.
ROLES = {
    'metal': (.56, .61, .65, 1), 'accent': (.72, .48, .19, 1), 'dark': (.012, .019, .027, 1),
    'rubber': (.62, .58, .47, 1), 'black_rubber': (.012, .012, .014, 1), 'skirt_lamp': (1, .2, .08, 1), 'cap_art': (.7, .2, .12, 1), 'enamel': (.86, .78, .6, 1),
    'lens': (.9, .95, 1, .18), 'glow': (.2, .8, 1, 1), 'glow_amber': (1, .65, .16, 1),
    'jewel': (.2, .8, 1, 1), 'ramp_floor': (.86, .78, .6, .62), 'sling_lens': (1, .25, .1, 1), 'amber_lens': (1, .65, .16, 1),
    'wall_art': (.05, .12, .14, 1), 'block_art': (.05, .18, .18, 1),
    'flipper_art': (.9, .85, .7, 1), 'target_art': (.6, .3, .15, 1),
}
ATLAS_SLOTS = {'cap_art': 'bumper_cap', 'jewel': 'bumper_cap_lit', 'wall_art': 'wall_top', 'block_art': 'plastic',
               'flipper_art': 'flipper', 'target_art': 'drop_target'}
METALLIC = ('metal', 'accent', 'ramp_floor')
EMISSIVE = {'amber_lens': 1, 'skirt_lamp': 3, 'glow': 3, 'glow_amber': 3, 'jewel': 1, 'sling_lens': 1}
materials = {}
palette = json.loads((ROOT / 'GameData/Skins/orbital.json').read_text())
atlas = bpy.data.images.load(str(ROOT / 'Art/Masters/orbital-hardware.png'))
for role, color in ROLES.items():
    material = bpy.data.materials.new(role)
    material.diffuse_color = color
    material.use_nodes = True
    nodes, links = material.node_tree.nodes, material.node_tree.links
    bsdf = nodes.get('Principled BSDF')
    bsdf.inputs['Base Color'].default_value = color
    bsdf.inputs['Metallic'].default_value = .9 if role in METALLIC else 0
    bsdf.inputs['Roughness'].default_value = .2 if role in METALLIC else .3
    if color[3] < 1:
        # Only for tools/render_board_blender.py: the game binds its own clear materials.
        bsdf.inputs['Alpha'].default_value = color[3]
        material.blend_method = 'BLEND'
    if role in EMISSIVE:
        bsdf.inputs['Emission Color'].default_value = color
        bsdf.inputs['Emission Strength'].default_value = EMISSIVE[role]
    if role in ATLAS_SLOTS:
        uv, mapping, texture = nodes.new('ShaderNodeTexCoord'), nodes.new('ShaderNodeMapping'), nodes.new('ShaderNodeTexImage')
        texture.image = atlas
        x, y, w, h = palette['atlasLayout']['slots'][ATLAS_SLOTS[role]]['rect']
        mapping.inputs['Location'].default_value = (x / 1254, 1 - (y + h) / 1254, 0)
        mapping.inputs['Scale'].default_value = (w / 1254, h / 1254, 1)
        links.new(uv.outputs['UV'], mapping.inputs['Vector'])
        links.new(mapping.outputs['Vector'], texture.inputs['Vector'])
        links.new(texture.outputs['Color'], bsdf.inputs['Base Color'])
        if role in EMISSIVE:
            links.new(texture.outputs['Color'], bsdf.inputs['Emission Color'])
    materials[role] = material

assets = {}
current = None


def asset(name, location=(0, 0, 0), scale=1):
    """Assets sit apart in the master so it stays browsable; export undoes this transform."""
    global current
    root = bpy.data.objects.new(name, None)
    scene.collection.objects.link(root)
    root.location, root.scale = location, (scale,) * 3
    root['asset_name'] = name
    assets[name] = (root, [])
    current = name
    return root


def solid(name, vertices, faces, role, uvs=None, sharp=38):
    """Faces follow the right-hand rule outward: SceneKit culls back faces."""
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata([tuple(v) for v in vertices], [], faces)
    mesh.update()
    mesh.materials.append(materials[role])
    if uvs:
        layer = mesh.uv_layers.new(name='UV')
        for loop in mesh.loops:
            layer.data[loop.index].uv = uvs[loop.vertex_index]
    mesh.shade_smooth()
    # Machined parts keep crisp creases; rounded ones stay smooth.
    work = bmesh.new()
    work.from_mesh(mesh)
    for edge in work.edges:
        if len(edge.link_faces) == 2 and edge.calc_face_angle(0) > math.radians(sharp):
            edge.smooth = False
    work.to_mesh(mesh)
    work.free()
    obj = bpy.data.objects.new(name, mesh)
    scene.collection.objects.link(obj)
    obj.parent = assets[current][0]
    obj['surface_role'] = role
    assets[current][1].append(obj)
    return obj


def lathe(name, profile, role, segments=48, xy=(0, 0), planar=None, sharp=38):
    """Profile runs (radius, height) up the outside and in over the top. planar maps UVs from above."""
    vertices, faces, uvs = [], [], []
    for radius, z in profile:
        for s in range(segments):
            a = s * 2 * math.pi / segments
            vertices.append((xy[0] + radius * math.cos(a), xy[1] + radius * math.sin(a), z))
            if planar:
                uvs.append((.5 + radius * math.cos(a) / planar, .5 + radius * math.sin(a) / planar))
    for row in range(len(profile) - 1):
        for s in range(segments):
            a = row * segments + s
            b = row * segments + (s + 1) % segments
            faces.append((a, b, b + segments, a + segments))
    return solid(name, vertices, faces, role, uvs or None, sharp)


def cylinder(name, radius, bottom, top, role, xy=(0, 0), segments=24, bevel=None):
    b = radius * .12 if bevel is None else bevel
    return lathe(name, [(radius, bottom), (radius, top - b), (radius - b, top), (.0001, top)], role, segments, xy)


def bolt(name, radius, z, xy=(0, 0)):
    """The concept's big fastener: a brass collar holding a polished dome."""
    lathe(f'{name} collar', [(radius, z), (radius, z + radius * .2), (radius * .84, z + radius * .36), (radius * .62, z + radius * .36)], 'accent', 20, xy, sharp=70)
    lathe(f'{name} dome', [(radius * .64, z + radius * .28), (radius * .58, z + radius * .56), (radius * .34, z + radius * .84), (.0001, z + radius * .94)], 'metal', 16, xy, sharp=80)


def ring(name, major, minor, z, role, xy=(0, 0), segments=48, sides=8):
    profile = [(major + minor * math.cos(a), z + minor * math.sin(a))
               for a in (-math.pi + i * 2 * math.pi / sides for i in range(sides + 1))]
    return lathe(name, profile[::-1] if False else profile, role, segments, xy, sharp=80)


def sweep(name, path, section, role, closed=False, band_roles=None, sharp=38, uv_scale=None):
    """Extrude section along path. Section points are (offset left of travel, height above
    the path point), running from the right foot over the top to the left foot."""
    n = len(path)
    pts = [Vector(p) for p in path]
    vertices, uvs = [], []
    along = 0
    for i, p in enumerate(pts):
        before = pts[(i - 1) % n] if closed or i else p
        after = pts[(i + 1) % n] if closed or i + 1 < n else p
        incoming = (p - before).xy
        outgoing = (after - p).xy
        t0 = incoming.normalized() if incoming.length > 1e-7 else outgoing.normalized()
        t1 = outgoing.normalized() if outgoing.length > 1e-7 else t0
        miter = (t0 + t1)
        miter = miter.normalized() if miter.length > 1e-4 else t1
        normal = Vector((-miter.y, miter.x))
        stretch = 1 / max(miter.dot(t1), .45)
        if i:
            along += (p - pts[i - 1]).length
        for j, (offset, z) in enumerate(section):
            vertices.append((p.x + normal.x * offset * stretch, p.y + normal.y * offset * stretch, p.z + z))
            uvs.append((along * (uv_scale or 1), j / max(len(section) - 1, 1)))
    m = len(section)
    faces, roles = [], []
    for i in range(n if closed else n - 1):
        for j in range(m - 1):
            k = (i + 1) % n
            faces.append((i * m + j, k * m + j, k * m + j + 1, i * m + j + 1))
            roles.append(band_roles[j] if band_roles else role)
    if not band_roles:
        return solid(name, vertices, faces, role, uvs, sharp)
    # One object per role keeps the exporter's material grouping trivial.
    objects = []
    for wanted in sorted(set(roles)):
        kept = [f for f, r in zip(faces, roles) if r == wanted]
        objects.append(solid(f'{name} • {wanted}', vertices, kept, wanted, uvs, sharp))
    return objects


def prism_top(name, outline, z, role, inset=0):
    """Flat polygon facing up, its UVs filling the outline's bounding box."""
    if sum(outline[i][0] * outline[(i + 1) % len(outline)][1] - outline[(i + 1) % len(outline)][0] * outline[i][1]
           for i in range(len(outline))) < 0:
        outline = outline[::-1]
    low = (min(p[0] for p in outline), min(p[1] for p in outline))
    high = (max(p[0] for p in outline), max(p[1] for p in outline))
    uvs = [((p[0] - low[0]) / max(high[0] - low[0], 1e-5), (p[1] - low[1]) / max(high[1] - low[1], 1e-5)) for p in outline]
    return solid(name, [(p[0], p[1], z) for p in outline], [tuple(range(len(outline)))], role, uvs, 90)


# ---------------------------------------------------------------------------------- Kit parts

X = 0
def next_slot():
    global X
    X += 3
    return (X, 0, 0)


# From the construction drawing: base flange, skirt with lit slots, rubber ring, cap, jewel.
# Tall enough that the camera's tilt shows the skirt below the ring.
asset('bumper-base', next_slot())
lathe('Base flange', [(1.06, 0), (1.06, .05), (1.03, .08), (.94, .1)], 'accent', 64, sharp=70)
for i in range(8):
    a = 2 * math.pi * (i + .5) / 8
    bolt(f'Flange bolt {i}', .034, .06, (1.0 * math.cos(a), 1.0 * math.sin(a)))
lathe('Skirt', [(.92, .08), (.92, .72)], 'accent', 64, sharp=70)
ring('Skirt band', .925, .018, .18, 'metal', segments=64, sides=6)
for i in range(10):
    a0 = 2 * math.pi * (i + .22) / 10
    a1 = 2 * math.pi * (i + .78) / 10
    quad = [(r * math.cos(a), r * math.sin(a), z) for a, r, z in ((a0, .93, .25), (a1, .93, .25), (a1, .93, .55), (a0, .93, .55))]
    solid(f'Lit slot {i}', quad, [(0, 1, 2, 3)], 'skirt_lamp', sharp=90)
lathe('Rubber ring', [(.86, .72), (.97, .75), (1.02, .86), (.97, .97), (.88, 1.01)], 'black_rubber', 64, sharp=80)

CAP_PLANAR = 1.8
asset('bumper-cap', next_slot())
lathe('Cap • painted star', [(.9, 1.06), (.8, 1.11), (.64, 1.17), (.5, 1.21)], 'cap_art', 72, planar=CAP_PLANAR, sharp=80)
lathe('Brass lip', [(.93, .98), (.93, 1.05), (.89, 1.09), (.85, 1.085)], 'accent', 72, sharp=70)
lathe('Jewel collar', [(.5, 1.2), (.5, 1.25), (.46, 1.29), (.33, 1.31), (.3, 1.29)], 'accent', 56, sharp=70)
for i in range(8):
    a = 2 * math.pi * (i + .5) / 8
    bolt(f'Collar bolt {i}', .026, 1.28, (.415 * math.cos(a), .415 * math.sin(a)))
lathe('Jewel', [(.31, 1.27), (.3, 1.34), (.23, 1.43), (.12, 1.49), (.001, 1.51)], 'jewel', 40, planar=.64, sharp=80)

asset('insert-bezel', next_slot())
lathe('Recessed socket', [(1.08, -.02), (1.10, .01), (1.06, .05), (1.0, .055)], 'dark', 40)
ring('Bevelled bezel', 1.04, .03, .05, 'accent', segments=40, sides=8)
# A shallow clear lens over the printed insert, so each one catches a highlight like a jewel.
lathe('Domed lens', [(1.0, .05), (.92, .13), (.7, .21), (.38, .265), (.001, .28)], 'lens', 36, sharp=80)

# Unit circumradius, apex on +x. The scene rotates it to the lamp's angle.
triangle = []
for corner, a in enumerate((0, 2 * math.pi / 3, 4 * math.pi / 3)):
    centre = Vector((math.cos(a), math.sin(a))) * .78
    for s in range(7):
        b = a - math.pi / 3 + s * (2 * math.pi / 3) / 6
        triangle.append((centre.x + .24 * math.cos(b), centre.y + .24 * math.sin(b), 0))
asset('insert-arrow', next_slot())
w = .04
sweep('Triangular bezel', triangle, [(-w, -.02), (-w, .06), (-w * .3, .10), (w * .3, .10), (w, .06), (w, -.02)], 'accent', closed=True)
sweep('Triangular socket', triangle, [(w, -.02), (w, .01), (w * 1.2, .012), (w * 1.2, -.02)], 'dark', closed=True)
inner = [(p[0] * .93, p[1] * .93) for p in triangle]
apex = len(inner)
vertices = [(p[0], p[1], .05) for p in inner] + [(p[0] * .62, p[1] * .62, .2) for p in inner] + [(0, 0, .26)]
faces = []
for i in range(apex):
    j = (i + 1) % apex
    faces.append((i, j, j + apex, i + apex))
    faces.append((i + apex, j + apex, apex * 2))
solid('Faceted lens', vertices, faces, 'lens', sharp=80)

# Small polished studs: the walls they cap are thin lines.
asset('post', next_slot())
lathe('Collar', [(.62, 0), (.62, 2.4), (.56, 2.6)], 'accent', 20, sharp=80)
lathe('Polished dome', [(.56, 2.5), (.5, 3.0), (.3, 3.4), (.001, 3.5)], 'metal', 18, sharp=80)

asset('target', next_slot())
d, t = .17, 1.0
face = [(-.5, -d), (.5, -d), (.5, d), (-.5, d)]
solid('Target art', [(x, y, t) for x, y in face], [(0, 1, 2, 3)], 'target_art', [(0, 0), (1, 0), (1, 1), (0, 1)], 90)
sweep('Target frame', [(x * 1.06, y * 1.12, 0) for x, y in face],
      [(-.05, 0), (-.05, t - .06), (-.02, t), (.03, t)], 'accent', closed=True, sharp=30)

asset('flasher-cage', next_slot())
lathe('Foot ring', [(1.05, 0), (1.05, .1), (.92, .22)], 'accent', 32)
ring('Chrome collar', .86, .07, .24, 'metal', segments=32)

def bullet_lamp(name, glow):
    """Unit radius: a glowing bullet in a brass and chrome socket, seen from above."""
    asset(name, next_slot())
    lathe('Socket flange', [(1.0, 0), (1.0, .1), (.92, .18), (.8, .2)], 'accent', 28)
    ring('Chrome ring', .78, .07, .24, 'metal', segments=28)
    lathe('Glowing bullet', [(.7, .2), (.68, .42), (.52, .62), (.28, .76), (.001, .8)], glow, 24, sharp=80)
    lathe('Lens highlight', [(.72, .24), (.69, .44), (.53, .64), (.29, .78), (.001, .82)], 'lens', 24, sharp=80)


bullet_lamp('bullet-cyan', 'glow')
bullet_lamp('bullet-amber', 'glow_amber')

asset('stud', next_slot())
lathe('Stud base', [(1.0, 0), (1.0, .12), (.86, .22), (.72, .24)], 'accent', 24)
lathe('Stud dome', [(.74, .2), (.7, .5), (.5, .8), (.26, .96), (.001, 1.0)], 'metal', 20, sharp=80)

# Unit circumradius, apex on +x: an always-lit coloured insert and its brass bezel.
asset('arrow-lens', next_slot())
w = .045
sweep('Heavy bezel', triangle, [(-w, -.02), (-w, .08), (-w * .3, .13), (w * .3, .13), (w, .08), (w, -.02)], 'accent', closed=True)
inner = [(p[0] * .9, p[1] * .9) for p in triangle]
low = [min(p[i] for p in inner) for i in (0, 1)]
span = [max(p[i] for p in inner) - low[i] for i in (0, 1)]
n = len(inner)
vertices = [(p[0], p[1], .05) for p in inner] + [(p[0] * .6, p[1] * .6, .16) for p in inner] + [(0, 0, .22)]
uvs = [((v[0] - low[0]) / span[0], (v[1] - low[1]) / span[1]) for v in vertices]
faces = []
for i in range(n):
    j = (i + 1) % n
    faces.append((i, j, j + n, i + n))
    faces.append((i + n, j + n, n * 2))
solid('Coloured lens', vertices, faces, 'sling_lens', uvs, sharp=80)


# --------------------------------------------------------------------------- Table-specific

TABLES = [json.loads(path.read_text()) for path in sorted((ROOT / 'GameData/Tables').glob('*.json'))]
SIZE = TABLES[0]['size']  # Set per table in the loop below.


def centred(x, y):
    return x - SIZE[0] * .5, y - SIZE[1] * .5


def table_path(points):
    out = []
    for entry in points:
        if isinstance(entry, dict):
            cx, cy, r, a0, a1, n = entry['arc']
            for i in range(n + 1):
                a = math.radians(a0 + (a1 - a0) * i / n)
                out.append((cx + r * math.cos(a), cy + r * math.sin(a)))
        else:
            out.append(tuple(entry))
    return out


def smooth_path(points):
    """The table's Catmull–Rom sampling (six subdivisions per authored segment)."""
    p = [Vector(v) for v in points]
    out = []
    at = lambda n: p[max(0, min(n, len(p) - 1))]
    for i in range(len(p) - 1):
        p0, p1, p2, p3 = at(i - 1), at(i), at(i + 1), at(i + 2)
        for step in range(6):
            t = step / 6
            out.append(.5 * ((2 * p1) + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t + (3 * p1 - p0 - 3 * p2 + p3) * t * t * t))
    return out + [p[-1]]


def faceted_lens(name, outline, z, role, rise=None):
    """A shallow moulded dome over a counter-clockwise outline, UVs across its bounding box."""
    centre = Vector((sum(p[0] for p in outline) / len(outline), sum(p[1] for p in outline) / len(outline)))
    low = (min(p[0] for p in outline), min(p[1] for p in outline))
    span = (max(p[0] for p in outline) - low[0], max(p[1] for p in outline) - low[1])
    n = len(outline)
    rise = min(span) * .1 if rise is None else rise
    rings = [(1.0, 0), (.8, rise * .75), (.48, rise)]
    vertices = [(centre.x + (p[0] - centre.x) * k, centre.y + (p[1] - centre.y) * k, z + dz) for k, dz in rings for p in outline] + [(centre.x, centre.y, z + rise * 1.12)]
    faces = []
    for r in range(2):
        for i in range(n):
            j = (i + 1) % n
            faces.append((r * n + i, r * n + j, (r + 1) * n + j, (r + 1) * n + i))
    for i in range(n):
        faces.append((2 * n + i, 2 * n + (i + 1) % n, 3 * n))
    uvs = [((v[0] - low[0]) / span[0], (v[1] - low[1]) / span[1]) for v in vertices]
    return solid(name, vertices, faces, role, uvs, 60)


# ------------------------------------------------------------------------------- Mechanisms

def lens_triangle(name, centre, scale, apex, role):
    """A framed, domed triangular lens from the arrow outline, its apex along +x or -x."""
    outline = [(centre + apex * p[0] * scale, apex * p[1] * scale) for p in triangle]
    if apex < 0:
        outline = outline[::-1]
    faceted_lens(f'{name} lens', outline, .05, role, rise=.1)
    sweep(f'{name} bezel', [(*p, 0) for p in outline], [(-.035, 0), (-.035, .08), (0, .11), (.035, .08), (.035, 0)], 'accent', closed=True, sharp=70)


# Unit half length along +x: the concept's lit pair, a red arrow above an amber one pointing away.
asset('arrow-stack', next_slot())
lens_triangle('Upper', .44, .52, 1, 'sling_lens')
lens_triangle('Lower', -.44, .52, -1, 'amber_lens')

# Unit half length along +x, half as wide: a bright bracket plate holding a lamp, and two bolts.
asset('mech-bracket', next_slot())
plate = [(-1, -.32), (.1, -.46), (1, -.2), (1, .2), (.2, .46), (-1, .32)]
plate = [q for a, b in zip(plate, plate[1:] + plate[:1]) for q in ((a[0] * .86 + b[0] * .14, a[1] * .86 + b[1] * .14), (a[0] * .14 + b[0] * .86, a[1] * .14 + b[1] * .86))]
faceted_lens('Plate', plate, .05, 'metal', rise=.09)
sweep('Plate rim', [(*p, 0) for p in plate], [(-.03, 0), (-.03, .06), (0, .09), (.03, .06), (.03, 0)], 'accent', closed=True, sharp=70)
lathe('Lamp seat', [(.3, .1), (.3, .16), (.25, .2)], 'accent', 24, (.1, 0), sharp=70)
lathe('Lamp', [(.25, .17), (.21, .27), (.11, .34), (.001, .36)], 'glow', 20, (.1, 0), sharp=80)
bolt('Bolt a', .13, .12, (-.72, 0))
bolt('Bolt b', .1, .12, (.76, 0))

# Unit half length along +x, a third as wide: a brass cylinder driving a polished rod.
asset('mech-piston', next_slot())
r = .3
round_top = [(r * math.cos(a), r * .9 * math.sin(a) + .02) for a in (math.pi - i * math.pi / 8 for i in range(9))][::-1]
round_top = [(-x, z) for x, z in round_top]
sweep('Cylinder', [(-.95, 0, 0), (-.1, 0, 0)], [(x, z) for x, z in round_top], 'accent', sharp=80)
sweep('Rod', [(-.1, 0, 0), (.82, 0, 0)], [(x * .33, z * .36 + .05) for x, z in round_top], 'metal', sharp=80)
for x in (-.95, -.62, -.28, -.1):
    sweep(f'Collar {x}', [(x - .035, 0, 0), (x + .035, 0, 0)], [(p[0] * 1.14, p[1] * 1.14) for p in round_top], 'metal' if x in (-.95, -.1) else 'accent', sharp=80)
lathe('Eye', [(.2, 0), (.2, .14), (.15, .2), (.07, .22)], 'accent', 16, (.84, 0), sharp=70)
bolt('Eye pin', .09, .19, (.84, 0))

# Unit radius, standing clear of the table like a post: a brass stud, and one topped with a lamp.
asset('mech-stud', next_slot())
lathe('Foot', [(1.0, 0), (1.0, .32), (.8, .55), (.62, .62)], 'accent', 18, sharp=70)
lathe('Stem', [(.62, .55), (.62, 2.2), (.86, 2.45), (.86, 2.8), (.62, 3.05)], 'accent', 18, sharp=70)
lathe('Polished dome', [(.62, 3.0), (.56, 3.45), (.32, 3.82), (.001, 3.95)], 'metal', 18, sharp=80)
asset('mech-tower', next_slot())
lathe('Foot', [(1.0, 0), (1.0, .32), (.8, .55), (.7, .62)], 'accent', 18, sharp=70)
lathe('Holder', [(.7, .55), (.7, 2.0), (.92, 2.25), (.92, 2.55), (.74, 2.7)], 'accent', 18, sharp=70)
lathe('Lamp', [(.74, 2.6), (.72, 3.1), (.56, 3.6), (.3, 3.92), (.001, 4.0)], 'glow', 18, sharp=80)


for table_index, table in enumerate(TABLES):
    SIZE = table['size']
    # Unit length from the pivot along +x, in the proportions of the table's flipper.
    asset(f"{table['id']}-flipper", next_slot())
    flipper_def = table['flippers'][0]
    rb, rt, height = flipper_def['baseRadius'] / flipper_def['length'], flipper_def['tipRadius'] / flipper_def['length'], .253
    stations = [-rb + rb * (1 - math.cos(i * math.pi / 12)) for i in range(7)] + [i * .1 for i in range(1, 10)] + \
               [1 + rt * math.sin(i * math.pi / 12) for i in range(7)]


    def half_width(x):
        if x <= 0:
            return math.sqrt(max(rb * rb - x * x, 0))
        if x >= 1:
            return math.sqrt(max(rt * rt - (x - 1) * (x - 1), 0))
        return rb + (rt - rb) * x


    # From the drawing: an ivory bat in a broad black rubber edge, with a lit inset and a brass pivot.
    across = [-1, -.97, -.92, -.84, -.8, -.45, 0, .45, .8, .84, .92, .97, 1]
    rise = [.0, .62, .95, .88, .9, .98, 1, .98, .9, .88, .95, .62, .0]
    vertices, uvs, faces = [], [], []
    for x in stations:
        hw = max(half_width(x), .001)
        for c, r in zip(across, rise):
            vertices.append((x, c * hw, .03 + (height - .03) * r))
            # The art's plain enamel band, above its stripes.
            uvs.append(((x + rb) / (1 + rb + rt), .865 + c * .085))
    m = len(across)
    for i in range(len(stations) - 1):
        for j in range(m - 1):
            faces.append((i * m + j, (i + 1) * m + j, (i + 1) * m + j + 1, i * m + j + 1))
    solid('Enamel bat', vertices, [f for f in faces if f[0] % m in range(4, m - 5)], 'flipper_art', uvs, 80)
    solid('Brass trim', vertices, [f for f in faces if f[0] % m in (3, m - 5)], 'accent', uvs, 80)
    solid('Rubber edge', vertices, [f for f in faces if f[0] % m in (0, 1, 2, m - 4, m - 3, m - 2)], 'black_rubber', uvs, 80)
    lathe('Pivot collar', [(rb * .95, 0), (rb * .95, height + .02), (rb * .82, height + .045), (rb * .55, height + .05)], 'accent', 28, sharp=70)
    lathe('Pivot cap', [(rb * .58, height + .04), (rb * .46, height + .08), (rb * .22, height + .1), (.001, height + .105)], 'metal', 20, sharp=80)
    inset = [(.38, .0), (.22, -.05), (.22, .05)]
    prism_top('Lit inset', inset, height + .003, 'sling_lens')
    sweep('Inset frame', [(*p, height) for p in inset[::-1]], [(-.006, 0), (-.006, .007), (.006, .007), (.006, 0)], 'accent', closed=True, sharp=70)
    bolt('Tip bolt', rt * .42, height - .01, (1, 0))

    # Every wall is a thin polished line. The concept has no heavy rails, and no fasteners on them.
    asset(f"{table['id']}-walls", (table_index * 3, -3, 0))
    r = .0032
    for wall in table['walls']:
        if wall['style'] not in ('wall', 'rail', 'rubber'):
            continue
        path = table_path(wall['points'])
        h = wall['height']
        sweep(wall['id'], [(*centred(*p), 0) for p in path],
              [(-r, 0), (-r, h - r * .9), (-r * .7, h - r * .3), (0, h), (r * .7, h - r * .3), (r, h - r * .9), (r, 0)], 'accent', sharp=80)
        for k, end in enumerate((path[0], path[-1])):
            lathe(f"{wall['id']} end {k}", [(r, 0), (r, h - r * .5), (r * .7, h + r * .2), (.0001, h + r * .4)], 'accent', 12, centred(*end), sharp=80)

    # The dead corners below the inlanes: a domed kite-shaped guard on a thin foot rail.
    # The table mirrors about the point midway between the flippers.
    # Coordinates are relative to the left flipper's pivot, plus the (.3, .345) they were measured from.
    pivot = table['flippers'][0]['pivot']
    MIRROR = pivot[0] + table['flippers'][1]['pivot'][0]
    for side, mirror in (('L', lambda x: x + pivot[0] - .3), ('R', lambda x: MIRROR - (x + pivot[0] - .3))):
        rise = pivot[1] - .345
        kite = [(.112, .352), (.158, .392), (.226, .362), (.238, .315), (.178, .272), (.118, .292)]
        # Soften each corner, keeping the straight edges of the concept's plate.
        kite = [q for a, b in zip(kite, kite[1:] + kite[:1]) for q in ((a[0] * .86 + b[0] * .14, a[1] * .86 + b[1] * .14), (a[0] * .14 + b[0] * .86, a[1] * .14 + b[1] * .86))]
        outline = [centred(mirror(x), y + rise) for x, y in kite]
        if sum(outline[i][0] * outline[(i + 1) % len(outline)][1] - outline[(i + 1) % len(outline)][0] * outline[i][1] for i in range(len(outline))) < 0:
            outline = outline[::-1]
        faceted_lens(f'Guard {side} plate', outline, .004, 'accent', rise=.006)
        sweep(f'Guard {side} rim', [(*p, 0) for p in outline], [(-.0016, 0), (-.0016, .0048), (0, .006), (.0016, .0048)], 'metal', closed=True, sharp=80)
        bolt(f'Guard {side} bolt', .0095, .009, centred(mirror(.172), .33 + rise))
        foot = [(.098, .278), (.112, .26), (.262, .26)]
        sweep(f'Foot rail {side}', [(*centred(mirror(x), y + rise), 0) for x, y in foot], [(-.002, 0), (-.002, .004), (0, .0052), (.002, .004), (.002, 0)], 'accent', sharp=80)

    asset(f"{table['id']}-plastics", (table_index * 3, -6, 0))
    plastic_shapes = [(p['id'], table_path(p['points']), p['height'], 'sling_lens') for p in table['plastics']]
    plastic_shapes += [(w['id'], table_path(w['points']), 0, 'block_art') for w in table['walls'] if w['style'] == 'plastic']
    for name, path, base, art in plastic_shapes:
        wall_height = next((w['height'] for w in table['walls'] if w['id'] == name), .006)
        top = base + wall_height
        outline = [centred(*p) for p in path]
        if sum(outline[i][0] * outline[(i + 1) % len(outline)][1] - outline[(i + 1) % len(outline)][0] * outline[i][1]
               for i in range(len(outline))) < 0:
            outline = outline[::-1]
        if art == 'sling_lens':
            # From the drawing: black bands between three brass posts, around a framed lit panel.
            middle = Vector((sum(p[0] for p in outline) / len(outline), sum(p[1] for p in outline) / len(outline)))
            panel = [tuple(middle + (Vector(p) - middle) * .62) for p in outline]
            faceted_lens(f'{name} panel', panel, .008, art, rise=.004)
            sweep(f'{name} panel frame', [(*p, 0) for p in panel], [(-.0022, 0), (-.0022, .009), (0, .0105), (.0022, .009), (.0022, 0)], 'accent', closed=True, sharp=70)
            for a, b in zip(outline, outline[1:] + outline[:1]):
                sweep(f'{name} band {a[0]:.3f}', [(a[0], a[1], 0), (b[0], b[1], 0)], [(-.0048, .003), (-.0048, .013), (-.0028, .0185), (.0028, .0185), (.0048, .013), (.0048, .003)], 'black_rubber', sharp=80)
            for k, p in enumerate(outline):
                lathe(f'{name} post {k}', [(.0088, 0), (.0088, .004), (.0066, .007), (.0066, .019), (.0056, .022)], 'accent', 18, tuple(p), sharp=70)
                bolt(f'{name} post cap {k}', .0056, .021, tuple(p))
            continue
        prism_top(f'{name} art', outline, top, art)
        # Outline is counter-clockwise, so "left of travel" is inward.
        sweep(f'{name} frame', [(*p, base) for p in outline], [(-.0024, 0), (-.0024, wall_height + .002), (-.0008, wall_height + .0032), (.0008, wall_height + .0032), (.0024, wall_height + .002), (.0024, 0)], 'accent', closed=True, sharp=80)

    # From the construction drawing: a flat channel floor between channel walls, broad brass side
    # rails, a retaining rail held above them, clamps across the rails, and mounting brackets.
    # The floor's lowest line follows the physics surface exactly.
    for ramp in table['ramps']:
        asset(f"{table['id']}-{ramp['id']}", (table_index * 3, 3, 0))
        path = [Vector((*centred(p.x, p.y), p.z)) for p in smooth_path(ramp['points'])]
        half = ramp['width'] * .5 + .002
        wall = .022
        rail = .0118

        def normal_at(i):
            tangent = (path[min(i + 1, len(path) - 1)] - path[max(i - 1, 0)]).xy.normalized()
            return Vector((-tangent.y, tangent.x))
        stops = (-1, -.8, -.6, -.4, -.2, 0, .2, .4, .6, .8, 1)
        floor = [(u * half, .009 * u * u) for u in stops]
        sweep('Channel floor', path, [(-half, wall)] + floor + [(half, wall)], 'ramp_floor', sharp=80)
        for u in (-.5, .5):
            z = .009 * u * u
            sweep(f'Floor line {u}', path, [(u * half - .0007, z + .0003), (u * half, z + .001), (u * half + .0007, z + .0003)], 'accent', sharp=89)
        for side in (-1, 1):
            # The side rail, crowned so its top sweeps the MatCap's streaks along every bend.
            # Broad enough to read as the concept's heavy rail: it overhangs the floor's unused edge.
            over = .009
            crown = [(-over, wall - .005), (-over + .0012, wall - .001), (-over + (rail + over) * .25, wall + .0016), (-over + (rail + over) * .5, wall + .0028), (-over + (rail + over) * .75, wall + .0016), (rail - .0012, wall - .001), (rail, wall - .004), (rail, -.002)]
            section = [(side * (half + x), z) for x, z in crown]
            # Sections run toward the left of travel, or their faces point inward and get culled.
            sweep(f'Side rail {side}', path, section if side > 0 else section[::-1], 'accent', sharp=70)
            # Retaining rail: a fine wire on standoffs, held above the side rail.
            lift = .0145
            o = side * (half + rail * .5)
            sweep(f'Retaining rail {side}', path, [(o + .0013 * math.cos(a), wall + lift + .0013 * math.sin(a)) for a in (math.pi + i * math.pi * 2 / 8 for i in range(9))], 'metal', sharp=89)
            for i in range(4, len(path) - 2, 9):
                cylinder(f'Standoff {i} {side}', .0012, path[i].z + wall, path[i].z + wall + lift, 'metal', tuple(path[i].xy + normal_at(i) * o), 6, 0)
        # Clamps across each rail, one small bolt each.
        for i in range(7, len(path) - 4, 14):
            a, b = path[i], path[i + 1]
            end = a + (b - a).normalized() * .009
            for side in (-1, 1):
                section = [(side * (half - .001), wall + .001), (side * (half - .001), wall + .0042), (side * (half + rail + .001), wall + .0042), (side * (half + rail + .001), -.001)]
                sweep(f'Clamp {i} {side}', [a, end], section if side > 0 else section[::-1], 'accent', sharp=30)
                bolt(f'Clamp bolt {i} {side}', .0026, a.z + wall + .0036, tuple((a.xy + end.xy) * .5 + normal_at(i) * side * (half + rail * .5)))
        # Lit inserts set into the outer rails, as on the track reference.
        for i in range(16, len(path) - 8, 24):
            tangent = (path[i + 1] - path[i]).xy.normalized()
            for side in (-1, 1):
                normal = normal_at(i)
                c = path[i].xy + normal * side * (half + rail * .5)
                c = path[i].xy + normal * side * (half + (rail - .009) * .5)
                corners = [c + tangent * .015, c - tangent * .01 + normal * .0072, c - tangent * .01 - normal * .0072]
                prism_top(f'Rail insert {i} {side}', [tuple(q) for q in corners], path[i].z + wall + .0034, 'sling_lens')
        # Square ends, as the track's open section.
        for index, step in ((0, 1), (len(path) - 1, -1)):
            a, b = path[index], path[index + step]
            end = a + (b - a).normalized() * .007
            section = [(-half - rail - .001, -.001), (-half - rail - .001, wall + .004), (half + rail + .001, wall + .004), (half + rail + .001, -.001)]
            sweep(f'End band {index}', [a, end] if step > 0 else [end, a], [(-half - rail - .001, wall - .004), (-half - rail - .001, wall + .004), (-half + .001, wall + .004), (-half + .001, wall - .004)], 'accent', sharp=30)
            sweep(f'End band r {index}', [a, end] if step > 0 else [end, a], [(half - .001, wall - .004), (half - .001, wall + .004), (half + rail + .001, wall + .004), (half + rail + .001, wall - .004)][::-1], 'accent', sharp=30)
        # Mounting brackets: a leg down to a bolted foot, wherever the track runs high.
        for i in range(12, len(path) - 8, 12):
            if path[i].z < .05:
                continue
            for side in (-1, 1):
                spot = path[i].xy + normal_at(i) * side * (half + rail * .5)
                cylinder(f'Leg {i} {side}', .0036, 0, path[i].z, 'accent', tuple(spot), 10, .0005)
                lathe(f'Foot {i} {side}', [(.0062, 0), (.0062, .0025), (.0042, .004)], 'accent', 14, tuple(spot), sharp=70)


# ------------------------------------------------------------------------------------ Export

# Standard COLLADA with Y-up coordinates, explicit normals, UVs, and semantic materials.
# A tiny custom exporter avoids a new dependency after Blender removed its legacy DAE exporter.
# Each asset becomes one mesh per material role, so an instance costs a few draw calls.
NS = 'http://www.collada.org/2005/11/COLLADASchema'


def child(parent, tag, attributes=None, text=None):
    e = SubElement(parent, tag, attributes or {})
    if text is not None:
        e.text = text
    return e


def floats(values):
    return ' '.join(format(v, '.6g') for v in values)


def export(name, root, objects):
    deps = bpy.context.evaluated_depsgraph_get()
    grouped = {}
    triangle_count = 0
    reach = 0.0
    inverse = root.matrix_world.inverted()
    for obj in objects:
        evaluated = obj.evaluated_get(deps)
        mesh = evaluated.to_mesh()
        mesh.calc_loop_triangles()
        transform = inverse @ obj.matrix_world
        normal_matrix = transform.to_3x3().inverted().transposed()
        role = obj['surface_role']
        group = grouped.setdefault(role, {'positions': [], 'normals': [], 'uvs': [], 'lookup': {}, 'indices': []})
        uv = mesh.uv_layers.active
        for triangle in mesh.loop_triangles:
            for loop in triangle.loops:
                vertex = mesh.loops[loop].vertex_index
                p = transform @ mesh.vertices[vertex].co
                normal = (normal_matrix @ mesh.corner_normals[loop].vector).normalized()
                t = uv.data[loop].uv if uv else (0, 0)
                key = (round(p.x, 6), round(p.z, 6), round(-p.y, 6), round(normal.x, 3), round(normal.z, 3), round(-normal.y, 3), round(t[0], 4), round(t[1], 4))
                index = group['lookup'].get(key)
                if index is None:
                    index = len(group['positions']) // 3
                    group['lookup'][key] = index
                    group['positions'].extend(key[:3])
                    group['normals'].extend(key[3:6])
                    group['uvs'].extend(key[6:])
                group['indices'].append(index)
                reach = max(reach, math.hypot(p.x, p.y))
            triangle_count += 1
        evaluated.to_mesh_clear()

    doc = Element('COLLADA', {'xmlns': NS, 'version': '1.4.1'})
    meta = child(doc, 'asset')
    child(meta, 'contributor')
    child(meta, 'created', text='2026-11-01T00:00:00Z')
    child(meta, 'modified', text='2026-11-01T00:00:00Z')
    child(meta, 'unit', {'name': 'meter', 'meter': '1'})
    child(meta, 'up_axis', text='Y_UP')
    effects = child(doc, 'library_effects')
    mats = child(doc, 'library_materials')
    for role in grouped:
        effect = child(effects, 'effect', {'id': role + '-fx'})
        tech = child(child(effect, 'profile_COMMON'), 'technique', {'sid': 'common'})
        child(child(child(tech, 'lambert'), 'diffuse'), 'color', text=floats(ROLES[role]))
        material = child(mats, 'material', {'id': role + '-mat', 'name': role})
        child(material, 'instance_effect', {'url': '#' + role + '-fx'})
    geometries = child(doc, 'library_geometries')
    vscene = child(child(doc, 'library_visual_scenes'), 'visual_scene', {'id': 'Scene', 'name': name})
    for number, (role, group) in enumerate(grouped.items()):
        gid = f'mesh{number}'
        data = child(child(geometries, 'geometry', {'id': gid, 'name': role}), 'mesh')
        for suffix, values, stride, axes in [('pos', group['positions'], 3, 'XYZ'), ('norm', group['normals'], 3, 'XYZ'), ('uv', group['uvs'], 2, 'ST')]:
            source = child(data, 'source', {'id': gid + '-' + suffix})
            aid = gid + '-' + suffix + '-array'
            child(source, 'float_array', {'id': aid, 'count': str(len(values))}, floats(values))
            accessor = child(child(source, 'technique_common'), 'accessor', {'source': '#' + aid, 'count': str(len(values) // stride), 'stride': str(stride)})
            for axis in axes:
                child(accessor, 'param', {'name': axis, 'type': 'float'})
        child(child(data, 'vertices', {'id': gid + '-verts'}), 'input', {'semantic': 'POSITION', 'source': '#' + gid + '-pos'})
        triangles = child(data, 'triangles', {'material': role, 'count': str(len(group['indices']) // 3)})
        for semantic, suffix, offset in [('VERTEX', 'verts', 0), ('NORMAL', 'norm', 1), ('TEXCOORD', 'uv', 2)]:
            attr = {'semantic': semantic, 'source': '#' + gid + '-' + suffix, 'offset': str(offset)}
            if semantic == 'TEXCOORD':
                attr['set'] = '0'
            child(triangles, 'input', attr)
        child(triangles, 'p', text=' '.join(f'{i} {i} {i}' for i in group['indices']))
        node = child(vscene, 'node', {'id': gid + '-node', 'name': role, 'type': 'NODE'})
        instance = child(node, 'instance_geometry', {'url': '#' + gid})
        binding = child(child(instance, 'bind_material'), 'technique_common')
        child(binding, 'instance_material', {'symbol': role, 'target': '#' + role + '-mat'})
    child(child(doc, 'scene'), 'instance_visual_scene', {'url': '#Scene'})
    ElementTree(doc).write(OUT / (name + '.dae'), encoding='utf-8', xml_declaration=True)
    return {'objects': len(objects), 'triangles': triangle_count, 'radius': round(reach, 4), 'bytes': (OUT / (name + '.dae')).stat().st_size}


bpy.context.view_layer.update()
stale = {p.stem for p in OUT.glob('*.dae')} - set(assets)
for name in stale:
    (OUT / (name + '.dae')).unlink()
stats = {name: export(name, *value) for name, value in assets.items()}
# This is an isolated session; discard orphaned earlier generator revisions before packing.
bpy.data.orphans_purge(do_recursive=True)
bpy.ops.file.pack_all()
bpy.ops.wm.save_as_mainfile(filepath=str(ROOT / 'Art/Models/premium-hardware.blend'), compress=True)
(ROOT / 'Art/Models/manifest.json').write_text(json.dumps({'generator': 'tools/build_hardware_models.py', 'transport': 'Blender MCP', 'assets': stats}, indent=2) + '\n')
result = {'master': 'Art/Models/premium-hardware.blend', 'assets': stats, 'removed': sorted(stale), 'blender': bpy.app.version_string}
