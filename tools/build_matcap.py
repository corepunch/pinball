"""Render the metal MatCap, via Blender MCP: a polished sphere in Blender's bundled studio room.

A MatCap (material capture, or sphere map) stores how a material looks for every facing
direction, so a shader needs only the surface normal to look it up. A skin picks one for its
hardware and one for its ramps, and tints them.

The rooms are from Blender's studiolights, CC0 (Greg Zaal, Poly Haven). A real room gives crisp,
irregular highlights in colour; painted rings turn into stripes along rounded parts.
Keep the output in colour: 8-bit grey textures crash the iOS simulator's Metal validation.
Writes GameData/Materials/matcap-{courtyard,studio,sunrise}.png.
"""
import bpy
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'GameData/Materials'
OUT.mkdir(parents=True, exist_ok=True)
ROOMS = Path(bpy.app.binary_path).parents[1] / 'Resources' / '.'.join(map(str, bpy.app.version[:2])) / 'datafiles/studiolights/world'
CAPTURES = {'courtyard': (1.4, .12), 'studio': (1.0, .25), 'sunrise': (1.4, .12)}  # Strength, roughness.

scene = bpy.data.scenes.new('MatCap')
world = bpy.data.worlds.new('MatCap room')
world.use_nodes = True
environment = world.node_tree.nodes.new('ShaderNodeTexEnvironment')
background = world.node_tree.nodes['Background']
world.node_tree.links.new(environment.outputs['Color'], background.inputs['Color'])
scene.world = world

mesh = bpy.data.meshes.new('MatCap sphere')
segments, rings = 192, 96
vertices = [(0, 0, 1)] + [(math.sin(math.pi * r / rings) * math.cos(2 * math.pi * s / segments),
                           math.sin(math.pi * r / rings) * math.sin(2 * math.pi * s / segments),
                           math.cos(math.pi * r / rings)) for r in range(1, rings) for s in range(segments)] + [(0, 0, -1)]
faces = [(0, 1 + s, 1 + (s + 1) % segments) for s in range(segments)]
for r in range(rings - 2):
    for s in range(segments):
        a, b = 1 + r * segments + s, 1 + r * segments + (s + 1) % segments
        faces.append((a, a + segments, b + segments, b))
last = 1 + (rings - 2) * segments
faces += [(last + s, len(vertices) - 1, last + (s + 1) % segments) for s in range(segments)]
mesh.from_pydata(vertices, [], faces)
mesh.update()
mesh.shade_smooth()
scene.collection.objects.link(bpy.data.objects.new('MatCap sphere', mesh))
metal = bpy.data.materials.new('MatCap metal')
metal.use_nodes = True
bsdf = metal.node_tree.nodes['Principled BSDF']
bsdf.inputs['Base Color'].default_value = (.92, .92, .92, 1)
bsdf.inputs['Metallic'].default_value = 1
mesh.materials.append(metal)

camera_data = bpy.data.cameras.new('MatCap camera')
camera_data.type = 'ORTHO'
camera_data.ortho_scale = 2
camera = bpy.data.objects.new('MatCap camera', camera_data)
camera.location = (0, 0, 8)
scene.collection.objects.link(camera)
scene.camera = camera

scene.render.engine = 'CYCLES'
scene.cycles.samples = 192
scene.cycles.use_denoising = True
scene.view_settings.view_transform = 'Standard'
scene.view_settings.look = 'None'
scene.render.resolution_x = scene.render.resolution_y = 512
scene.render.image_settings.file_format = 'PNG'
scene.render.image_settings.color_mode = 'RGB'
previous_scene = bpy.context.window.scene
bpy.context.window.scene = scene
for name, (strength, roughness) in CAPTURES.items():
    environment.image = bpy.data.images.load(str(ROOMS / f'{name}.exr'), check_existing=True)
    background.inputs['Strength'].default_value = strength
    bsdf.inputs['Roughness'].default_value = roughness
    scene.render.filepath = str(OUT / f'matcap-{name}.png')
    bpy.ops.render.render(write_still=True, scene=scene.name)
bpy.context.window.scene = previous_scene
bpy.data.scenes.remove(scene)
result = {'matcaps': sorted(CAPTURES)}
