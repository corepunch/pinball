"""Inspect the actual channel loft from an oblique angle, through the Blender MCP bridge.

Run after build_hardware_models.py in the same session. PB_RAMP_DETAIL_OUT selects the PNG.
This transient scene is not saved over the editable master.
"""
import bpy
import math
import os
from pathlib import Path
from mathutils import Vector

source = next(s for s in bpy.data.scenes if s.get('workflow', '').startswith('Authored through'))
root = next(o for o in source.objects if o.get('asset_name') == 'aurora-rampL')
for previous in [s for s in bpy.data.scenes if s.get('ramp_detail')]:
    for obj in list(previous.objects):
        bpy.data.objects.remove(obj, do_unlink=True)
    bpy.data.scenes.remove(previous)
scene = bpy.data.scenes.new('Rounded-square channel detail')
scene['ramp_detail'] = True
bpy.context.window.scene=source
bpy.context.view_layer.update()
deps=bpy.context.evaluated_depsgraph_get()
points=[]
for obj in root.children_recursive:
    if obj.type not in ('MESH','CURVE') or obj.get('pb_track_owner'):continue
    evaluated=obj.evaluated_get(deps)
    mesh=bpy.data.meshes.new_from_object(evaluated,preserve_all_data_layers=True,depsgraph=deps)
    copy=bpy.data.objects.new(obj.name+' • Detail',mesh)
    copy.matrix_world=root.matrix_world.inverted()@obj.matrix_world
    scene.collection.objects.link(copy)
    points.extend(copy.matrix_world@v.co for v in mesh.vertices)

# Look directly into the open upper end, showing the floor/wall corner and rolled lip.
low = Vector(tuple(min(p[i] for p in points) for i in range(3)))
high = Vector(tuple(max(p[i] for p in points) for i in range(3)))
aim = Vector(((low.x + high.x) * .5, high.y - .10, high.z * .65))
camera = bpy.data.objects.new('Detail camera', bpy.data.cameras.new('Detail camera'))
camera.location = aim + Vector((.48, -.8, .62))
camera.rotation_euler = (aim - camera.location).to_track_quat('-Z', 'Y').to_euler()
camera.data.type = 'ORTHO'
camera.data.ortho_scale = .46
scene.collection.objects.link(camera)
scene.camera = camera
world = bpy.data.worlds.new('Detail navy room')
world.use_nodes = True
world.node_tree.nodes['Background'].inputs['Color'].default_value = (.08, .10, .14, 1)
world.node_tree.nodes['Background'].inputs['Strength'].default_value = .55
scene.world = world
for name, offset, power, size in [('Softbox', (-.3, -.3, 1.0), 100, .8), ('Edge', (.5, .4, .6), 80, .5)]:
    light = bpy.data.lights.new(name, 'AREA')
    light.energy, light.shape, light.size = power, 'DISK', size
    obj = bpy.data.objects.new(name, light)
    obj.location = aim + Vector(offset)
    obj.rotation_euler = (aim - obj.location).to_track_quat('-Z', 'Y').to_euler()
    scene.collection.objects.link(obj)
scene.render.engine = 'CYCLES'
scene.cycles.samples = 32
scene.cycles.use_denoising = True
scene.render.resolution_x, scene.render.resolution_y = 1000, 800
scene.render.resolution_percentage = 100
scene.view_settings.view_transform = 'AgX'
scene.render.image_settings.file_format = 'PNG'
scene.render.filepath = os.environ.get('PB_RAMP_DETAIL_OUT', '/tmp/pinball-ramp-detail.png')
Path(scene.render.filepath).parent.mkdir(parents=True, exist_ok=True)
bpy.context.window.scene = scene
bpy.ops.render.render(write_still=True)
bpy.context.window.scene = source
result = {'image': scene.render.filepath, 'section': root['section']}
