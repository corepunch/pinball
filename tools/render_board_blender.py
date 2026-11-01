"""Lay the Blender hardware kit out on the table and render it from the game's camera, via Blender MCP.

Run after tools/build_hardware_models.py, in the same dedicated session. Fast iteration only:
materials approximate SceneKit, and tools/render_preview.sh remains the check of the shipped look.
Environment variables choose the output: PB_BOARD_OUT (directory), PB_BOARD_SKIN (default orbital),
PB_BOARD_TABLE (default aurora), PB_BOARD_WIDTH (default 804 pixels), PB_BOARD_SAMPLES (default 48), PB_BOARD_CROP (x0,y0,x1,y1 of the
image, each 0 to 1 from the top left, for a close-up render).
"""
import bpy
import json
import math
import os
from pathlib import Path

import numpy

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(os.environ.get('PB_BOARD_OUT', '/tmp/pinball-board'))
OUT.mkdir(parents=True, exist_ok=True)
SKIN = os.environ.get('PB_BOARD_SKIN', 'orbital')
WIDTH = int(os.environ.get('PB_BOARD_WIDTH', 804))
SAMPLES = int(os.environ.get('PB_BOARD_SAMPLES', 48))
CROP = os.environ.get('PB_BOARD_CROP')

table = json.loads((ROOT / f"GameData/Tables/{os.environ.get('PB_BOARD_TABLE', 'aurora')}.json").read_text())
skin = json.loads((ROOT / f'GameData/Skins/{SKIN}.json').read_text())
SIZE = table['size']
source = next(s for s in bpy.data.scenes if s.get('workflow', '').startswith('Authored through'))
roots = {o['asset_name']: o for o in source.objects if 'asset_name' in o}

for previous in [s for s in bpy.data.scenes if s.get('board_preview')]:
    bpy.data.scenes.remove(previous)
for stale in [c for c in bpy.data.collections if c.get('board_asset')]:
    bpy.data.collections.remove(stale)
board = bpy.data.scenes.new('Board preview')
board['board_preview'] = True


def crop(path, rect, canvas, name):
    """A slot of a master image. Blender stores rows bottom-up."""
    image = bpy.data.images.load(str(path), check_existing=True)
    w, h = image.size
    sx, sy = w / canvas[0], h / canvas[1]
    x, y, cw, ch = int(rect[0] * sx), int(rect[1] * sy), int(rect[2] * sx), int(rect[3] * sy)
    pixels = numpy.empty(w * h * 4, dtype=numpy.float32)
    image.pixels.foreach_get(pixels)
    pixels = pixels.reshape(h, w, 4)[h - y - ch:h - y, x:x + cw].copy()
    slot = bpy.data.images.get(name) or bpy.data.images.new(name, cw, ch, alpha=True)
    if tuple(slot.size) != (cw, ch):
        slot.scale(cw, ch)
    slot.pixels.foreach_set(pixels.ravel())
    slot.update()
    slot.pack()
    return slot


slots = skin['atlasLayout']['slots']
CANVAS = skin['atlasLayout']['canvas']
hardware = ROOT / f'Art/Masters/{SKIN}-hardware.png'
painting = ROOT / f'Art/Masters/{SKIN}-playfield.png'


def set_color(role, color):
    material = bpy.data.materials.get(role)
    if material:
        material.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value = (*color, 1)


set_color('metal', skin['metal'])
set_color('accent', skin['accent'])
set_color('rubber', skin['rubber'])
set_color('glow', skin['lamps']['bumper'])
set_color('ramp_floor', skin['materials']['rampGlass'])
set_color('glow_amber', skin['lamps']['amber'])
ATLAS = bpy.data.images.load(str(hardware), check_existing=True)
for material in bpy.data.materials:
    if material.use_nodes:
        for node in material.node_tree.nodes:
            if node.type == 'TEX_IMAGE' and node.image and node.image.name.endswith('-hardware.png'):
                node.image = ATLAS

world = bpy.data.worlds.new('Board room')
world.use_nodes = True
environment = world.node_tree.nodes.new('ShaderNodeTexEnvironment')
environment.image = crop(hardware, slots['environment']['rect'], CANVAS, 'board-environment')
world.node_tree.links.new(environment.outputs['Color'], world.node_tree.nodes['Background'].inputs['Color'])
world.node_tree.nodes['Background'].inputs['Strength'].default_value = skin['ambient'] * .9
board.world = world


def art_plane(name, image, x0, y0, x1, y1, z=0.0):
    x0, x1 = x0 - SIZE[0] * .5, x1 - SIZE[0] * .5
    y0, y1 = y0 - SIZE[1] * .5, y1 - SIZE[1] * .5
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata([(x0, y0, z), (x1, y0, z), (x1, y1, z), (x0, y1, z)], [], [(0, 1, 2, 3)])
    layer = mesh.uv_layers.new(name='UV')
    for loop, uv in zip(mesh.loops, ((0, 0), (1, 0), (1, 1), (0, 1))):
        layer.data[loop.index].uv = uv
    material = bpy.data.materials.new(name)
    material.use_nodes = True
    texture = material.node_tree.nodes.new('ShaderNodeTexImage')
    texture.image = image
    bsdf = material.node_tree.nodes['Principled BSDF']
    material.node_tree.links.new(texture.outputs['Color'], bsdf.inputs['Base Color'])
    bsdf.inputs['Roughness'].default_value = .55
    mesh.materials.append(material)
    obj = bpy.data.objects.new(name, mesh)
    board.collection.objects.link(obj)
    return obj


art_plane('Playfield', crop(painting, slots['playfield']['rect'], slots['playfield']['canvas'], 'board-playfield'), 0, 0, 1, SIZE[1])


collections = {}


def collection_for(name):
    if name not in collections:
        group = bpy.data.collections.new('board ' + name)
        group['board_asset'] = True
        root = roots[name]
        for obj in [root, *root.children]:
            group.objects.link(obj)
        group.instance_offset = root.location
        collections[name] = group
    return collections[name]


def place(name, x=None, y=None, z=0.0, scale=1.0, angle=0.0, sx=None):
    """Kit parts take table coordinates, and table-specific assets none."""
    if name not in roots:
        return None
    holder = bpy.data.objects.new(f'{name} instance', None)
    holder.instance_type = 'COLLECTION'
    holder.instance_collection = collection_for(name)
    if x is not None:
        holder.location = (x - SIZE[0] * .5, y - SIZE[1] * .5, z)
    holder.scale = (sx or scale, scale, scale)
    holder.rotation_euler[2] = angle
    board.collection.objects.link(holder)
    return holder


def disc(name, x, y, radius, color, emission):
    bpy.ops.mesh.primitive_circle_add(vertices=32, radius=radius, fill_type='NGON', location=(x - SIZE[0] * .5, y - SIZE[1] * .5, .0008))
    obj = bpy.context.object
    for collection in obj.users_collection:
        collection.objects.unlink(obj)
    board.collection.objects.link(obj)
    obj.name = name
    material = bpy.data.materials.new(name)
    material.use_nodes = True
    bsdf = material.node_tree.nodes['Principled BSDF']
    bsdf.inputs['Base Color'].default_value = (*color, 1)
    bsdf.inputs['Emission Color'].default_value = (*color, 1)
    bsdf.inputs['Emission Strength'].default_value = emission
    obj.data.materials.append(material)


for name in ('walls', 'plastics', *(ramp['id'] for ramp in table['ramps'])):
    place(f"{table['id']}-{name}")
for post in table['posts']:
    place('post', post['x'], post['y'], 0, post['r'])
for bumper in table['bumpers']:
    place('bumper-base', bumper['x'], bumper['y'], 0, bumper['r'])
    place('bumper-cap', bumper['x'], bumper['y'], 0, bumper['r'])
for flipper in table['flippers']:
    place(f"{table['id']}-flipper", flipper['pivot'][0], flipper['pivot'][1], 0, flipper['length'], math.radians(flipper['restAngle']))
for lamp in table['lamps']:
    color = skin['lamps'][lamp['color']]
    arrow = lamp.get('shape') == 'arrow'
    if not arrow:
        disc(lamp['id'], lamp['x'], lamp['y'], lamp['size'], color, 1.2)
    place('insert-arrow' if arrow else 'insert-bezel', lamp['x'], lamp['y'], 0, lamp['size'], math.radians(lamp.get('angle', 0)))
for flasher in table['flashers']:
    place('flasher-cage', flasher['x'], flasher['y'], .11, .034)
for edge in table['dropTargets'] + table['standups']:
    width = math.dist(edge['a'], edge['b'])
    holder = place('target', (edge['a'][0] + edge['b'][0]) * .5, (edge['a'][1] + edge['b'][1]) * .5, 0, width,
                   math.atan2(edge['b'][1] - edge['a'][1], edge['b'][0] - edge['a'][0]))
    if holder:
        holder.scale[2] = .05
for decor in table['decor']:
    place(decor['model'], decor['x'], decor['y'], decor.get('base', 0), decor['size'], math.radians(decor.get('angle', 0)))

# The game's camera, as PBTableScene's fitCameraToAspect: orthographic, leaning toward the player,
# with the table's foot on the image's lower edge.
TILT = math.radians(18)
span = SIZE[1] * math.cos(TILT)
visible = max(span, SIZE[0] * SIZE[1])
camera_data = bpy.data.cameras.new('Table camera')
camera_data.sensor_fit = 'VERTICAL'
camera_data.type = 'ORTHO'
camera_data.ortho_scale = visible
camera_data.clip_end = 20
camera = bpy.data.objects.new('Table camera', camera_data)
aim = (visible - span) * .5 / math.cos(TILT)
camera.location = (0, aim - math.sin(TILT) * 6, math.cos(TILT) * 6)
camera.rotation_euler = (TILT, 0, 0)
board.collection.objects.link(camera)
board.camera = camera

key = bpy.data.lights.new('Key', 'SPOT')
key.energy = 180
key.spot_size = math.radians(86)
key.shadow_soft_size = .3
light = bpy.data.objects.new('Key', key)
light.location = (-2.2, -1.4, 2.9)
light.rotation_euler = (math.radians(52), 0, math.radians(-57))
board.collection.objects.link(light)

board.render.engine = 'CYCLES'
board.cycles.samples = SAMPLES
board.cycles.use_denoising = True
preferences = bpy.context.preferences.addons['cycles'].preferences
preferences.compute_device_type = 'METAL'
preferences.get_devices()
for device in preferences.devices:
    device.use = True
board.cycles.device = 'GPU'
board.view_settings.view_transform = 'Standard'
board.view_settings.look = 'None'
board.render.resolution_x = WIDTH
board.render.resolution_y = round(WIDTH * SIZE[1])
board.render.image_settings.file_format = 'PNG'
board.render.filepath = str(OUT / f'board-{SKIN}.png')
if CROP:
    x0, y0, x1, y1 = (float(v) for v in CROP.split(','))
    board.render.use_border = board.render.use_crop_to_border = True
    board.render.border_min_x, board.render.border_max_x = x0, x1
    board.render.border_min_y, board.render.border_max_y = 1 - y1, 1 - y0
    board.render.filepath = str(OUT / f'board-{SKIN}-crop.png')
bpy.context.window.scene = board
bpy.ops.render.render(write_still=True, scene=board.name)
bpy.context.window.scene = source
result = {'render': board.render.filepath, 'instances': len(board.objects)}
