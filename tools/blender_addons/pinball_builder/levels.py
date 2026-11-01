"""Round-trip gameplay tables as typed Blender objects, including physics and rules."""
import copy
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import shutil
import tempfile
import sys
import bpy
from mathutils import Matrix, Vector
from . import curve_points, configure_track, configure_wall, rebuild_track, object_from_mesh_data, ensure_material
from .geometry import TrackSpec, MeshData, arc_lengths, sample, trimmed, build_track, clear_support, entrance_lamp, funnel_walls
from . import pathing

SPOTS=('posts','bumpers','rollovers','saucers','kickbacks','magnets','captiveBalls','flashers')
EDGES=('slingshots','dropTargets','standups','spinners','gates')
ARRAYS=('walls',)+SPOTS+EDGES+('flippers','ramps','lamps','plastics','decor')
GEOMETRIC={'x','y','points','pivot','a','b','angle','restAngle'}


def encode(value):
    return json.dumps(value,separators=(',',':')) if isinstance(value,(list,dict)) else value


def decode(value,original):
    return json.loads(value) if isinstance(original,(list,dict)) and isinstance(value,str) else value


def points_2d(entries):
    out=[]
    for p in entries:
        if isinstance(p,dict):
            cx,cy,r,start,end,count=p['arc']
            out.extend([(cx+r*math.cos(math.radians(start+(end-start)*i/count)),cy+r*math.sin(math.radians(start+(end-start)*i/count))) for i in range(count+1)])
        else:out.append(p)
    return out


def poly(name,points,collection,closed=False):
    c=bpy.data.curves.new(name,'CURVE');c.dimensions='3D';s=c.splines.new('POLY');s.points.add(len(points)-1)
    for p,co in zip(s.points,points):p.co=(*co[:2],co[2] if len(co)>2 else 0,1)
    s.use_cyclic_u=closed
    obj=bpy.data.objects.new(name,c);collection.objects.link(obj);return obj



def bezier_path(name,points,collection,tolerance=.0002):
    """Fit a compact C1 Bézier controller to the imported dense legacy spline."""
    pts=[Vector(p) for p in points];tangents=[(pts[min(i+1,len(pts)-1)]-pts[max(0,i-1)]).normalized() for i in range(len(pts))]
    lengths=arc_lengths(pts);pieces=[]
    def fit(first,last):
        a,b=pts[first],pts[last];span=lengths[last]-lengths[first]
        if span<=1e-8:raise ValueError('Repeated ramp points')
        c00=c01=c11=x0=x1=0
        for i in range(first,last+1):
            t=(lengths[i]-lengths[first])/span;u=1-t;b0=u**3;b1=3*u*u*t;b2=3*u*t*t;b3=t**3
            v=tangents[first]*b1;w=-tangents[last]*b2;r=pts[i]-a*(b0+b1)-b*(b2+b3)
            c00+=v.dot(v);c01+=v.dot(w);c11+=w.dot(w);x0+=v.dot(r);x1+=w.dot(r)
        det=c00*c11-c01*c01
        alpha=(x0*c11-x1*c01)/det if abs(det)>1e-12 else span/3
        beta=(x1*c00-x0*c01)/det if abs(det)>1e-12 else span/3
        if min(alpha,beta)<span*.001:alpha=beta=span/3
        left=a+tangents[first]*alpha;right=b-tangents[last]*beta
        worst=0;split=(first+last)//2
        for i in range(first+1,last):
            t=(lengths[i]-lengths[first])/span;u=1-t;q=a*u**3+left*(3*u*u*t)+right*(3*u*t*t)+b*t**3
            error=(pts[i]-q).length
            if error>worst:worst=error;split=i
        if worst>tolerance and last-first>2:fit(first,split);fit(split,last)
        else:pieces.append((a,left,right,b))
    fit(0,len(pts)-1)
    curve=bpy.data.curves.new(name,'CURVE');curve.dimensions='3D';curve.resolution_u=32
    spline=curve.splines.new('BEZIER');spline.bezier_points.add(len(pieces))
    for i,piece in enumerate(pieces):
        a,left,right,b=piece;p=spline.bezier_points[i];q=spline.bezier_points[i+1]
        p.co=a;p.handle_left_type=p.handle_right_type='FREE';p.handle_right=left
        q.co=b;q.handle_left_type=q.handle_right_type='FREE';q.handle_left=right
    spline.bezier_points[0].handle_left=pieces[0][0]*2-pieces[0][1]
    spline.bezier_points[-1].handle_right=pieces[-1][3]*2-pieces[-1][2]
    obj=bpy.data.objects.new(name,curve);collection.objects.link(obj);return obj

def root_for(scene):
    return next((o for o in scene.objects if o.get('pb_kind')=='table'),None)


def geom_signature(obj):
    data=[list(obj.location),list(obj.rotation_euler),list(obj.scale),[list(row) for row in obj.matrix_parent_inverse]]
    if obj.type=='CURVE':
        for s in obj.data.splines:
            data.append([s.type,s.use_cyclic_u])
            if s.type=='BEZIER':data.extend([list(p.co)+list(p.handle_left)+list(p.handle_right) for p in s.bezier_points])
            else:data.extend(list(p.co) for p in s.points)
    return hashlib.sha256(json.dumps(data).encode()).hexdigest()


def metadata(obj,kind,item):
    obj['pb_kind']=kind;obj['pb_id']=item.get('id',kind);obj['pb_definition']=json.dumps(item)
    for key,value in item.items():
        if key not in GEOMETRIC and key not in ('id','authoring') and value is not None:obj['game_'+key]=encode(value)
    obj['pb_source_signature']=geom_signature(obj)


def original(obj):
    item=json.loads(obj.get('pb_definition','{}'));item['id']=obj.get('pb_id',obj.name)
    for key,value in list(item.items()):
        if 'game_'+key in obj:item[key]=decode(obj['game_'+key],value)
    # Newly-created fields can be added as game_* custom properties too.
    for key in obj.keys():
        if key.startswith('game_') and key[5:] not in item:item[key[5:]]=obj[key]
    return item


def rounded(p):return [round(float(v),6) for v in p]


def entity_json(obj):
    kind=obj['pb_kind'];item=original(obj);changed=geom_signature(obj)!=obj.get('pb_source_signature')
    matrix=obj.matrix_local
    if kind=='ramps':
        spec=__import__(__package__,fromlist=['spec_for']).spec_for(obj)
        item['width']=spec.width
        path=trimmed(curve_points(obj),spec.trim_start,spec.trim_end)
        item['points']=[rounded(p) for p in path]
        p,t,n=sample(path,arc_lengths(path),0)
        half=spec.width*.5*(spec.flare if spec.entrance=='FLARED' else 1)
        item['mouth']=[rounded(p.xy-n*half),rounded(p.xy+n*half)]
        item['plasticUntil']=max(0,len(path)-1)
        params=spec.to_dict();params['trim_start']=params['trim_end']=0;params['path_sampled']=True
        item['authoring']=params
    elif kind in ('walls','plastics'):
        from . import modifier
        wall=modifier.read_wall(obj) if obj.type=='CURVE' else None
        if wall:item['radius'],item['height']=round(wall[0],6),round(wall[1],6)
        if changed or 'points' not in item:
            spline=obj.data.splines[0]
            if spline.type=='POLY':points=[matrix@Vector(p.co[:3]) for p in spline.points]
            else:points=curve_points(obj)
            item['points']=[rounded(p.xy) for p in points]
            item['closed']=spline.use_cyclic_u
    elif kind in EDGES:
        points=[matrix@Vector(p.co[:3]) for p in obj.data.splines[0].points]
        item['a'],item['b']=rounded(points[0].xy),rounded(points[-1].xy)
    elif kind=='flippers':
        item['pivot']=rounded(matrix.translation.xy)
        base=json.loads(obj.get('pb_definition','{}'));rotation=math.degrees(obj.rotation_euler.z)
        original_angle=base.get('restAngle',rotation)
        item['restAngle']=round(rotation,6);item['activeAngle']=round(item.get('activeAngle',rotation)+rotation-original_angle,6)
        for key,axis in (('length',0),('baseRadius',1),('tipRadius',1)):item[key]=round(item[key]*abs(obj.scale[axis]),6)
    elif kind=='plunger':
        item.pop('id',None);item['x'],item['y']=rounded(matrix.translation.xy)
        item['width']=round(item['width']*abs(obj.scale.x),6)
    elif kind in SPOTS+('lamps','decor'):
        item['x'],item['y']=rounded(matrix.translation.xy)
        for key in ('r','radius','size'):
            if key in item:item[key]=round(item[key]*max(abs(obj.scale.x),abs(obj.scale.y)),6)
        if kind in ('lamps','decor') and 'angle' in item and changed:item['angle']=round(math.degrees(obj.rotation_euler.z),6)
        if kind=='decor':item['base']=round(obj.location.z,6)
    if kind=='rollovers':
        from . import modifier
        bar=modifier.find_rollover_bar(obj)
        item['plate']=bool(bar and bar.show_viewport)
    for key in ('passDirection','ejectDirection'):
        if key in item:
            direction=matrix.to_3x3()@Vector((*item[key],0))
            if direction.xy.length<1e-6:raise ValueError(obj.name+': '+key+' must be nonzero')
            if changed:item[key]=rounded(direction.xy.normalized())
    return item


def table_dict(scene):
    root=root_for(scene)
    if not root:raise ValueError('Import or create a pinball table in this scene first')
    bpy.context.view_layer.update()
    table=json.loads(root['pb_definition']);table['id']=root['pb_id']
    if not re.fullmatch(r'[a-z0-9_-]{1,40}',table['id']):raise ValueError('Table ID must contain only lower-case letters, digits, _ or -')
    for key in ('name','defaultSkin','size','apron'):
        if 'game_'+key in root:table[key]=decode(root['game_'+key],table.get(key))
    for group,prefix in (('physics','physics_'),('rules','rule_')):
        for key,value in list(table[group].items()):
            if key not in ('groups','scores') and 'game_'+prefix+key in root:table[group][key]=decode(root['game_'+prefix+key],value)
    for key in table['rules']['scores']:
        if 'game_score_'+key in root:table['rules']['scores'][key]=root['game_score_'+key]
    for key in ARRAYS:table[key]=[]
    table['rules']['groups']=[]
    for obj in scene.objects:
        kind=obj.get('pb_kind')
        if kind in ARRAYS:table[kind].append(entity_json(obj))
        elif kind=='groups':table['rules']['groups'].append(original(obj))
        elif kind=='plunger':table['plunger']=entity_json(obj)
    # Each ramp owns its entrance lamp, so moving the curve moves the lamp.
    from . import spec_for
    # Its funnel too: the walls the ball meets must be where the mesh draws them.
    for obj in scene.objects:
        if obj.get('pb_kind')=='ramps' and spec_for(obj).entrance_funnel:
            spec=spec_for(obj);path=trimmed(curve_points(obj),spec.trim_start,spec.trim_end)
            for line,side in zip(funnel_walls(path,spec),'LR'):
                table['walls'].append({'id':obj['pb_id']+'Funnel'+side,'ramp':obj['pb_id'],'style':'none','radius':.006,'height':spec.wall_height,'layers':['playfield'],'points':[rounded(p) for p in line]})
    for obj in scene.objects:
        if obj.get('pb_kind')=='ramps' and spec_for(obj).entrance_lamp:
            spec=spec_for(obj);centre,heading=entrance_lamp(trimmed(curve_points(obj),spec.trim_start,spec.trim_end),spec,table)
            table['lamps'].append({'id':'lamp'+obj['pb_id'][0].upper()+obj['pb_id'][1:],'ramp':obj['pb_id'],'x':round(centre.x,6),'y':round(centre.y,6),
                                   'size':round(spec.entrance_lamp_size,6),'color':'magenta','icon':7,'bind':'rampHot','shape':'arrow',
                                   'angle':round(math.degrees(math.atan2(heading.y,heading.x)),6)})
    for obj in scene.objects:
        if obj.get('pb_kind')=='ramps':
            generated=build_track(curve_points(obj),spec_for(obj),lambda xy,r,tight=False:clear_support(table,xy,r,tight))
            entry=next(r for r in table['ramps'] if r['id']==obj['pb_id'])
            entry['authoring']['columns']=[rounded(p) for p in generated.metadata['support_centres']]
    return table


def validate(table):
    def finite(value):
        if isinstance(value,dict):return all(finite(v) for v in value.values())
        if isinstance(value,list):return all(finite(v) for v in value)
        return math.isfinite(value) if isinstance(value,(int,float)) else True
    if not finite(table):raise ValueError('Gameplay values must be finite')
    if min(table['size'])<=0 or min(table['physics']['gravity'],table['physics']['plungerSpeed'])<=0:raise ValueError('Table size, gravity and launch speed must be positive')
    ids=[]
    for key in ARRAYS:
        for item in table.get(key,[]):
            if not item.get('id'):raise ValueError(f'{key}: missing gameplay ID')
            if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_-]{0,63}',item['id']):raise ValueError('Object IDs must start with a letter and contain letters, digits, _ or -: '+item['id'])
            ids.append(item['id'])
            for field in ('r','radius','size','length','baseRadius','tipRadius'):
                if field in item and item[field]<=0:raise ValueError(item['id']+': '+field+' must be positive')
            if key=='flippers' and not item['length']>item['baseRadius']+item['tipRadius']:raise ValueError(item['id']+': flipper length is too short')
    duplicates={key for key in ids if ids.count(key)>1}
    if duplicates:raise ValueError('Duplicate object IDs: '+', '.join(sorted(duplicates)))
    all_ids=set(ids);lamps={x['id'] for x in table['lamps']}
    if len(table['flippers'])<2:raise ValueError('A playable table needs two flippers')
    if not table['walls']:raise ValueError('A playable table needs boundary colliders')
    if table['physics']['ballRadius']<=0:raise ValueError('Ball radius must be positive')
    if table['rules']['balls']<=0:raise ValueError('Rules must allow at least one ball')
    groups=table['rules']['groups'];group_ids=[g['id'] for g in groups]
    if len(set(group_ids))!=len(group_ids):raise ValueError('Duplicate rule group IDs')
    target=table['rules'].get('skillShotTarget')
    if target and target not in all_ids:raise ValueError('Skill shot references a missing object: '+target)
    allowed={'bonusX','resetGroup','lightLock','resetDrops','armKickback','armMagnet','addBonus'}
    flashers={f['id'] for f in table['flashers']}
    for group in table['rules']['groups']:
        if not group.get('members'):raise ValueError('Rule group '+group['id']+' needs at least one member')
        missing=set(group['members'])-all_ids
        if missing:raise ValueError(f"Rule group {group['id']} references missing objects: {sorted(missing)}")
        missing=set(group.get('lamps',[]))-lamps
        if missing:raise ValueError(f"Rule group {group['id']} references missing lamps: {sorted(missing)}")
        for action in group.get('actions',[]):
            if action.startswith('flash:'):
                if action[6:] not in flashers:raise ValueError('Rule action references a missing flasher: '+action)
            elif action not in allowed:raise ValueError('Unknown rule action: '+action)
    for ramp in table['ramps']:
        corner=ramp.get('authoring',{}).get('corner_radius',.0035)
        if ramp['width']<=table['physics']['ballRadius']*2+corner*2+.005:raise ValueError(f"{ramp['id']}: channel is too narrow for the ball")
        if len(ramp.get('points',[]))<2:raise ValueError(f"{ramp['id']}: incomplete path")
    return table


def template_parts(name):
    root=next((o for o in bpy.data.objects if o.get('asset_name')==name),None)
    if not root:return []
    deps=bpy.context.evaluated_depsgraph_get();out=[]
    for obj in root.children_recursive:
        if obj.type not in ('MESH','CURVE'):continue
        if obj.type=='CURVE' and not obj.pb_track.enabled:continue
        evaluated=obj.evaluated_get(deps);mesh=evaluated.to_mesh()
        if not mesh:continue
        transform=root.matrix_world.inverted()@obj.matrix_world
        vertices=[tuple(transform@v.co) for v in mesh.vertices]
        faces=[tuple(p.vertices) for p in mesh.polygons]
        roles=[mesh.materials[p.material_index].get('pb_surface_role',obj.get('surface_role','metal')) for p in mesh.polygons]
        uv=[(0,0)]*len(vertices)
        if mesh.uv_layers.active:
            for loop in mesh.loops:uv[loop.vertex_index]=tuple(mesh.uv_layers.active.data[loop.index].uv)
        out.append((vertices,faces,roles,uv));evaluated.to_mesh_clear()
    return out


def proxy_data(kind,item,table):
    data=MeshData()
    templates=[];scale=1
    if kind=='bumpers':templates=['bumper-base','bumper-cap'];scale=item['r']
    elif kind=='flippers':templates=[table['id']+'-flipper'];scale=item['length']
    elif kind=='decor':templates=[item['model']];scale=item['size']
    elif kind=='posts':templates=[item.get('model','post')];scale=item.get('r',.012)
    if templates:
        for name in templates:
            for vertices,faces,roles,uv in template_parts(name):data.add([(x*scale,y*scale,z*scale) for x,y,z in vertices],faces,roles,uv,65)
        if data.faces:return data
    radius=item.get('r',item.get('size',.018))
    if kind=='magnets':radius=.054
    if kind=='lamps':
        color=table.get('_lamp_colors',{}).get(item.get('color'),(.1,.6,.8))
        role='preview_'+item.get('color','white');material=ensure_material(role);material.diffuse_color=(*color,1)
        bsdf=material.node_tree.nodes.get('Principled BSDF');bsdf.inputs['Base Color'].default_value=(*color,1);bsdf.inputs['Emission Color'].default_value=(*color,1);bsdf.inputs['Emission Strength'].default_value=.35
        data.lathe((0,0),[(radius*1.08,0),(radius*1.08,.0015),(radius,.003)],'channel_aluminum',24)
        data.lathe((0,0),[(radius,.002),(radius*.75,.0035),(.0001,.004)],role,24)
    elif kind=='plunger':
        data.lathe((0,0),[(item['width']*.25,0),(item['width']*.25,.012),(.0001,.014)],'channel_aluminum',20)
    else:
        data.lathe((0,0),[(radius,0),(radius,.009),(radius*.65,.016),(.0001,.02)],'channel_aluminum' if kind!='rollovers' else 'dark',20)
    return data


def import_level(path,project_root='',scene_name=None):
    table=json.loads(Path(path).read_text());project=Path(project_root or Path(path).resolve().parents[2])
    master=project/'Art/Models/premium-hardware.blend'
    if master.exists() and not any(o.get('asset_name')=='bumper-cap' for o in bpy.data.objects):
        with bpy.data.libraries.load(str(master),link=False) as (available,loaded):loaded.scenes=[n for n in available.scenes if n.startswith('Pinball • machined hardware')]
    skin_path=project/'GameData/Skins'/(table.get('defaultSkin','orbital')+'.json')
    skin=json.loads(skin_path.read_text()) if skin_path.exists() else {}
    scene=bpy.data.scenes.new(scene_name or 'Level • '+table['name']);scene['pb_level_authoring']=True
    bpy.context.window.scene=scene;scene.pb_project_root=str(project)
    root=bpy.data.objects.new('Table • '+table['id'],None);scene.collection.objects.link(root)
    root['pb_kind']='table';root['pb_id']=table['id'];root['pb_definition']=json.dumps(table)
    root.lock_location=root.lock_rotation=root.lock_scale=(True,True,True)
    for key in ('name','defaultSkin','size','apron'):
        if key in table:root['game_'+key]=encode(table[key])
    for group,prefix in (('physics','physics_'),('rules','rule_')):
        for key,value in table[group].items():
            if key not in ('groups','scores'):root['game_'+prefix+key]=encode(value)
    for key,value in table['rules']['scores'].items():root['game_score_'+key]=value
    groups={}
    for key in ARRAYS+('plunger','groups'):
        collection=bpy.data.collections.new(key.title());scene.collection.children.link(collection);groups[key]=collection
    augmented=copy.deepcopy(table);augmented['_lamp_colors']=skin.get('lamps',{})
    for kind in ARRAYS+('plunger','groups'):
        entries=table.get(kind,[]) if kind not in ('plunger','groups') else [table['plunger']] if kind=='plunger' else table['rules']['groups']
        for index,item in enumerate(entries):
            if kind in ('lamps','walls') and 'ramp' in item:continue  # Generated from its ramp on export.
            name=f"{kind[:-1] if kind.endswith('s') else kind} • {item.get('id','plunger')}"
            if kind=='ramps':
                points=pathing.ramp_path(item)
                obj=bezier_path(name,points,groups[kind]);obj.parent=root
                spec=TrackSpec.from_dict({'width':item['width'],**item.get('authoring',{})})
                configure_track(obj,spec);rebuild_track(obj)
            elif kind in ('walls','plastics'):
                obj=poly(name,points_2d(item['points']),groups[kind],item.get('closed',kind=='plastics'))
                obj.parent=root
                if item.get('style')=='none':obj.hide_render=True;obj.color=(1,.3,.05,1)
                elif kind=='walls' and item.get('style') in ('wall','rail','rubber'):
                    # A line and a modifier: edit the points, and thickness and height in the modifier.
                    configure_wall(obj,item['radius'],item.get('height',.03))
                else:
                    # Native curve preview; gameplay dimensions stay on the object.
                    obj.data.bevel_depth=item.get('radius',.003);obj.data.bevel_resolution=1;obj.data.use_fill_caps=True
                    obj.data.materials.append(ensure_material('channel_shell'))
            elif kind in EDGES:
                obj=poly(name,[item['a'],item['b']],groups[kind]);obj.parent=root
                obj.data.bevel_depth=.004;obj.data.bevel_resolution=1;obj.data.materials.append(ensure_material('channel_aluminum'))
            elif kind=='groups':
                obj=bpy.data.objects.new(name,None);groups[kind].objects.link(obj);obj.parent=root;obj.hide_render=True;obj.empty_display_size=.025
            else:
                data=proxy_data(kind,item,augmented);obj=object_from_mesh_data(name,data,groups[kind]);obj['pb_generated']=False;obj.hide_select=False;obj.parent=root
                if kind=='flippers':obj.location=(*item['pivot'],0);obj.rotation_euler.z=math.radians(item['restAngle'])
                else:obj.location=(item.get('x',0),item.get('y',0),item.get('base',0));obj.rotation_euler.z=math.radians(item.get('angle',0))
            metadata(obj,kind,item)
            if kind=='rollovers' and item.get('plate',True):
                from . import modifier
                modifier.attach_rollover_bar(obj,ensure_material('plate_frame'),ensure_material('dark'))
    # Backdrop is a visual guide, with no gameplay type or collision data.
    slots=skin.get('atlasLayout',{}).get('slots',{})
    if 'playfield' in slots:
        image_path=project/'GameData/Skins'/slots['playfield']['file']
        image=bpy.data.images.load(str(image_path),check_existing=True)
        w,h=table['size'];mesh=bpy.data.meshes.new('Playfield');mesh.from_pydata([(0,0,-.002),(w,0,-.002),(w,h,-.002),(0,h,-.002)],[],[(0,1,2,3)])
        uv=mesh.uv_layers.new()
        for loop,coord in zip(mesh.loops,[(0,0),(1,0),(1,1),(0,1)]):uv.data[loop.index].uv=coord
        material=bpy.data.materials.new('Playfield • '+table['id']);material.use_nodes=True
        texture=material.node_tree.nodes.new('ShaderNodeTexImage');texture.image=image
        material.node_tree.links.new(texture.outputs['Color'],material.node_tree.nodes['Principled BSDF'].inputs['Base Color']);mesh.materials.append(material)
        floor=bpy.data.objects.new('Playfield artwork',mesh);scene.collection.objects.link(floor);floor.parent=root;floor.hide_select=True
    scene.unit_settings.system='METRIC'
    scene['pb_source_file']=str(path)
    catalog=project/'GameData/Levels.json'
    if catalog.exists():root['game_campaign']=json.dumps([level for level in json.loads(catalog.read_text())['levels'] if level['table']==table['id']])
    for obj in [o for o in scene.objects if o.type=='CURVE' and o.pb_track.enabled]:rebuild_track(obj)
    setup_view(scene,table)
    return scene


def write_table(scene,destination):
    table=validate(table_dict(scene));destination=Path(destination);destination.parent.mkdir(parents=True,exist_ok=True)
    temp=destination.with_suffix('.pending.json');temp.write_text(json.dumps(table,indent=1)+'\n');temp.replace(destination)
    return table


def export_playable(scene,project):
    project=Path(project).resolve();builder=project/'tools/build_hardware_models.py';validator=project/'tools/validate_level.sh'
    if not builder.is_file() or not validator.is_file():raise ValueError('Choose the Pinball project folder (with tools/build_hardware_models.py and tools/validate_level.sh)')
    table=validate(table_dict(scene));root=root_for(scene)
    # All native checks and model conversion happen in staging. A rejected export leaves the game untouched.
    with tempfile.TemporaryDirectory(prefix='pinball-export-') as temporary:
        stage=Path(temporary);(stage/'GameData').mkdir();(stage/'Art').mkdir()
        shutil.copytree(project/'GameData/Tables',stage/'GameData/Tables')
        (stage/'GameData/Skins').symlink_to(project/'GameData/Skins',target_is_directory=True)
        (stage/'Art/Masters').symlink_to(project/'Art/Masters',target_is_directory=True)
        target=stage/'GameData/Tables'/(table['id']+'.json');write_table(scene,target)
        catalog=json.loads((project/'GameData/Levels.json').read_text())
        entries=json.loads(root.get('game_campaign','[]'))
        if not entries:entries=[dict(id=table['id']+'_01',name=table['name'],table=table['id'],skin=table['defaultSkin'],goal='score',count=15000,stars=[50000,120000])]
        entry_ids=[e['id'] for e in entries]
        if len(set(entry_ids))!=len(entry_ids):raise ValueError('Duplicate campaign level IDs')
        if any(e['table']!=table['id'] and e['id'] in entry_ids for e in catalog['levels']):raise ValueError('Campaign IDs belong to another table; give copied campaign entries new IDs')
        for entry in entries:entry['table']=table['id']
        replaced={e['id'] for e in entries};catalog['levels']=[e for e in catalog['levels'] if e['table']!=table['id'] and e['id'] not in replaced]+entries
        # Keep existing campaign order stable.
        old_order={e['id']:i for i,e in enumerate(json.loads((project/'GameData/Levels.json').read_text())['levels'])}
        catalog['levels'].sort(key=lambda e:old_order.get(e['id'],len(old_order)))
        for level in catalog['levels']:
            if not (stage/'GameData/Tables'/(level['table']+'.json')).is_file():raise ValueError('Campaign references missing table: '+level['table'])
            if not (project/'GameData/Skins'/(level['skin']+'.json')).is_file():raise ValueError('Campaign references missing skin: '+level['skin'])
        (stage/'GameData/Levels.json').write_text(json.dumps(catalog,indent=2)+'\n')
        check=subprocess.run(['zsh',str(validator),str(target),str(stage/'GameData/Levels.json')],cwd=project,text=True,capture_output=True,timeout=180)
        if check.returncode:raise ValueError(check.stdout[-4000:]+check.stderr[-4000:])
        env=dict(os.environ,PB_PROJECT_ROOT=str(stage))
        build=subprocess.run([bpy.app.binary_path,'--background','--factory-startup','--python-exit-code','1','--python',str(builder)],env=env,cwd=project,text=True,capture_output=True,timeout=240)
        if build.returncode:raise ValueError('Mesh export failed: '+build.stderr[-2000:]+build.stdout[-2000:])
        compiled=subprocess.run(['zsh',str(project/'tools/compile_models.sh')],env=env,cwd=project,text=True,capture_output=True,timeout=180)
        if compiled.returncode:raise ValueError('SceneKit compilation failed: '+compiled.stderr[-2000:])
        deliver=[target,stage/'GameData/Levels.json',stage/'Art/Models/manifest.json',stage/'Art/Models/premium-hardware.blend']
        deliver+=list((stage/'Art/Models/premium').glob('*.dae'))+list((stage/'GameData/Models/premium').glob('*.scn'))
        for source in deliver:
            destination=project/source.relative_to(stage);destination.parent.mkdir(parents=True,exist_ok=True)
            pending=destination.with_name(destination.name+'.pending');shutil.copyfile(source,pending);pending.replace(destination)
    return f"Exported playable table {table['id']}: gameplay, campaign and compiled models"


def unique_id(scene,prefix):
    used={o.get('pb_id') for o in scene.objects};index=1
    while prefix+str(index) in used:index+=1
    return prefix+str(index)


def add_element(scene,kind,position):
    root=root_for(scene)
    if not root:raise ValueError('Import a game table first')
    table=table_dict(scene);entries=table['rules']['groups'] if kind=='groups' else table.get(kind,[])
    if not entries:entries=json.loads(root['pb_definition'])['rules']['groups'] if kind=='groups' else json.loads(root['pb_definition']).get(kind,[])
    if not entries:raise ValueError('Duplicate a template of this type from another imported table')
    item=copy.deepcopy(entries[0]);item['id']=unique_id(scene,kind.rstrip('s'))
    collection=next((c for c in scene.collection.children if c.name.split('.')[0]==kind.title()),scene.collection)
    if kind in EDGES:
        midpoint=(Vector(item['a'])+Vector(item['b']))*.5
        points=[Vector(item[k])-midpoint+Vector(position[:2]) for k in ('a','b')]
        obj=poly(kind,points,collection);obj.data.bevel_depth=.004;obj.data.bevel_resolution=1;obj.data.materials.append(ensure_material('channel_aluminum'))
    elif kind in ('walls','plastics'):
        pts=[(position.x-.05,position.y,position.z),(position.x+.05,position.y,position.z)] if kind=='walls' else [(position.x-.04,position.y-.04,position.z),(position.x+.04,position.y-.04,position.z),(position.x,position.y+.04,position.z)]
        obj=poly(kind,pts,collection,kind=='plastics');obj.data.bevel_depth=.003;obj.data.bevel_resolution=1;obj.data.materials.append(ensure_material('channel_shell'));item['style']='wall' if kind=='walls' else item.get('style','plastic')
    elif kind=='groups':
        obj=bpy.data.objects.new(kind,None);collection.objects.link(obj);item['members']=[];item['lamps']=[]
    else:
        if kind=='flippers':item['pivot']=list(position[:2])
        else:item['x'],item['y']=position[:2]
        obj=object_from_mesh_data(kind,proxy_data(kind,item,table),collection);obj['pb_generated']=False;obj.hide_select=False
        obj.location=position
        if kind=='flippers':obj.rotation_euler.z=math.radians(item['restAngle'])
    obj.parent=root;obj.name=kind+' • '+item['id'];metadata(obj,kind,item)
    # New edge/path geometry must replace the copied template coordinates on export.
    if kind in EDGES+('walls','plastics'):obj['pb_source_signature']='new'
    return obj


def refresh_level(scene):
    table=table_dict(scene)
    for obj in [o for o in scene.objects if o.get('pb_kind')]:
        kind=obj.get('pb_kind')
        if kind=='ramps':rebuild_track(obj)
        elif kind in SPOTS+('lamps','decor','flippers','plunger'):
            item=entity_json(obj)
            if kind=='flippers':item['length']/=abs(obj.scale.x);item['baseRadius']/=abs(obj.scale.y);item['tipRadius']/=abs(obj.scale.y)
            else:
                for key in ('r','radius','size'):
                    if key in item:item[key]/=max(abs(obj.scale.x),abs(obj.scale.y))
            generated=object_from_mesh_data('Updated preview',proxy_data(kind,item,table),scene.collection)
            old=obj.data;obj.data=generated.data;bpy.data.objects.remove(generated,do_unlink=True)
            if old.users==0:bpy.data.meshes.remove(old)
        elif kind=='walls':obj.data.bevel_depth=original(obj).get('radius',.003)


def setup_view(scene,table):
    w,h=table['size'];scene.render.engine='CYCLES';scene.cycles.samples=24
    scene.render.resolution_x=804;scene.render.resolution_y=1743;scene.render.resolution_percentage=100
    camera=bpy.data.cameras.new('Gameplay camera');camera.type='ORTHO';camera.ortho_scale=h*1.04
    obj=bpy.data.objects.new('Gameplay camera',camera);scene.collection.objects.link(obj);scene.camera=obj
    target=Vector((w*.5,h*.5,0));obj.location=target+Vector((0,-math.sin(math.radians(18))*4,math.cos(math.radians(18))*4));obj.rotation_euler=(target-obj.location).to_track_quat('-Z','Y').to_euler();obj.hide_select=True
    world=bpy.data.worlds.new('Authoring studio');world.use_nodes=True;world.node_tree.nodes['Background'].inputs['Strength'].default_value=.3;scene.world=world
    for name,offset,power,size in [('Key',(-1,-.3,2),100,2),('Fill',(1,1,1),70,1)]:
        light=bpy.data.lights.new(name,'AREA');light.energy=power;light.shape='DISK';light.size=size
        obj=bpy.data.objects.new(name,light);scene.collection.objects.link(obj);obj.location=target+Vector(offset);obj.rotation_euler=(target-obj.location).to_track_quat('-Z','Y').to_euler();obj.hide_select=True
    for area in bpy.context.screen.areas:
        if area.type=='VIEW_3D':
            area.spaces.active.region_3d.view_perspective='CAMERA';area.spaces.active.shading.type='MATERIAL'
