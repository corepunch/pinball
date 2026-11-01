"""Editable Blender hardware master and SceneKit-ready COLLADA, executed via Blender MCP.

No downloads, simulation caches or external Python packages. Round kit parts are built to
unit radius and scaled by the table; elongated decor to unit half length. Table-specific
assets (ramps, wall plates, plastics, display frame) use the JSON's coordinates, so they
follow the physics exactly: rebuild after moving walls or ramps.
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
    'rubber': (.62, .58, .47, 1), 'flipper_rubber': (.5, .1, .06, 1), 'cap_art': (.7, .2, .12, 1),
    'glass': (.16, .42, .42, .5), 'lens': (.9, .95, 1, .18), 'glow': (.2, .8, 1, 1),
    'wall_art': (.05, .12, .14, 1), 'plastic_art': (.1, .2, .3, 1), 'block_art': (.05, .18, .18, 1),
    'flipper_art': (.9, .85, .7, 1), 'target_art': (.6, .3, .15, 1),
}
ATLAS_SLOTS = {'cap_art': 'bumper_cap', 'wall_art': 'wall_top', 'plastic_art': 'slingshot', 'block_art': 'plastic',
               'flipper_art': 'flipper', 'target_art': 'drop_target'}
METALLIC = ('metal', 'accent')
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
    bsdf.inputs['Roughness'].default_value = .28 if role in METALLIC else .38
    if role in ATLAS_SLOTS:
        uv, mapping, texture = nodes.new('ShaderNodeTexCoord'), nodes.new('ShaderNodeMapping'), nodes.new('ShaderNodeTexImage')
        texture.image = atlas
        x, y, w, h = palette['atlasLayout']['slots'][ATLAS_SLOTS[role]]['rect']
        mapping.inputs['Location'].default_value = (x / 1254, 1 - (y + h) / 1254, 0)
        mapping.inputs['Scale'].default_value = (w / 1254, h / 1254, 1)
        links.new(uv.outputs['UV'], mapping.inputs['Vector'])
        links.new(mapping.outputs['Vector'], texture.inputs['Vector'])
        links.new(texture.outputs['Color'], bsdf.inputs['Base Color'])
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


def rivet(name, radius, z, role='metal', xy=(0, 0), segments=10):
    return lathe(name, [(radius, z), (radius * .9, z + radius * .35), (radius * .55, z + radius * .68), (.0001, z + radius * .82)],
                 role, segments, xy, sharp=70)


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


asset('bumper-base', next_slot())
lathe('Stepped foot flange', [(1.12, 0), (1.12, .05), (1.08, .085), (1.0, .10), (.96, .14)], 'accent', 64)
for i in range(32):
    a = 2 * math.pi * i / 32
    rivet(f'Flange rivet {i:02}', .018, .085, 'metal', (1.05 * math.cos(a), 1.05 * math.sin(a)), 8)
lathe('Impact cushion', [(.99, .13), (1.0, .17), (.99, .24), (.93, .26)], 'rubber', 64, sharp=80)
lathe('Lamp gallery', [(.99, .24), (.97, .29), (.86, .33), (.80, .46), (.80, .55)], 'dark', 64)
for i in range(12):
    a = 2 * math.pi * (i + .5) / 12
    x, y = .905 * math.cos(a), .905 * math.sin(a)
    # A jewel set into the gallery, outside the cap so it shows from above; lit by the skin's bumper colour.
    lathe(f'Jewel seat {i:02}', [(.082, .30), (.082, .335), (.066, .35)], 'accent', 14, (x, y))
    lathe(f'Gallery jewel {i:02}', [(.066, .34), (.066, .37), (.044, .415), (.001, .435)], 'glow', 14, (x, y), sharp=80)
ring('Upper rolled lip', .81, .03, .58, 'accent', segments=64)

asset('bumper-cap', next_slot())
lathe('Enamel crown • atlas surface', [(.80, .60), (.80, .70), (.78, .79), (.70, .90), (.52, 1.0), (.36, 1.055), (.31, 1.065)], 'cap_art', 72, planar=1.62, sharp=80)
ring('Outer machined lip', .80, .03, .695, 'accent', segments=72)
ring('Inner concentric fillet', .335, .026, 1.07, 'accent', segments=48)
lathe('Jewel bezel', [(.32, 1.05), (.32, 1.11), (.275, 1.16)], 'accent', 48)
ring('Jewel seat', .272, .018, 1.155, 'metal', segments=48)
lathe('Raised jewel • authored atlas centre', [(.262, 1.15), (.24, 1.215), (.17, 1.275), (.09, 1.31), (.001, 1.32)], 'cap_art', 40, planar=1.62, sharp=80)

asset('insert-bezel', next_slot())
lathe('Recessed socket', [(1.08, -.02), (1.10, .01), (1.06, .05), (1.0, .055)], 'dark', 40)
ring('Bevelled bezel', 1.04, .04, .055, 'accent', segments=40, sides=6)
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
w = .055
sweep('Triangular bezel', triangle, [(-w, -.02), (-w, .06), (-w * .3, .10), (w * .3, .10), (w, .06), (w, -.02)], 'accent', closed=True)
sweep('Triangular socket', triangle, [(w, -.02), (w, .01), (w * 2.1, .012), (w * 2.1, -.02)], 'dark', closed=True)
inner = [(p[0] * .93, p[1] * .93) for p in triangle]
apex = len(inner)
vertices = [(p[0], p[1], .05) for p in inner] + [(p[0] * .62, p[1] * .62, .2) for p in inner] + [(0, 0, .26)]
faces = []
for i in range(apex):
    j = (i + 1) % apex
    faces.append((i, j, j + apex, i + apex))
    faces.append((i + apex, j + apex, apex * 2))
solid('Faceted lens', vertices, faces, 'lens', sharp=80)

asset('post', next_slot())
cylinder('Stem', .55, 0, 3.0, 'metal', segments=14)
lathe('Rubber sleeve', [(.72, 1.1), (1.0, 1.35), (1.0, 2.0), (.72, 2.25)], 'rubber', 20, sharp=80)
lathe('Domed cap', [(.72, 3.0), (.72, 3.25), (.6, 3.55), (.34, 3.8), (.001, 3.92)], 'accent', 18, sharp=80)
rivet('Cap screw', .26, 3.86, 'metal')

# Unit length from the pivot along +x, in the proportions of the table's flipper.
asset('flipper', next_slot())
flipper_def = json.loads((ROOT / 'GameData/Tables/aurora.json').read_text())['flippers'][0]
rb, rt, height = flipper_def['baseRadius'] / flipper_def['length'], flipper_def['tipRadius'] / flipper_def['length'], .253
stations = [-rb + rb * (1 - math.cos(i * math.pi / 12)) for i in range(7)] + [i * .1 for i in range(1, 10)] + \
           [1 + rt * math.sin(i * math.pi / 12) for i in range(7)]


def half_width(x):
    if x <= 0:
        return math.sqrt(max(rb * rb - x * x, 0))
    if x >= 1:
        return math.sqrt(max(rt * rt - (x - 1) * (x - 1), 0))
    return rb + (rt - rb) * x


across = [-1, -.98, -.76, -.45, 0, .45, .76, .98, 1]
rise = [.0, .62, .92, .985, 1, .985, .92, .62, .0]
vertices, uvs, faces = [], [], []
for x in stations:
    hw = max(half_width(x), .001)
    for c, r in zip(across, rise):
        vertices.append((x, c * hw, .03 + (height - .03) * r))
        uvs.append(((x + rb) / (1 + rb + rt), .5 + c * .5))
m = len(across)
for i in range(len(stations) - 1):
    for j in range(m - 1):
        faces.append((i * m + j, (i + 1) * m + j, (i + 1) * m + j + 1, i * m + j + 1))
top = [f for f in faces if f[0] % m in range(2, m - 3)]
solid('Enamel bat • atlas surface', vertices, top, 'flipper_art', uvs, 80)
solid('Rubber edge', vertices, [f for f in faces if f[0] % m in (0, 1, m - 3, m - 2)], 'flipper_rubber', uvs, 80)
lathe('Pivot collar', [(rb * .72, height), (rb * .72, height + .03), (rb * .58, height + .065)], 'accent', 24)
lathe('Pivot cap', [(rb * .58, height + .06), (rb * .42, height + .09), (rb * .2, height + .105), (.001, height + .11)], 'metal', 20, sharp=80)

# Unit width and height. Seen from straight above, so the art goes on a broad bevelled top.
asset('target', next_slot())
d, t = .17, 1.0
face = [(-.5, -d), (.5, -d), (.5, d), (-.5, d)]
solid('Target art', [(x, y, t) for x, y in face], [(0, 1, 2, 3)], 'target_art', [(0, 0), (1, 0), (1, 1), (0, 1)], 90)
sweep('Target frame', [(x * 1.06, y * 1.12, 0) for x, y in face],
      [(-.05, 0), (-.05, t - .06), (-.02, t), (.03, t)], 'accent', closed=True, sharp=30)

asset('flasher-cage', next_slot())
lathe('Foot ring', [(1.05, 0), (1.05, .1), (.92, .22)], 'accent', 32)
for i in range(6):
    a = 2 * math.pi * i / 6
    bar = [(math.cos(a) * r, math.sin(a) * r, z) for r, z in ((.95, .15), (.92, .55), (.74, 1.0), (.42, 1.34), (.1, 1.52))]
    sweep(f'Cage bar {i}', bar, [(-.085, 0), (-.085, .07), (.085, .07), (.085, 0)], 'accent', sharp=80)
lathe('Finial', [(.14, 1.48), (.14, 1.56), (.06, 1.66), (.001, 1.7)], 'metal', 12, sharp=80)

asset('gear', next_slot())
teeth = 14
outline = []
for i in range(teeth):
    for r, off in ((.8, -.27), (1.0, -.14), (1.0, .14), (.8, .27)):
        a = (i + off + .0) * 2 * math.pi / teeth
        outline.append((r * math.cos(a), r * math.sin(a), 0))
sweep('Gear teeth', outline, [(-.02, 0), (-.02, .08), (.02, .13), (.32, .13)], 'accent', closed=True, sharp=30)
prism_top('Gear web', [(p[0] * .7, p[1] * .7) for p in outline], .12, 'wall_art')
for i in range(6):
    a = 2 * math.pi * i / 6
    cylinder(f'Lightening hole {i}', .13, .1, .125, 'dark', (.46 * math.cos(a), .46 * math.sin(a)), 14, .01)
lathe('Hub', [(.26, .12), (.24, .24), (.15, .28), (.001, .29)], 'metal', 20)

asset('medallion', next_slot())
lathe('Dished plate', [(1.0, 0), (1.0, .08), (.92, .12), (.82, .07), (.001, .07)], 'accent', 48)
star = []
for i in range(16):
    r = (.76 if i % 4 == 0 else .3) if i % 2 == 0 else .17
    a = i * math.pi / 8
    star.append((r * math.cos(a), r * math.sin(a)))
prism_top('Compass star', star, .1, 'metal')
for i in range(8):
    a = 2 * math.pi * i / 8
    rivet(f'Rim rivet {i}', .05, .1, 'metal', (.92 * math.cos(a), .92 * math.sin(a)), 8)

# Elongated parts: unit half length along +x.
asset('piston', next_slot())
aspect = .3
for x0, x1, r, role in ((-1, -.25, aspect * .92, 'accent'), (-.25, .95, aspect * .35, 'metal')):
    profile = [(r * .8, 0), (r, r * .25), (r, r * .75), (r * .8, r)]
    steps = [x0 + (x1 - x0) * i / 6 for i in range(7)]
    sweep(f'Barrel {x0}', [(x, 0, 0) for x in steps],
          [(-r * .95, .0), (-r, .35 * r), (-r * .55, .9 * r), (0, 1.1 * r), (r * .55, .9 * r), (r, .35 * r), (r * .95, 0)], role, sharp=80)
for x in (-.9, -.35):
    sweep(f'Collar {x}', [(x, 0, 0), (x + .07, 0, 0)],
          [(-aspect, 0), (-aspect, .42 * aspect), (-aspect * .55, aspect), (0, 1.2 * aspect), (aspect * .55, aspect), (aspect, .42 * aspect), (aspect, 0)], 'metal', sharp=80)
rivet('Rod end', aspect * .42, .03, 'accent', (.95, 0))

asset('bracket', next_slot())
aspect = .3
outline = [(-1, -aspect), (1, -aspect * .6), (1, aspect * .6), (-1, aspect)]
rounded = [(x, y, 0) for x, y in outline]
sweep('Bracket edge', rounded, [(-.04, 0), (-.04, .07), (.02, .1)], 'accent', closed=True, sharp=30)
prism_top('Bracket plate', [(x * .97, y * .92) for x, y in outline], .095, 'wall_art')
for x in (-.82, 0, .82):
    rivet(f'Bracket rivet {x}', aspect * .32, .09, 'metal', (x, 0))



# --------------------------------------------------------------------------- Table-specific

table = json.loads((ROOT / 'GameData/Tables/aurora.json').read_text())
SIZE = table['size']


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


def rivets_along(prefix, path, spacing, z, radius, offset=0.0, role='metal'):
    travelled = spacing * .5
    for i in range(len(path) - 1):
        a, b = Vector(path[i]), Vector(path[i + 1])
        length = (b - a).length
        if length < 1e-5:
            continue
        direction = (b - a) / length
        normal = Vector((-direction.y, direction.x))
        while travelled < length:
            point = a + direction * travelled + normal * offset
            x, y = centred(point.x, point.y)
            rivet(f'{prefix} {i} {travelled:.3f}', radius, z, role, (x, y))
            travelled += spacing
        travelled -= length


# Guide plates: broad enough to read as machined metal, like the concept's bolted rails.
asset(f"{table['id']}-walls", (0, -3, 0))
for wall in table['walls']:
    if wall['style'] not in ('wall', 'rail'):
        continue
    path = table_path(wall['points'])
    points = [(*centred(*p), 0) for p in path]
    half = wall['radius'] + .004
    h = wall['height']
    bevel = min(half * .28, .003)
    inlay = half * .52
    section = [(-half, 0), (-half, h - bevel), (-half + bevel, h), (-inlay, h), (inlay, h), (half - bevel, h), (half, h - bevel), (half, 0)]
    top_role = 'accent' if wall['style'] == 'rail' else 'wall_art'
    sweep(wall['id'], points, section, 'accent', band_roles=['accent', 'accent', 'accent', top_role, 'accent', 'accent', 'accent'], uv_scale=4)
    if wall['style'] == 'rail' or h >= .07:
        rivets_along(f"{wall['id']} rivet", path, .07 if wall['id'] != 'outer' else .1, h - .0004, .0032)

asset(f"{table['id']}-plastics", (0, -6, 0))
plastic_shapes = [(p['id'], table_path(p['points']), p['height'], 'plastic_art') for p in table['plastics']]
plastic_shapes += [(w['id'], table_path(w['points']), 0, 'block_art') for w in table['walls'] if w['style'] == 'plastic']
for name, path, base, art in plastic_shapes:
    wall_height = next((w['height'] for w in table['walls'] if w['id'] == name), .006)
    top = base + wall_height
    outline = [centred(*p) for p in path]
    if sum(outline[i][0] * outline[(i + 1) % len(outline)][1] - outline[(i + 1) % len(outline)][0] * outline[i][1]
           for i in range(len(outline))) < 0:
        outline = outline[::-1]
    prism_top(f'{name} art', outline, top, art)
    frame = [(*p, base) for p in outline]
    # Outline is counter-clockwise, so "left of travel" is inward.
    sweep(f'{name} frame', frame, [(-.003, 0), (-.003, wall_height + .002), (.001, wall_height + .004), (.004, wall_height + .002), (.004, wall_height)],
          'accent', closed=True, sharp=30)
    centre = Vector((sum(p[0] for p in outline) / len(outline), sum(p[1] for p in outline) / len(outline)))
    for i, p in enumerate(outline):
        # Bolts sit just inside each corner, and hold raised plastics on standoffs.
        toward = (centre - Vector(p))
        spot = Vector(p) + toward * min(.016 / max(toward.length, .001), .3)
        rivet(f'{name} bolt {i}', .0042, top + .0015, 'metal', tuple(spot))
        if base > 0:
            cylinder(f'{name} standoff {i}', .004, 0, base, 'metal', tuple(spot), 10)

for ramp in table['ramps']:
    asset(f"{table['id']}-{ramp['id']}", (0, 3, 0))
    points = smooth_path(ramp['points'])
    half = ramp['width'] * .5 + .004
    path = [Vector((*centred(p.x, p.y), p.z)) for p in points]
    # Clear channel: the floor follows the physics surface exactly.
    wall = .024
    sweep('Clear channel', path, [(-half, wall), (-half, .003), (-half + .006, 0), (half - .006, 0), (half, .003), (half, wall)], 'glass', sharp=80)
    # Heavy rolled rims, the concept's strongest silhouette.
    for side in (-1, 1):
        o = side * (half + .001)
        r = .0082
        rim = [(o + r * math.cos(a), wall + r * math.sin(a)) for a in (math.pi + i * math.pi * 2 / 8 for i in range(9))]
        rim = rim if side < 0 else rim
        sweep(f'Rolled rim {side}', path, rim, 'accent', sharp=80)
        # A thin chrome hairline inside the brass.
        sweep(f'Hairline {side}', path, [(o - side * .0085, wall - .001), (o - side * .0085, wall + .0015), (o - side * .0065, wall + .0015)][::side], 'metal', sharp=80)
    # Clamp bands, each bolted through both rims.
    for i in range(5, len(path) - 3, 7):
        a, b = path[i], path[i + 1]
        wrap = [(-half - .009, wall - .007), (-half - .009, wall + .009), (-half + .006, wall + .009), (-half + .006, wall + .006),
                (-half - .003, wall + .006)]
        for side in (-1, 1):
            section = wrap if side < 0 else [(-x, z) for x, z in wrap][::-1]
            band = [a, a + (b - a) * .5, b]
            sweep(f'Clamp {i} {side}', band, section, 'accent', sharp=30)
        tangent = (b - a).xy.normalized()
        normal = Vector((-tangent.y, tangent.x))
        for side in (-1, 1):
            spot = a.xy + normal * side * (half + .0025)
            rivet(f'Clamp bolt {i} {side}', .0034, a.z + wall + .009, 'metal', tuple(spot))
    # Bolted flanges at the mouth and exit.
    for index, step in ((0, 1), (len(path) - 1, -1)):
        a, b = path[index], path[index + step]
        section = [(-half - .016, -.001), (-half - .016, wall + .004), (-half - .01, wall + .008), (half + .01, wall + .008), (half + .016, wall + .004), (half + .016, -.001)]
        end = a + (b - a).normalized() * .02
        sweep(f'End flange {index}', [a, end] if step > 0 else [end, a], section, 'accent', sharp=30)
        tangent = (b - a).xy.normalized()
        normal = Vector((-tangent.y, tangent.x))
        for side in (-1, 1):
            spot = (a.xy + end.xy) * .5 + normal * side * (half + .009)
            rivet(f'Flange bolt {index} {side}', .0042, a.z + wall + .007, 'metal', tuple(spot))
    # Support posts where the channel is high enough to need them.
    for i in range(12, len(path) - 8, 12):
        if path[i].z > .05:
            tangent = (path[i + 1] - path[i - 1]).xy.normalized()
            normal = Vector((-tangent.y, tangent.x))
            for side in (-1, 1):
                cylinder(f'Support {i} {side}', .0045, 0, path[i].z, 'metal', tuple(path[i].xy + normal * side * (half + .004)), 10)

asset(f"{table['id']}-dmd", (0, -9, 0))
rx, ry, rw, rh = table['apron']['dmd']
apron_top = table['apron']['height']
m = .022
frame = [(*centred(rx - m, ry - m), apron_top), (*centred(rx + rw + m, ry - m), apron_top),
         (*centred(rx + rw + m, ry + rh + m), apron_top), (*centred(rx - m, ry + rh + m), apron_top)]
sweep('Display frame', frame, [(-.008, 0), (-.008, .007), (-.002, .012), (.008, .012), (.018, .008), (.018, 0)], 'accent', closed=True, sharp=30)
for name, x, y in (('bl', rx - m + .004, ry - m + .004), ('br', rx + rw + m - .004, ry - m + .004),
                   ('tr', rx + rw + m - .004, ry + rh + m - .004), ('tl', rx - m + .004, ry + rh + m - .004)):
    rivet(f'Frame bolt {name}', .0048, apron_top + .012, 'metal', centred(x, y))
rivets_along('Frame rivet top', [(rx, ry + rh + m - .004), (rx + rw, ry + rh + m - .004)], .06, apron_top + .012, .0028)
rivets_along('Frame rivet low', [(rx, ry - m + .004), (rx + rw, ry - m + .004)], .06, apron_top + .012, .0028)


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
