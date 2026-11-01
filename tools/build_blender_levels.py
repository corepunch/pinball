"""Create the complete editable level source with the installed Pinball Builder add-on.
Run via tools/blender_mcp.py after build_hardware_models.py, or background Blender.
"""
import bpy
import importlib
import json
import sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools/blender_addons'))
# The Blender session outlives edits to the add-on.
if 'pinball_builder' in sys.modules:
    sys.modules['pinball_builder'].unregister()
    for module in [m for m in sys.modules if m.split('.')[0] == 'pinball_builder']:
        del sys.modules[module]
import pinball_builder as pb
pb.register()
from pinball_builder import levels
for previous in list(bpy.data.scenes):
    if previous.get('pb_level_authoring'):
        for obj in list(previous.objects):
            if len(obj.users_scene)==1:bpy.data.objects.remove(obj,do_unlink=True)
        if len(bpy.data.scenes)>1:bpy.data.scenes.remove(previous)
scenes=[]
for path in sorted((ROOT/'GameData/Tables').glob('*.json')):
    scene=levels.import_level(path,ROOT);scenes.append(scene)
    root=levels.root_for(scene);root['pb_workflow']='Edit curves and modifier settings; gameplay values are in the Pinball sidebar. Export Playable validates before updating the game.'
bpy.context.window.scene=next(s for s in scenes if levels.root_for(s)['pb_id']=='meridian')
bpy.ops.object.select_all(action='DESELECT')
track=next(o for o in bpy.context.scene.objects if o.get('pb_kind')=='ramps')
track.select_set(True);bpy.context.view_layer.objects.active=track
for area in bpy.context.screen.areas:
    if area.type=='PROPERTIES':area.spaces.active.context='MODIFIER'
bpy.data.orphans_purge(do_recursive=True)
bpy.ops.file.pack_all()
bpy.ops.wm.save_as_mainfile(filepath=str(ROOT/'Art/Models/pinball-levels.blend'),compress=True)
result={'source':str(ROOT/'Art/Models/pinball-levels.blend'),'levels':[levels.root_for(s)['pb_id'] for s in scenes], 'controllers':{o.name:len(o.data.splines[0].bezier_points) for s in scenes for o in s.objects if o.get('pb_kind')=='ramps'}}
