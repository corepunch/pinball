"""Editable Blender hardware master and SceneKit-ready COLLADA, executed via Blender MCP.

No downloads, simulation caches or external Python packages. Model units: bumper and
insert radius = 1; table-specific ramp uses the same metres/curve as the physics JSON.
"""
import bpy
import json
import math
from pathlib import Path
from mathutils import Matrix, Vector
from xml.etree.ElementTree import Element, SubElement, ElementTree

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "GameData/Models/premium"
OUT.mkdir(parents=True, exist_ok=True)
(ROOT / "Art/Models").mkdir(parents=True, exist_ok=True)
if not bpy.app.background:
    raise RuntimeError('Run this generator in the dedicated background Blender MCP session')
for previous in list(bpy.data.scenes):
    if previous.get('workflow', '').startswith('Authored through the installed Blender MCP bridge'):
        for obj in list(previous.objects): bpy.data.objects.remove(obj, do_unlink=True)
        bpy.data.scenes.remove(previous)
scene = bpy.data.scenes.new("Pinball • machined hardware")
bpy.context.window.scene = scene
scene.unit_settings.system = 'METRIC'
scene['source_reference'] = 'Art/References/premium-pinball-target.png'
scene['workflow'] = 'Authored through the installed Blender MCP bridge; tools/build_hardware_models.py'
materials = {}
colors = {'channel': (.14,.17,.20,1), 'metal': (.56,.61,.65,1), 'accent': (.72,.48,.19,1), 'dark': (.012,.019,.027,1),
          'rubber': (.62,.58,.47,1), 'cap_art': (.7,.2,.12,1), 'ramp_art': (.04,.15,.18,1)}
for name, color in colors.items():
    material = bpy.data.materials.new(name)
    material.diffuse_color = color
    material.use_nodes = True
    bsdf = material.node_tree.nodes.get('Principled BSDF')
    bsdf.inputs['Base Color'].default_value = color
    bsdf.inputs['Metallic'].default_value = .9 if name in ('metal','accent','channel') else 0
    bsdf.inputs['Roughness'].default_value = .28 if name in ('metal','accent','channel') else .38
    materials[name] = material

# Packed texture in the editable master; runtime binds each named material to the selected skin.
palette = json.loads((ROOT/'GameData/Skins/orbital.json').read_text())
atlas = bpy.data.images.load(str(ROOT/'Art/Masters/orbital-hardware.png'))
for name, slot in [('cap_art','bumper_cap'), ('ramp_art','ramp')]:
    mat = materials[name]
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    uv, mapping, texture = nodes.new('ShaderNodeTexCoord'), nodes.new('ShaderNodeMapping'), nodes.new('ShaderNodeTexImage')
    texture.image = atlas
    x,y,w,h = palette['atlasLayout']['slots'][slot]['rect']
    mapping.inputs['Location'].default_value = (x/1254, 1-(y+h)/1254, 0)
    mapping.inputs['Scale'].default_value = (w/1254, h/1254, 1)
    links.new(uv.outputs['UV'], mapping.inputs['Vector'])
    links.new(mapping.outputs['Vector'], texture.inputs['Vector'])
    links.new(texture.outputs['Color'], nodes.get('Principled BSDF').inputs['Base Color'])

assets = {}
current = None
def asset(name, location=(0,0,0), scale=1):
    global current
    root = bpy.data.objects.new(name, None)
    scene.collection.objects.link(root)
    root.location, root.scale = location, (scale,)*3
    root['asset_name'] = name
    assets[name] = (root, [])
    current = name
    return root

def finish(obj, name, material, bevel=0, smooth=True):
    obj.name = name
    # Preserve local primitive dimensions under the kit's presentation transform.
    obj.parent = assets[current][0]
    obj.data.materials.clear()
    obj.data.materials.append(materials[material])
    if bevel:
        mod = obj.modifiers.new('Machined edge radii', 'BEVEL')
        mod.width, mod.segments = bevel, 3
    if smooth:
        for polygon in obj.data.polygons: polygon.use_smooth = True
    obj['surface_role'] = material
    assets[current][1].append(obj)
    return obj

def cylinder(name, radius, depth, z, material, bevel=.02, xy=(0,0), vertices=64):
    bpy.ops.mesh.primitive_cylinder_add(vertices=vertices, radius=radius, depth=depth, location=(*xy,z))
    return finish(bpy.context.object,name,material,bevel)

def torus(name, major, minor, z, material, xy=(0,0)):
    bpy.ops.mesh.primitive_torus_add(major_radius=major, minor_radius=minor, major_segments=64,
                                   minor_segments=10, location=(*xy,z))
    return finish(bpy.context.object,name,material)

def lathe(name, profile, material, segments=64):
    vertices, faces = [], []
    for radius,z in profile:
        vertices.extend((radius*math.cos(s*2*math.pi/segments), radius*math.sin(s*2*math.pi/segments), z) for s in range(segments))
    for row in range(len(profile)-1):
        for s in range(segments):
            a=row*segments+s; b=row*segments+(s+1)%segments
            faces.append((a,b,b+segments,a+segments))
    mesh=bpy.data.meshes.new(name);mesh.from_pydata(vertices,[],faces);mesh.update()
    obj=bpy.data.objects.new(name,mesh);scene.collection.objects.link(obj)
    uv=mesh.uv_layers.new(name='Surface projection')
    for polygon in mesh.polygons:
        for loop in polygon.loop_indices:
            p=mesh.vertices[mesh.loops[loop].vertex_index].co
            uv.data[loop].uv=(.5+p.x/1.96,.5+p.y/1.96)
    return finish(obj,name,material)

asset('bumper-base',(-2.5,0,0))
cylinder('Foot • bevelled chrome',1.07,.095,.06,'metal',.025)
torus('Lower protective bead',1.01,.035,.11,'accent')
torus('Impact cushion',.94,.075,.20,'rubber')
cylinder('Recessed actuator body',.76,.37,.40,'dark',.025)
cylinder('Upper collar',.89,.12,.63,'accent',.025)
for i in range(20):
    a=2*math.pi*i/20
    cylinder(f'Collar flute {i:02}',.024,.30,.40,'metal',.006, (.765*math.cos(a),.765*math.sin(a)),12)
torus('Upper rolled lip',.94,.035,.69,'metal')

asset('bumper-cap',(-2.5,0,0))
lathe('Enamel crown • atlas surface',[(.98,.69),(.98,.78),(.94,.86),(.84,.94),(.40,1.025),(.32,1.03)],'cap_art')
torus('Outer machined lip',.965,.027,.80,'accent')
torus('Inner concentric fillet',.37,.027,1.04,'accent')
cylinder('Jewel bezel',.31,.10,1.09,'accent',.025)
torus('Jewel seat',.285,.024,1.155,'metal')
bpy.ops.mesh.primitive_uv_sphere_add(segments=48,ring_count=24,radius=.265,location=(0,0,1.155))
dome=bpy.context.object;dome.scale.z=.65
# Real raised jewel, projected into the authored centre of the idle/hit atlas cap.
uv=dome.data.uv_layers.active
for loop in dome.data.loops:
    p=dome.data.vertices[loop.vertex_index].co
    uv.data[loop.index].uv=(.5+p.x/1.96,.5+p.y/1.96)
finish(dome,'Raised jewel • authored atlas centre','cap_art')

asset('insert-bezel',(0,0,0))
lathe('Recessed socket',[(1.08,-.025),(1.08,.0),(1.025,.035),(.965,.035),(.945,.01),(.945,-.025)],'dark')
torus('Hairline bezel',1.018,.018,.027,'accent')
torus('Inner lens retainer',.958,.011,.018,'metal')

table=json.loads((ROOT/'GameData/Tables/aurora.json').read_text())
def smooth_path(points):
    p=[Vector(v) for v in points]; out=[]
    at=lambda n:p[max(0,min(n,len(p)-1))]
    for i in range(len(p)-1):
        p0,p1,p2,p3=at(i-1),at(i),at(i+1),at(i+2)
        for step in range(6):
            t=step/6
            out.append(.5*((2*p1)+(p2-p0)*t+(2*p0-5*p1+4*p2-p3)*t*t+(3*p1-p0-3*p2+p3)*t*t*t))
    return out+[p[-1]]

for ramp in table['ramps']:
    asset(f"{table['id']}-{ramp['id']}",(3,0,0),2.5)
    points=smooth_path(ramp['points'])[:ramp['plasticUntil']*6+1]
    half=ramp['width']*.5+.004
    # U-channel with folded edges and real underside thickness. Floor follows physics exactly.
    section=[(-half-.002,.019),(-half,.023),(-half+.002,.019),(-half+.003,.002),
             (-half+.007,0),(half-.007,0),(half-.003,.002),(half-.002,.019),
             (half,.023),(half+.002,.019),(half+.002,-.002),(-half-.002,-.002)]
    vertices=[]; along=[]; length=0
    for i,p in enumerate(points):
        prev,nxt=points[max(i-1,0)],points[min(i+1,len(points)-1)]
        tangent=(nxt-prev).xy.normalized(); normal=Vector((-tangent.y,tangent.x))
        if i:length+=(p-points[i-1]).length
        along.append(length)
        for offset,z in section:
            vertices.append((p.x-.5+normal.x*offset,p.y-table['size'][1]*.5+normal.y*offset,p.z+z))
    faces=[]; roles=[]; n=len(section)
    for i in range(len(points)-1):
        for j in range(n):
            faces.append((i*n+j,(i+1)*n+j,(i+1)*n+(j+1)%n,i*n+(j+1)%n))
            roles.append('channel' if j in (3,4,5,9,10,11) else 'accent')
    mesh=bpy.data.meshes.new('Continuous folded channel');mesh.from_pydata(vertices,[],faces);mesh.update()
    obj=bpy.data.objects.new('Rolled channel • matched physics spline',mesh);scene.collection.objects.link(obj)
    finish(obj,obj.name,'channel')
    mesh.materials.append(materials['accent'])
    for poly,role in zip(mesh.polygons,roles):poly.material_index=0 if role=='channel' else 1
    # Narrow chevron strip, leaving reflective floor visible around it.
    vertices=[];faces=[]
    for i,p in enumerate(points):
        tangent=(points[min(i+1,len(points)-1)]-points[max(i-1,0)]).xy.normalized()
        normal=Vector((-tangent.y,tangent.x))
        for side in (-1,1):vertices.append((p.x-.5+normal.x*.009*side,p.y-table['size'][1]*.5+normal.y*.009*side,p.z+.0004))
        if i:faces.append(((i-1)*2,i*2,i*2+1,(i-1)*2+1))
    mesh=bpy.data.meshes.new('Inset navigation strip');mesh.from_pydata(vertices,[],faces);mesh.update()
    obj=bpy.data.objects.new('Narrow enamel navigation strip',mesh);scene.collection.objects.link(obj)
    uv=mesh.uv_layers.new(name='Repeating chevrons')
    for loop in mesh.loops:
        vertex=loop.vertex_index;uv.data[loop.index].uv=(vertex%2,along[vertex//2]*5)
    finish(obj,obj.name,'ramp_art')
    for i in range(4,len(points)-2,8):
        p=points[i];tangent=(points[i+1]-points[i-1]).xy.normalized();normal=Vector((-tangent.y,tangent.x))
        for side in (-1,1):
            xy=(p.x-.5+normal.x*(half-.001)*side,p.y-table['size'][1]*.5+normal.y*(half-.001)*side)
            cylinder(f'Flange rivet {i} {side}',.0018,.001,p.z+.024,'metal',.0002,xy,12)

# Standard COLLADA with Y-up coordinates, explicit smooth normals, UVs, and semantic materials.
# A tiny custom exporter avoids a new dependency after Blender removed its legacy DAE exporter.
NS='http://www.collada.org/2005/11/COLLADASchema'
def child(parent,tag,attributes=None,text=None):
    e=SubElement(parent,tag,attributes or {})
    if text is not None:e.text=text
    return e
def floats(values):return ' '.join(format(v,'.7g') for v in values)
def export(name,root,objects):
    doc=Element('COLLADA',{'xmlns':NS,'version':'1.4.1'})
    meta=child(doc,'asset');child(meta,'contributor');child(meta,'created',text='2026-11-01T00:00:00Z');child(meta,'modified',text='2026-11-01T00:00:00Z')
    child(meta,'unit',{'name':'meter','meter':'1'});child(meta,'up_axis',text='Y_UP')
    effects=child(doc,'library_effects');mats=child(doc,'library_materials')
    for role,color in colors.items():
        effect=child(effects,'effect',{'id':role+'-fx'});profile=child(effect,'profile_COMMON');tech=child(profile,'technique',{'sid':'common'})
        lambert=child(tech,'lambert');child(child(lambert,'diffuse'),'color',text=floats(color))
        material=child(mats,'material',{'id':role+'-mat','name':role});child(material,'instance_effect',{'url':'#'+role+'-fx'})
    geometries=child(doc,'library_geometries');vscene=child(child(doc,'library_visual_scenes'),'visual_scene',{'id':'Scene','name':name})
    deps=bpy.context.evaluated_depsgraph_get();triangle_count=0
    for number,obj in enumerate(objects):
        evaluated=obj.evaluated_get(deps);mesh=evaluated.to_mesh();mesh.calc_loop_triangles()
        transform=root.matrix_world.inverted()@obj.matrix_world;normal_matrix=transform.to_3x3().inverted().transposed()
        gid=f'mesh{number}';geom=child(geometries,'geometry',{'id':gid,'name':obj.name});data=child(geom,'mesh')
        positions=[];normals=[];uvs=[];index_by_key={};groups={}
        uv=mesh.uv_layers.active
        for triangle in mesh.loop_triangles:
            role=mesh.materials[triangle.material_index].name.split('.')[0]
            indices=groups.setdefault(role,[])
            for loop in triangle.loops:
                vertex=mesh.loops[loop].vertex_index;p=transform@mesh.vertices[vertex].co
                normal=(normal_matrix@mesh.corner_normals[loop].vector).normalized()
                t=uv.data[loop].uv if uv else (0,0)
                key=tuple(round(v,7) for v in (p.x,p.z,-p.y,normal.x,normal.z,-normal.y,t[0],t[1]))
                if key not in index_by_key:
                    index_by_key[key]=len(positions)//3;positions.extend(key[:3]);normals.extend(key[3:6]);uvs.extend(key[6:])
                indices.append(index_by_key[key])
            triangle_count+=1
        for suffix,values,stride,axes in [('pos',positions,3,'XYZ'),('norm',normals,3,'XYZ'),('uv',uvs,2,'ST')]:
            source=child(data,'source',{'id':gid+'-'+suffix});aid=gid+'-'+suffix+'-array'
            child(source,'float_array',{'id':aid,'count':str(len(values))},floats(values))
            accessor=child(child(source,'technique_common'),'accessor',{'source':'#'+aid,'count':str(len(values)//stride),'stride':str(stride)})
            for axis in axes:child(accessor,'param',{'name':axis,'type':'float'})
        verts=child(data,'vertices',{'id':gid+'-verts'});child(verts,'input',{'semantic':'POSITION','source':'#'+gid+'-pos'})
        for role,indices in groups.items():
            triangles=child(data,'triangles',{'material':role,'count':str(len(indices)//3)})
            for semantic,suffix,offset in [('VERTEX','verts',0),('NORMAL','norm',1),('TEXCOORD','uv',2)]:
                attr={'semantic':semantic,'source':'#'+gid+'-'+suffix,'offset':str(offset)}
                if semantic=='TEXCOORD':attr['set']='0'
                child(triangles,'input',attr)
            child(triangles,'p',text=' '.join(str(i) for index in indices for i in (index,index,index)))
        node=child(vscene,'node',{'id':gid+'-node','name':obj.name,'type':'NODE'})
        instance=child(node,'instance_geometry',{'url':'#'+gid})
        binding=child(child(instance,'bind_material'),'technique_common')
        for role in groups:child(binding,'instance_material',{'symbol':role,'target':'#'+role+'-mat'})
        evaluated.to_mesh_clear()
    child(child(doc,'scene'),'instance_visual_scene',{'url':'#Scene'})
    ElementTree(doc).write(OUT/(name+'.dae'),encoding='utf-8',xml_declaration=True)
    return {'objects':len(objects),'triangles':triangle_count,'bytes':(OUT/(name+'.dae')).stat().st_size}

bpy.context.view_layer.update()
stats={name:export(name,*value) for name,value in assets.items()}
# This is an isolated session; discard orphaned earlier generator revisions before packing.
bpy.data.orphans_purge(do_recursive=True)
bpy.ops.file.pack_all()
bpy.ops.wm.save_as_mainfile(filepath=str(ROOT/'Art/Models/premium-hardware.blend'),compress=True)
(ROOT/'Art/Models/manifest.json').write_text(json.dumps({'generator':'tools/build_hardware_models.py','transport':'Blender MCP','assets':stats},indent=2)+'\n')
result={'master':'Art/Models/premium-hardware.blend','assets':stats,'blender':bpy.app.version_string}
