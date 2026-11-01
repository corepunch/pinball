"""Integration checks for the actual Blender add-on, modifier and full table round trip.
/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup --python-exit-code 1 --python tools/test_blender_builder.py
"""
import bpy
import copy
import json
import math
from pathlib import Path
import sys
from mathutils import Vector
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools/blender_addons'))
import pinball_builder as pb
from pinball_builder import levels,modifier
from pinball_builder.geometry import TrackSpec,build_track,arc_lengths,sample
pb.register()
bpy.ops.wm.open_mainfile(filepath=str(ROOT/'Art/Models/pinball-levels.blend'))
checks=[]
def check(condition,message):
    if not condition:raise AssertionError(message)
    checks.append(message)
def similar(a,b,path=''):
    if isinstance(a,dict):
        check(set(a)==set(b),path+' fields preserved')
        for key in a:similar(a[key],b[key],path+'/'+key)
    elif isinstance(a,list):
        check(len(a)==len(b),path+' count preserved')
        for i,(x,y) in enumerate(zip(a,b)):similar(x,y,path+'/'+str(i))
    elif isinstance(a,(float,int)) and not isinstance(a,bool):check(abs(a-b)<2e-6,path+' value preserved')
    else:check(a==b,path+' value preserved')
for scene in [s for s in bpy.data.scenes if s.get('pb_level_authoring')]:
    bpy.context.window.scene=scene
    root=levels.root_for(scene);original=json.loads(root['pb_definition'])
    table=levels.validate(levels.table_dict(scene));clean=copy.deepcopy(table)
    for ramp in clean['ramps']:ramp.pop('authoring',None)
    # Legacy physics is replaced by the exact editable curve, preserving all other gameplay values.
    for ramp in clean['ramps']:
        prior=next(r for r in original['ramps'] if r['id']==ramp['id'])
        for key in ('points','mouth','plasticUntil'):prior[key]=copy.deepcopy(ramp[key])
        prior.pop('authoring',None)
    # A ramp's entrance lamp comes from its curve, which the import refits.
    for name,ramp in [(r['id'],r) for r in table['ramps']]:
        lamp=next((l for l in table['lamps'] if l.get('ramp')==name),None)
        check(lamp is not None,'each ramp generates its entrance lamp')
        check(len([w for w in table['walls'] if w.get('ramp')==name])==2,'each ramp generates its funnel walls')
    for generated in (clean,original):
        for kind in ('lamps','walls'):generated[kind]=[l for l in generated[kind] if 'ramp' not in l]
    # JSON array order is irrelevant; IDs bind rules and runtime instances.
    for kind in levels.ARRAYS:clean[kind].sort(key=lambda v:v['id']);original[kind].sort(key=lambda v:v['id'])
    clean['rules']['groups'].sort(key=lambda v:v['id']);original['rules']['groups'].sort(key=lambda v:v['id'])
    similar(original,clean,root['pb_id'])
    for obj in [o for o in scene.objects if o.get('pb_kind')=='ramps']:
        check(obj.type=='CURVE' and obj.data.splines[0].type=='BEZIER','editable Bézier controller')
        check(len(obj.data.splines[0].bezier_points)<25,'compact curve handles')
        check(modifier.find(obj).name=='Pinball Ramp','native modifier exists')
        count=len(bpy.data.objects)
        for i in range(3):helper,data=pb.rebuild_track(obj)
        check(len(bpy.data.objects)==count,'regeneration has no object growth')
        check(obj['pb_triangle_count']<=6000,'mobile triangle budget')
        deps=bpy.context.evaluated_depsgraph_get();evaluated=obj.evaluated_get(deps);mesh=evaluated.to_mesh()
        check(len(mesh.polygons)==len(data.faces),'modifier outputs actual generated mesh');evaluated.to_mesh_clear()
        path=pb.curve_points(obj);lengths=arc_lengths(path)
        for arrow in data.metadata['arrows']:
            expected=sample(path,lengths,arrow['distance'])[0]
            check((Vector(arrow['centre'])-expected).length<1e-6,'arrow center lies on curve')
        saved=pb.spec_for(obj);spec=TrackSpec.from_dict(saved.to_dict());spec.arrow_mode='REPEAT'
        modifier.create(obj,spec);pb.rebuild_track(obj)
        check(obj['pb_support_count']==0 and obj['pb_arrow_count']>2,'modifier toggles repeated arrows, with no columns by default')
        # Change an actual native modifier socket, rather than the Python settings cache.
        m=modifier.find(obj);mapping=json.loads(m.node_group['pb_socket_map']);modifier.set_input(m,mapping['width'],.1)
        check(abs(pb.spec_for(obj).width-.1)<1e-6,'modifier sockets are authoritative')
        bpy.context.view_layer.update();pb.paths_changed(scene,bpy.context.evaluated_depsgraph_get())
        check(obj.name in pb._dirty,'modifier edit queues live regeneration')
        pb.flush_updates()
        check(abs(pb.spec_for(obj).width-.1)<1e-6 and obj.get('pb_build_error')=='','live regeneration completes')
        modifier.create(obj,saved);pb.rebuild_track(obj)
        obj.location.x+=.004;bpy.context.view_layer.update()
        changed=levels.entity_json(obj)
        check(changed['authoring']['path_sampled'] and len(changed['points'])>50,'edited curve exports exact sampled physics path')
        check(changed['plasticUntil']==len(changed['points'])-1,'aluminum channel runs to open exit')
        obj.location.x-=.004;bpy.context.view_layer.update();pb.rebuild_track(obj)
    wall=next(o for o in scene.objects if o.get('pb_kind')=='walls' and modifier.find_wall(o))
    deps=bpy.context.evaluated_depsgraph_get();evaluated=wall.evaluated_get(deps);mesh=evaluated.to_mesh()
    check(len(mesh.polygons)>10,'wall line and modifier output a generated mesh');evaluated.to_mesh_clear()
    saved=modifier.read_wall(wall);modifier.create_wall(wall,saved[0]+.005,saved[1]);pb.rebuild_wall(wall)
    check(abs(levels.entity_json(wall)['radius']-saved[0]-.005)<1e-5,'wall modifier sets its collider radius')
    modifier.create_wall(wall,*saved);pb.rebuild_wall(wall)
    bumper=next(o for o in scene.objects if o.get('pb_kind')=='bumpers');before=levels.entity_json(bumper)
    bumper.location.x+=.01;bumper.scale*=1.1;bpy.context.view_layer.update();after=levels.entity_json(bumper)
    check(abs(after['x']-before['x']-.01)<1e-6 and abs(after['r']-before['r']*1.1)<1e-6,'moving and resizing updates gameplay dimensions')
    bumper.location.x-=.01;bumper.scale/=1.1;bpy.context.view_layer.update()
    edge=next(o for o in scene.objects if o.get('pb_kind')=='gates');edge.location.y+=.01;bpy.context.view_layer.update()
    check(abs(levels.entity_json(edge)['a'][1]-json.loads(edge['pb_definition'])['a'][1]-.01)<1e-6,'edited gate endpoints export')
    edge.location.y-=.01;bpy.context.view_layer.update()
    before_direction=edge['game_passDirection'];before_rotation=edge.rotation_euler.z
    edge['game_passDirection']='[1,0]';edge.rotation_euler.z=math.pi*.5;bpy.context.view_layer.update()
    check(abs(levels.entity_json(edge)['passDirection'][1]-1)<1e-6,'custom gate direction follows the edited object rotation')
    edge['game_passDirection']=before_direction;edge.rotation_euler.z=before_rotation;bpy.context.view_layer.update()
    duplicate=next(o for o in scene.objects if o.get('pb_kind')=='lamps').copy();scene.collection.objects.link(duplicate)
    try:levels.validate(levels.table_dict(scene));raise AssertionError('duplicate IDs accepted')
    except ValueError as e:check('Duplicate' in str(e),'duplicate gameplay IDs rejected')
    bpy.data.objects.remove(duplicate,do_unlink=True)
    bad=copy.deepcopy(table);bad['rules']['groups'][0]['members'].append('missing-object')
    try:levels.validate(bad);raise AssertionError('dangling group accepted')
    except ValueError as e:check('missing objects' in str(e),'dangling rule reference rejected')
    new=levels.add_element(scene,'bumpers',Vector((.5,1.3,0)));check(new['pb_id'] not in {b['id'] for b in table['bumpers']},'new element gets unique ID');bpy.data.objects.remove(new,do_unlink=True)
    levels.write_table(scene,Path('/tmp')/(root['pb_id']+'-blender-roundtrip.json'))
# Kit parts stay editable: a line or outline and live modifiers, not a baked mesh.
kit={o['asset_name']:o for o in bpy.data.objects if 'asset_name' in o}
for name,kinds in (('bumper-cap',{'SCREW','EDGE_SPLIT','NODES'}),('bumper-base',{'SCREW'}),('spot-target',{'SCREW'}),('insert-bezel',{'SCREW'}),('rollover-plate',{'NODES'}),('target',{'SOLIDIFY'})):
    found={m.type for child in kit[name].children for m in child.modifiers}
    check(kinds<=found,name+' is built from modifiers')
cap=next(c for c in kit['bumper-cap'].children if 'painted' in c.name)
bpy.context.window.scene=cap.users_scene[0]
deps=bpy.context.evaluated_depsgraph_get();evaluated=cap.evaluated_get(deps);mesh=evaluated.to_mesh()
check(mesh.uv_layers.active is not None,'the modifier stack maps the painted art')
us=[l.uv[0] for l in mesh.uv_layers.active.data];check(max(us)-min(us)>.5,'art spans the cap');evaluated.to_mesh_clear()
screw=next(m for m in cap.modifiers if m.type=='SCREW');before=len(evaluated.to_mesh().polygons);evaluated.to_mesh_clear();screw.steps=24;bpy.context.view_layer.update()
deps=bpy.context.evaluated_depsgraph_get();evaluated=cap.evaluated_get(deps);after=len(evaluated.to_mesh().polygons);evaluated.to_mesh_clear()
check(after<before,'changing a modifier changes the part');screw.steps=64
# The grey bar can go on any object, and tells the game whether a rollover shows one.
for scene in [s for s in bpy.data.scenes if s.get('pb_level_authoring')]:
    bpy.context.window.scene=scene
    lane=next(o for o in scene.objects if o.get('pb_kind')=='rollovers')
    check(modifier.find_rollover_bar(lane) is not None and levels.entity_json(lane)['plate'] is True,'rollover has its bar modifier')
    m=modifier.find_rollover_bar(lane);m.show_viewport=False;check(levels.entity_json(lane)['plate'] is False,'a disabled bar exports no plate');m.show_viewport=True
# The mesh floor has straight vertical walls and distinct inward-facing bands.
mesh=build_track([(0,0,.1),(0,.4,.1),(0,.8,.15)],TrackSpec())
check({'channel_floor','channel_entry','channel_liner','accent','channel_arrow'}<=set(mesh.roles),'distinct floor, inner wall, rail and arrow materials')
for a in mesh.metadata['arrows']:
    face=next(f for f,r in zip(mesh.faces,mesh.roles) if r=='channel_arrow' and (sum(mesh.vertices[i][1] for i in f)/3-a['centre'][1])**2<1e-8)
    center=sum((Vector(mesh.vertices[i]) for i in face),Vector())/3
    check((center.xy-Vector(a['centre']).xy).length<1e-6,'triangle geometric centroid is centered')
print('PINBALL BUILDER PASSED:',len(checks),'checks; both full levels round-trip; no object leaks')
Path('/tmp/pinball-builder-tests.json').write_text(json.dumps({'checks':len(checks),'status':'passed'},indent=2))
