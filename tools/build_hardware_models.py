"""Editable Blender hardware master and SceneKit-ready COLLADA, executed via Blender MCP.

No downloads, simulation caches or external Python packages. Round kit parts are built to
unit radius and scaled by the table; elongated decor to unit half length. Each table in
GameData/Tables gets its own assets (flipper, ramps, walls, plastics) in
the JSON's coordinates, so they follow the physics exactly: rebuild after moving walls or ramps.
"""
import bmesh
import bpy
import importlib
import json
import math
import os
import sys
from pathlib import Path
from mathutils import Vector
from xml.etree.ElementTree import Element, SubElement, ElementTree

CODE_ROOT = Path(__file__).resolve().parents[1]
ROOT = Path(os.environ.get('PB_PROJECT_ROOT',str(CODE_ROOT)))
sys.path.insert(0, str(CODE_ROOT / 'tools'))
sys.path.insert(0, str(CODE_ROOT / 'tools/blender_addons'))
# The Blender session outlives edits to the add-on.
if 'pinball_builder' in sys.modules:
    sys.modules['pinball_builder'].unregister()
    for module in [m for m in sys.modules if m.split('.')[0] == 'pinball_builder']:
        del sys.modules[module]
import pinball_builder as pb_builder
from pinball_builder import modifier as pb_modifier
from pinball_builder.geometry import TrackSpec, build_wall, clear_support, rail_geometry
pb_builder.register()
import ramp_paths
importlib.reload(ramp_paths)  # The Blender session outlives edits to it.
OUT = ROOT / "Art/Models/premium"  # tools/compile_models.sh turns these into the shipped .scn files.
OUT.mkdir(parents=True, exist_ok=True)
(ROOT / "Art/Models").mkdir(parents=True, exist_ok=True)
if not bpy.app.background:
    raise RuntimeError('Run this generator in the dedicated background Blender MCP session')
for previous in list(bpy.data.scenes):
    if (previous.get('workflow', '').startswith('Authored through the installed Blender MCP bridge')
            or previous.get('ramp_detail') or previous.get('board_preview') or previous.get('pb_probe')
            or previous.name.startswith('Pinball add-on probe')):
        for obj in list(previous.objects):
            bpy.data.objects.remove(obj, do_unlink=True)
        if len(bpy.data.scenes) > 1:
            bpy.data.scenes.remove(previous)
scene = bpy.data.scenes.new("Pinball • machined hardware")
bpy.context.window.scene = scene
scene.unit_settings.system = 'METRIC'
scene['source_reference'] = 'Art/Concepts/cadet-inspired-redesign.png'
scene['workflow'] = 'Authored through the installed Blender MCP bridge; tools/build_hardware_models.py'

LATHE_FLIP = True

# Each role is a material slot the game rebinds per skin; see PBTableScene's skinModel.
ROLES = {
    'cabinet_shell': (.018, .035, .065, 1), 'guide_glow': (1, .32, .04, 1), 'channel_liner': (.29, .35, .40, 1), 'plate_frame': (.62, .63, .66, 1), 'channel_entry': (.72, .6, .38, 1), 'channel_floor': (.52,.57,.61,1), 'channel_aluminum': (.66,.71,.75,1), 'channel_shell': (.35,.40,.44,1), 'channel_arrow': (1,.12,.025,1), 'metal': (.56, .61, .65, 1), 'accent': (.72, .48, .19, 1), 'dark': (.012, .019, .027, 1),
    'rubber': (.62, .58, .47, 1), 'black_rubber': (.012, .012, .014, 1), 'skirt_lamp': (1, .2, .08, 1), 'cap_art': (.7, .2, .12, 1), 'enamel': (.86, .78, .6, 1),
    'lens': (.9, .95, 1, .18), 'glow': (.2, .8, 1, 1), 'glow_amber': (1, .65, .16, 1),
    'jewel': (.2, .8, 1, 1), 'ramp_floor': (.58, .62, .66, 1), 'sling_lens': (1, .25, .1, 1), 'amber_lens': (1, .65, .16, 1),
    'wall_art': (.05, .12, .14, 1), 'block_art': (.05, .18, .18, 1),
    'flipper_art': (.9, .85, .7, 1), 'target_art': (.6, .3, .15, 1),
}
ATLAS_SLOTS = {'cap_art': 'bumper_cap', 'jewel': 'bumper_cap_lit', 'wall_art': 'wall_top', 'block_art': 'plastic',
               'flipper_art': 'flipper', 'target_art': 'drop_target'}
for phase in range(4):
    ROLES[f'ramp_step_{phase}'] = (.035, .10, .16, 1)
METALLIC = ('metal', 'accent', 'ramp_floor', 'channel_liner', 'channel_entry', 'channel_floor', 'channel_aluminum', 'channel_shell')
EMISSIVE = {'amber_lens': 1, 'skirt_lamp': 3, 'glow': 3, 'glow_amber': 3, 'jewel': 1, 'sling_lens': 1, 'guide_glow': 2, 'channel_arrow': .7}
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
    bsdf.inputs['Roughness'].default_value = .32 if role.startswith('channel_') else .34 if role == 'ramp_floor' else (.2 if role in METALLIC else .3)
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
    material['pb_surface_role'] = role
    materials[role] = material

# The master uses the same authored deck textures as the game (Orbital is the preview theme).
chase_image = bpy.data.images.load(str(ROOT / 'Art/Masters/ramp-chase.png'))
for phase in range(4):
    material = materials[f'ramp_step_{phase}']
    nodes, links = material.node_tree.nodes, material.node_tree.links
    uv, mapping, texture = nodes.new('ShaderNodeTexCoord'), nodes.new('ShaderNodeMapping'), nodes.new('ShaderNodeTexImage')
    texture.image = chase_image
    slot = palette['atlasLayout']['slots']['ramp_chase_1' if phase == 0 else 'ramp_chase_off']
    x, y, w, h = slot['rect']
    cw, ch = slot['canvas']
    mapping.inputs['Location'].default_value = (x / cw, 1 - (y + h) / ch, 0)
    mapping.inputs['Scale'].default_value = (w / cw, h / ch, 1)
    links.new(uv.outputs['UV'], mapping.inputs['Vector'])
    links.new(mapping.outputs['Vector'], texture.inputs['Vector'])
    bsdf = nodes.get('Principled BSDF')
    links.new(texture.outputs['Color'], bsdf.inputs['Base Color'])
    links.new(texture.outputs['Color'], bsdf.inputs['Emission Color'])
    bsdf.inputs['Emission Strength'].default_value = 1.15 if phase == 0 else .24

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


def object_for(name, mesh, role, location=(0, 0, 0)):
    mesh.materials.append(materials[role])
    obj = bpy.data.objects.new(name, mesh)
    scene.collection.objects.link(obj)
    obj.parent = assets[current][0]
    obj.location = location
    obj['surface_role'] = role
    assets[current][1].append(obj)
    return obj


def planar_uv_group():
    """Geometry Nodes that map the art from above: a round part's UVs follow its radius, and stay live."""
    group = bpy.data.node_groups.get('Pinball Planar UV')
    if group:
        return group
    group = bpy.data.node_groups.new('Pinball Planar UV', 'GeometryNodeTree')
    group.interface.new_socket(name='Geometry', in_out='INPUT', socket_type='NodeSocketGeometry')
    size = group.interface.new_socket(name='Art diameter', in_out='INPUT', socket_type='NodeSocketFloat')
    size.default_value = 1
    group.interface.new_socket(name='Geometry', in_out='OUTPUT', socket_type='NodeSocketGeometry')
    nodes, links = group.nodes, group.links
    source, output = nodes.new('NodeGroupInput'), nodes.new('NodeGroupOutput')
    position = nodes.new('GeometryNodeInputPosition')
    inverse = nodes.new('ShaderNodeMath')
    inverse.operation = 'DIVIDE'
    inverse.inputs[0].default_value = 1
    links.new(source.outputs['Art diameter'], inverse.inputs[1])
    scale = nodes.new('ShaderNodeVectorMath')
    scale.operation = 'SCALE'
    links.new(position.outputs['Position'], scale.inputs[0])
    links.new(inverse.outputs[0], scale.inputs['Scale'])
    centre = nodes.new('ShaderNodeVectorMath')
    centre.operation = 'ADD'
    centre.inputs[1].default_value = (.5, .5, 0)
    links.new(scale.outputs[0], centre.inputs[0])
    store = nodes.new('GeometryNodeStoreNamedAttribute')
    store.data_type = 'FLOAT2'
    store.domain = 'CORNER'
    store.inputs['Name'].default_value = 'UV'
    links.new(source.outputs['Geometry'], store.inputs['Geometry'])
    links.new(centre.outputs[0], store.inputs['Value'])
    links.new(store.outputs['Geometry'], output.inputs['Geometry'])
    return group


def lathe(name, profile, role, segments=48, xy=(0, 0), planar=None, sharp=38):
    """A round part: a profile line, running (radius, height) up the outside and in over the top,
    turned by a Screw modifier. Edit the line or the modifiers in the master. planar maps UVs from above."""
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata([(radius, 0, z) for radius, z in profile], [(i, i + 1) for i in range(len(profile) - 1)], [])
    mesh.update()
    obj = object_for(name, mesh, role, (xy[0], xy[1], 0))
    screw = obj.modifiers.new('Turn the profile', 'SCREW')
    screw.axis = 'Z'
    screw.angle = math.tau
    screw.screw_offset = 0
    screw.steps = screw.render_steps = segments
    screw.use_normal_calculate = False
    screw.use_normal_flip = LATHE_FLIP
    screw.use_smooth_shade = True
    screw.use_merge_vertices = False
    if planar:
        art = obj.modifiers.new('Map the art', 'NODES')
        art.node_group = planar_uv_group()
        pb_modifier.set_input(art, art.node_group.interface.items_tree['Art diameter'].identifier, planar)
    crease = obj.modifiers.new('Crisp edges', 'EDGE_SPLIT')
    crease.split_angle = math.radians(sharp)
    crease.use_edge_sharp = False
    return obj


def plate(name, outline, top, height, role, corner=0, chamfer=0, sharp=40):
    """A flat part: an outline, rounded by a Bevel modifier, given height by Solidify, its edges by another Bevel."""
    if sum(outline[i][0] * outline[(i + 1) % len(outline)][1] - outline[(i + 1) % len(outline)][0] * outline[i][1]
           for i in range(len(outline))) < 0:
        outline = outline[::-1]
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata([(p[0], p[1], top) for p in outline], [], [tuple(range(len(outline)))])
    mesh.update()
    obj = object_for(name, mesh, role)
    if corner:
        rounded = obj.modifiers.new('Round the corners', 'BEVEL')
        rounded.affect = 'VERTICES'
        rounded.width = corner
        rounded.segments = 4
        rounded.limit_method = 'NONE'
    solid_part = obj.modifiers.new('Height', 'SOLIDIFY')
    solid_part.thickness = height
    solid_part.offset = 1
    solid_part.use_even_offset = False
    if chamfer:
        edges = obj.modifiers.new('Chamfer', 'BEVEL')
        edges.width = chamfer
        edges.segments = 1
        edges.limit_method = 'ANGLE'
        edges.angle_limit = math.radians(30)
    crease = obj.modifiers.new('Crisp edges', 'EDGE_SPLIT')
    crease.split_angle = math.radians(sharp)
    crease.use_edge_sharp = False
    return obj


def trim_group():
    """Geometry Nodes that give a line a rectangular section: the frame around a part."""
    group = bpy.data.node_groups.get('Pinball Trim')
    if group:
        return group
    group = bpy.data.node_groups.new('Pinball Trim', 'GeometryNodeTree')
    group.interface.new_socket(name='Geometry', in_out='INPUT', socket_type='NodeSocketGeometry')
    for label, value in (('Width', .1), ('Height', .1)):
        group.interface.new_socket(name=label, in_out='INPUT', socket_type='NodeSocketFloat').default_value = value
    material = group.interface.new_socket(name='Material', in_out='INPUT', socket_type='NodeSocketMaterial')
    group.interface.new_socket(name='Geometry', in_out='OUTPUT', socket_type='NodeSocketGeometry')
    nodes, links = group.nodes, group.links
    source, output = nodes.new('NodeGroupInput'), nodes.new('NodeGroupOutput')
    section = nodes.new('GeometryNodeCurvePrimitiveQuadrilateral')
    links.new(source.outputs['Width'], section.inputs['Width'])
    links.new(source.outputs['Height'], section.inputs['Height'])
    # The section stands on the line, rather than around it.
    lift = nodes.new('GeometryNodeTransform')
    half = nodes.new('ShaderNodeMath')
    half.operation = 'MULTIPLY'
    half.inputs[1].default_value = -.5
    links.new(source.outputs['Height'], half.inputs[0])
    offset = nodes.new('ShaderNodeCombineXYZ')
    links.new(half.outputs[0], offset.inputs['Y'])
    links.new(section.outputs[0], lift.inputs['Geometry'])
    links.new(offset.outputs[0], lift.inputs['Translation'])
    loft = nodes.new('GeometryNodeCurveToMesh')
    links.new(source.outputs['Geometry'], loft.inputs['Curve'])
    links.new(lift.outputs[0], loft.inputs['Profile Curve'])
    outward = nodes.new('GeometryNodeFlipFaces')
    links.new(loft.outputs[0], outward.inputs['Mesh'])
    paint = nodes.new('GeometryNodeSetMaterial')
    links.new(outward.outputs[0], paint.inputs['Geometry'])
    links.new(source.outputs['Material'], paint.inputs['Material'])
    links.new(paint.outputs[0], output.inputs['Geometry'])
    return group


def trim_line(name, outline, width, height, role, z=0, sharp=40):
    """A frame from a closed line: a poly curve with a section given by modifiers."""
    curve = bpy.data.curves.new(name, 'CURVE')
    curve.dimensions = '3D'
    spline = curve.splines.new('POLY')
    spline.points.add(len(outline) - 1)
    for point, p in zip(spline.points, outline):
        point.co = (p[0], p[1], z, 1)
    spline.use_cyclic_u = True
    curve.materials.append(materials[role])
    obj = bpy.data.objects.new(name, curve)
    scene.collection.objects.link(obj)
    obj.parent = assets[current][0]
    obj['surface_role'] = role
    assets[current][1].append(obj)
    section = obj.modifiers.new('Section', 'NODES')
    section.node_group = trim_group()
    tree = section.node_group.interface.items_tree
    for label, value in (('Width', width), ('Height', height), ('Material', materials[role])):
        pb_modifier.set_input(section, tree[label].identifier, value)
    return obj


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


def sweep(name, path, section, role, closed=False, band_roles=None, sharp=38, uv_scale=None, path_tangents=None):
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
        if path_tangents is not None:
            normal = Vector((-path_tangents[i][1], path_tangents[i][0]))
            stretch = 1
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


def inset_polygon(outline, distance):
    """A convex counter-clockwise polygon moved in by distance."""
    out = []
    n = len(outline)
    for i in range(n):
        p, a, b = Vector(outline[i]), Vector(outline[i - 1]), Vector(outline[(i + 1) % n])
        t0, t1 = (p - a).normalized(), (b - p).normalized()
        miter = (t0 + t1).normalized()
        normal = Vector((-miter.y, miter.x))
        out.append(p + normal * distance / max(normal.dot(Vector((-t1.y, t1.x))), .3))
    return out


def filleted(outline, radius, arc=8):
    """A convex counter-clockwise polygon with round corners."""
    out = []
    n = len(outline)
    for i in range(n):
        p, a, b = Vector(outline[i]), Vector(outline[i - 1]), Vector(outline[(i + 1) % n])
        t0, t1 = (p - a).normalized(), (b - p).normalized()
        turn = math.acos(max(-1, min(1, t0.dot(t1))))
        reach = radius * math.tan(turn * .5)
        start, stop = p - t0 * reach, p + t1 * reach
        centre = start + Vector((-t0.y, t0.x)) * radius
        a0 = math.atan2((start - centre).y, (start - centre).x)
        out.extend(tuple(centre + Vector((math.cos(a0 + turn * k / arc), math.sin(a0 + turn * k / arc))) * radius) for k in range(arc + 1))
    return out


# ---------------------------------------------------------------------------------- Kit parts

X = 0
def next_slot():
    global X
    X += 3
    return (X, 0, 0)


# A mushroom: a flared foot, a narrow waist, and a wide cap that overhangs them with a raised hub
# holding the jewel. Tall enough that the camera's tilt shows the foot below the cap, and that the
# cap throws a real shadow on the playfield. Every part is broad enough to read at phone size.
asset('bumper-base', next_slot())
lathe('Foot', [(.88, 0), (.88, .06), (.8, .11)], 'accent', 56, sharp=50)
# Black under the cap: this is what makes the cap read as overhanging.
lathe('Waist', [(.8, .1), (.56, .18), (.4, .27), (.3, .42), (.28, .62), (.34, .8), (.5, .92)], 'black_rubber', 40, sharp=80)

CAP_PLANAR = 1.92
asset('bumper-cap', next_slot())
# The UV-mapped part comes first: joining keeps the first object's UV layers.
lathe('Cap • painted star', [(.92, 1.13), (.72, 1.16), (.5, 1.19)], 'cap_art', 64, planar=CAP_PLANAR, sharp=80)
lathe('Cap edge', [(.46, .95), (.94, .98), (1.0, 1.02), (1.0, 1.1), (.95, 1.15), (.9, 1.15)], 'accent', 64, sharp=50)
lathe('Hub', [(.56, 1.17), (.54, 1.25), (.48, 1.3), (.38, 1.3), (.34, 1.26), (.34, 1.2)], 'accent', 48, sharp=50)
lathe('Jewel', [(.345, 1.21), (.335, 1.28), (.27, 1.35), (.15, 1.4), (.001, 1.42)], 'jewel', 36, planar=.69, sharp=80)

asset('insert-bezel', next_slot())
# Broad raised chamfer, kept inside the existing collision-validator footprint.
# Widen inward rather than growing adjacent inserts into one another.
lathe('Recessed socket', [(1.10, -.025), (1.10, .015), (1.07, .04)], 'dark', 40)
lathe('Machined brass bezel', [(1.095, .015), (1.095, .07), (1.055, .14),
                             (.94, .17), (.86, .125), (.84, .08), (.84, .025)], 'accent', 48, sharp=50)
lathe('Clear inset lens', [(.84, .055), (.77, .10), (.60, .145), (.32, .17), (.001, .18)], 'lens', 32, sharp=80)

# Unit circumradius, apex on +x. The scene rotates it to the lamp's angle.
triangle = []
for corner, a in enumerate((0, 2 * math.pi / 3, 4 * math.pi / 3)):
    centre = Vector((math.cos(a), math.sin(a))) * .78
    for s in range(7):
        b = a - math.pi / 3 + s * (2 * math.pi / 3) / 6
        # Narrowed into an arrowhead: an equilateral triangle has no direction.
        triangle.append((centre.x + .24 * math.cos(b), (centre.y + .24 * math.sin(b)) * .62, 0))
asset('insert-arrow', next_slot())
w = .065
trim_line('Triangular bezel', triangle, w * 2, .1, 'accent')
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
lathe('Brass stop', [(1.0, 0), (1.0, .55), (.86, .75), (.62, .8)], 'accent', 20, sharp=60)
lathe('Polished dome', [(.66, .74), (.58, .98), (.34, 1.14), (.001, 1.2)], 'metal', 16, sharp=80)

asset('target', next_slot())
d = .17
plate('Target block', [(-.53, -d * 1.12), (.53, -d * 1.12), (.53, d * 1.12), (-.53, d * 1.12)], 0, 1.0, 'accent', chamfer=.03)
solid('Target art', [(-.5, -d, 1.002), (.5, -d, 1.002), (.5, d, 1.002), (-.5, d, 1.002)], [(0, 1, 2, 3)], 'target_art', [(0, 0), (1, 0), (1, 1), (0, 1)], 90)

# Unit radius: a round target, a domed lens in a broad gold ring on a short solid body.
asset('spot-target', next_slot())
lathe('Target lens', [(.74, .62), (.56, .74), (.3, .82), (.001, .85)], 'sling_lens', 32, planar=2.0, sharp=80)
lathe('Target body', [(1.0, 0), (1.0, .42), (.92, .6), (.76, .66), (.7, .6)], 'accent', 32, sharp=50)

# Unit half length along y: a rollover switch's plate, a broad metal frame around a dark slot with a
# gold wire down it. Flat enough for the ball to roll over. Space Cadet's lanes are built from these.
asset('rollover-plate', next_slot())
plate_object = object_for('Rollover bar', bpy.data.meshes.new('Rollover bar'), 'plate_frame')
pb_modifier.attach_rollover_bar(plate_object, materials['plate_frame'], materials['dark'], 1, .46)

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


def clear_of_parts(table, x, y, radius):
    """Whether a foot plate on the playfield sits clear of what is drawn there."""
    spots = [(b['x'], b['y'], b['r'] * 1.1) for b in table['bumpers']] + [(q['x'], q['y'], q['r']) for q in table['posts']]
    spots += [(l['x'], l['y'], l['size'] * 1.1) for l in table['lamps']] + [(r['x'], r['y'], r['r']) for r in table['rollovers']]
    spots += [(d['x'], d['y'], d['size']) for d in table['decor']] + [(q['x'], q['y'], q['r'] * 1.15) for q in table['saucers']]
    if any(math.hypot(x - a, y - b) < radius + r for a, b, r in spots):
        return False
    for wall in table['walls']:
        if wall['style'] == 'none' or 'ramp' in wall.get('layers', ()):
            continue
        line = table_path(wall['points'])
        if ramp_paths.distance_to_polyline((x, y), line) < radius + wall['radius']:
            return False
    return True


def bevelled_block(name, centre, tangent, across, along, z0, z1, role):
    """A chamfered block on a ramp. across and along are (low, high) from centre, in its own frame."""
    normal = Vector((-tangent.y, tangent.x))
    b = min(.0012, (z1 - z0) * .4)

    def ring(inset, z):
        corners = ((across[0] + inset, along[0] + inset), (across[1] - inset, along[0] + inset),
                   (across[1] - inset, along[1] - inset), (across[0] + inset, along[1] - inset))
        # Counter-clockwise seen from above, with across on the normal and along on the tangent.
        return [(*(centre + normal * a + tangent * c), z) for a, c in corners[::-1]]
    vertices = ring(0, z0) + ring(0, z1 - b) + ring(b, z1)
    faces = []
    for k in range(2):
        for i in range(4):
            j = (i + 1) % 4
            faces.append((k * 4 + i, k * 4 + j, (k + 1) * 4 + j, (k + 1) * 4 + i))
    faces.append((8, 9, 10, 11))
    return solid(name, vertices, faces, role, sharp=30)


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
lathe('Moulded light socket', [(1.0, 0), (1.0, .45), (.78, .75), (.7, .85)], 'cabinet_shell', 20, sharp=65)
lathe('Inset lens', [(.70, .78), (.65, 1.0), (.44, 1.16), (.001, 1.20)], 'glow', 20, sharp=80)



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

    # Every wall is a thick piece rising out of the board, with a gold trim, and it casts a shadow.
    asset(f"{table['id']}-walls", (table_index * 3, -3, 0))
    for wall in table['walls']:
        if wall['style'] not in ('wall', 'rail', 'rubber'):
            continue
        data = build_wall([centred(*p) for p in table_path(wall['points'])], wall['radius'], wall['height'])
        for role in sorted(set(data.roles)):
            faces = [f for f, r in zip(data.faces, data.roles) if r == role]
            solid(f"{wall['id']} • {role}", data.vertices, faces, role, sharp=50)

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
        if name == 'captiveHousing':
            # A low docking pod with a recessed ball tray, not a tall skeletal cage.
            x0, x1 = min(p[0] for p in outline), max(p[0] for p in outline)
            y0, y1 = min(p[1] for p in outline), max(p[1] for p in outline)
            tray = [(x0, y0), (x1, y0), (x1, y1 - .025), (x0, y1 - .025)]
            prism_top('Docking pod tray', tray, .001, 'dark')
            prism_top('Docking pod shell', outline, .020, 'dark')
            sweep('Docking pod soft edge', [(*p, 0) for p in outline],
                  [(-.0042, 0), (-.0042, .016), (0, .023), (.0042, .016), (.0042, 0)],
                  'accent', closed=True, sharp=65)
            continue
        if art == 'sling_lens':
            # A rounded block like a real bouncer: coloured base and top, a cream band between
            # them, a cream line inset in the top, and a screw in each corner.
            band, lip = .03, .037
            body = filleted(outline, .014)
            plate = filleted([tuple(q) for q in inset_polygon(outline, .002)], .012)
            sweep(f'{name} base', [(*p, 0) for p in body], [(0, 0), (0, .006), (.0015, .0085)], 'sling_lens', closed=True, sharp=50)
            sweep(f'{name} band', [(*p, 0) for p in plate], [(0, .007), (0, band)], 'enamel', closed=True, sharp=50)
            sweep(f'{name} rim', [(*p, 0) for p in body], [(.002, band), (0, band + .002), (0, lip - .0025), (.0025, lip)], 'sling_lens', closed=True, sharp=50)
            prism_top(f'{name} top', filleted([tuple(q) for q in inset_polygon(outline, .0025)], .0115), lip, 'sling_lens')
            line = filleted([tuple(q) for q in inset_polygon(outline, .0065)], .0075)
            sweep(f'{name} line', [(*p, 0) for p in line], [(0, lip + .0002), (.0042, lip + .0002)], 'enamel', closed=True, sharp=80)
            # At the centres of the corners' arcs, so they always sit inside the outline.
            for k, corner in enumerate(inset_polygon(outline, .0175)):
                lathe(f'{name} screw {k}', [(.0058, lip), (.0058, lip + .0012), (.0042, lip + .0026), (.001, lip + .0032)], 'metal', 14, tuple(corner), sharp=70)
            continue
        prism_top(f'{name} art', outline, top, art)
        # Outline is counter-clockwise, so "left of travel" is inward.
        sweep(f'{name} frame', [(*p, base) for p in outline], [(-.0042, 0), (-.0042, wall_height + .002), (-.0014, wall_height + .0036), (.0014, wall_height + .0036), (.0042, wall_height + .002), (.0042, 0)], 'accent', closed=True, sharp=80)

    # One editable Curve + Pinball Ramp modifier. Supports and arrows are internal geometry.
    for ramp in table['ramps']:
        spec = TrackSpec.from_dict({'width':ramp['width'], **ramp.get('authoring',{})})
        spec.triangle_budget=min(6000,spec.triangle_budget)
        found = ramp_paths.problems(ramp)
        clearance = rail_geometry(spec)[0] - spec.corner_radius - table['physics']['ballRadius']
        if ramp_paths.measure(ramp)['drift'] > clearance:
            found.append('the larger ball would clip the channel walls along the relaxed spline')
        if found:raise RuntimeError(f"{table['id']}/{ramp['id']}: {found}")
        asset(f"{table['id']}-{ramp['id']}",(table_index*3,3,0))
        root=assets[current][0]
        curve=bpy.data.curves.new(current+' path','CURVE');curve.dimensions='3D'
        points=ramp_paths.ramp_path(ramp)
        spline=curve.splines.new('POLY');spline.points.add(len(points)-1)
        for point,p in zip(spline.points,points):point.co=(*centred(p[0],p[1]),p[2],1)
        controller=bpy.data.objects.new(current+' • Path',curve);scene.collection.objects.link(controller);controller.parent=root
        controller['pb_kind']='ramps';controller['pb_id']=ramp['id']
        pb_builder.configure_track(controller,spec)
        _,generated=pb_builder.rebuild_track(controller,materials,lambda xy,r,tight=False:clear_support(table,(xy.x+SIZE[0]*.5,xy.y+SIZE[1]*.5),r,tight))
        assets[current]=(root,[controller])
        root['section']=generated.metadata['section'];root['arrow_count']=generated.metadata['arrow_count']
        root['arrow_spacing']=spec.arrow_spacing;root['support_count']=generated.metadata['support_count']


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
        uv = mesh.uv_layers.active
        for triangle in mesh.loop_triangles:
            material=mesh.materials[triangle.material_index]
            role=material.get('pb_surface_role',obj.get('surface_role',material.name))
            group=grouped.setdefault(role,{'positions':[],'normals':[],'uvs':[],'lookup':{},'indices':[]})
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

    if name.rsplit('-', 1)[-1] in ('rampL', 'rampR') and triangle_count > 6000:
        raise RuntimeError(f'{name}: {triangle_count} triangles exceeds mobile ramp budget of 6000')

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
    stats = {'objects': len(objects), 'triangles': triangle_count, 'radius': round(reach, 4), 'bytes': (OUT / (name + '.dae')).stat().st_size}
    if 'arrow_count' in root:
        stats.update(section=root['section'], arrow_count=root['arrow_count'], arrow_spacing=round(root['arrow_spacing'], 6))
    return stats


# Parts stay separate objects: joining would apply their modifiers, and the master could no longer edit them.
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
