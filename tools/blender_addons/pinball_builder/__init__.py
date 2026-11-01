"""Pinball Builder: curve-driven tracks and complete gameplay table authoring."""
bl_info = {'name':'Pinball Builder','author':'Pinball project','version':(1,0,0),'blender':(4,2,0),
           'location':'3D View > Sidebar > Pinball','description':'Parametric aluminum channels and playable level export','category':'Add Curve'}

import json
import math
import hashlib
from pathlib import Path
import bpy
import bmesh
from bpy.props import BoolProperty, EnumProperty, FloatProperty, IntProperty, PointerProperty, StringProperty
from bpy.app.handlers import persistent
from mathutils import Vector
from mathutils.geometry import interpolate_bezier
from .geometry import TrackSpec, build_track, build_wall, arc_lengths, sample, trimmed, entrance_lamp

_busy = False
_dirty = set()


def track_object(obj):
    while obj:
        if obj.type == 'CURVE' and getattr(obj,'pb_track',None) and obj.pb_track.enabled:
            return obj
        obj = obj.parent
    return None


def queue_update(self, context):
    obj = self.id_data
    if not _busy and self.enabled and self.auto_update:
        _dirty.add(obj.name)
        if not bpy.app.timers.is_registered(flush_updates): bpy.app.timers.register(flush_updates,first_interval=.12)


def flush_updates():
    names = list(_dirty); _dirty.clear()
    from . import modifier
    for name in names:
        obj = bpy.data.objects.get(name)
        if obj and obj.type == 'CURVE' and modifier.find_wall(obj):
            try: rebuild_wall(obj)
            except Exception as error: obj['pb_build_error'] = str(error)
            continue
        if obj and track_object(obj) is obj:
            try: rebuild_track(obj)
            except Exception as error: obj['pb_build_error'] = str(error)
    return .12 if _dirty else None


@persistent
def paths_changed(scene, depsgraph):
    if _busy: return
    changed = {u.id.original for u in depsgraph.updates if u.is_updated_geometry or u.is_updated_transform}
    obstacles=[o for o in scene.objects if o.get('pb_kind') not in (None,'ramps','groups','table')]
    obstacle_state=hashlib.sha256(json.dumps([[o.name,list(o.location),list(o.rotation_euler),list(o.scale),
                      {k:o[k] for k in o.keys() if k.startswith('game_')}] for o in obstacles],sort_keys=True).encode()).hexdigest()
    supports_changed=scene.get('pb_obstacle_signature')!=obstacle_state
    if supports_changed:scene['pb_obstacle_signature']=obstacle_state
    for obj in scene.objects:
        if obj.type == 'CURVE' and obj.pb_track.enabled and obj.pb_track.auto_update and (supports_changed or ((obj in changed or obj.data in changed) and obj.get('pb_build_signature') != signature(obj))):
            _dirty.add(obj.name)
    from . import modifier
    for obj in scene.objects:
        if obj.type == 'CURVE' and modifier.find_wall(obj) and obj.get('pb_build_signature') != wall_signature(obj):
            _dirty.add(obj.name)
    if _dirty and not bpy.app.timers.is_registered(flush_updates): bpy.app.timers.register(flush_updates,first_interval=.12)


@persistent
def file_loaded(_):
    _dirty.clear()
    for obj in bpy.context.scene.objects:
        if obj.type=='CURVE' and obj.pb_track.enabled and obj.pb_track.auto_update and obj.get('pb_build_signature')!=signature(obj):_dirty.add(obj.name)
    if _dirty and not bpy.app.timers.is_registered(flush_updates):bpy.app.timers.register(flush_updates,first_interval=.12)


class PBTrackSettings(bpy.types.PropertyGroup):
    enabled: BoolProperty(default=False)
    auto_update: BoolProperty(name='Live update',default=True)
    width: FloatProperty(name='Inside width',default=.088,min=.015,max=1,subtype='DISTANCE',update=queue_update)
    wall_height: FloatProperty(name='Wall height',default=.05,min=.009,max=.5,subtype='DISTANCE',update=queue_update)
    rail_width: FloatProperty(name='Round rail width',default=.008,min=.001,max=.04,subtype='DISTANCE',update=queue_update)
    corner_radius: FloatProperty(name='Floor corner radius',default=.0035,min=.0005,max=.02,subtype='DISTANCE',update=queue_update)
    floor_thickness: FloatProperty(name='Floor thickness',default=.002,min=.0005,max=.02,subtype='DISTANCE',update=queue_update)
    entrance: EnumProperty(name='Entrance',items=[(x,x.title(),'') for x in ('OPEN','FLARED','RUNOUT')],default='OPEN',update=queue_update)
    exit: EnumProperty(name='Exit',items=[(x,x.title(),'') for x in ('OPEN','FLARED','RUNOUT')],default='OPEN',update=queue_update)
    end_hardware: BoolProperty(name='Exit crossbar',default=True,update=queue_update)
    entrance_funnel: BoolProperty(name='Entrance funnel',default=True,update=queue_update)
    funnel_length: FloatProperty(name='Funnel length',default=.12,min=.02,max=.5,subtype='DISTANCE',update=queue_update)
    funnel_width: FloatProperty(name='Funnel opening',default=.155,min=.02,max=.6,subtype='DISTANCE',update=queue_update)
    funnel_turn: FloatProperty(name='Funnel turn',default=0,min=-90,max=90,update=queue_update)
    funnel_skew: FloatProperty(name='Funnel skew',default=0,min=-1,max=1,update=queue_update)
    end_length: FloatProperty(name='Transition length',default=.055,min=.01,max=.5,subtype='DISTANCE',update=queue_update)
    flare: FloatProperty(name='Flare width factor',default=1.18,min=1,max=2,update=queue_update)
    trim_start: FloatProperty(name='Entrance cut distance',default=0,min=0,subtype='DISTANCE',update=queue_update)
    trim_end: FloatProperty(name='Exit cut distance',default=0,min=0,subtype='DISTANCE',update=queue_update)
    loop_gap: FloatProperty(name='Opening in closed loop',default=.12,min=.02,subtype='DISTANCE',update=queue_update)
    supports: BoolProperty(name='Generate support columns',default=False,update=queue_update)
    support_spacing: FloatProperty(name='Column spacing',default=.2,min=.06,max=2,subtype='DISTANCE',update=queue_update)
    support_radius: FloatProperty(name='Column radius',default=.0065,min=.002,max=.03,subtype='DISTANCE',update=queue_update)
    foot_radius: FloatProperty(name='Foot radius',default=.0125,min=.004,max=.05,subtype='DISTANCE',update=queue_update)
    clamp_length: FloatProperty(name='Bracket length',default=.026,min=.008,max=.08,subtype='DISTANCE',update=queue_update)
    base_height: FloatProperty(name='Support ground height',default=0,subtype='DISTANCE',update=queue_update)
    arrow_mode: EnumProperty(name='Arrows',items=[('ENDS','Entrance and exit',''),('ENTRY','Entrance only',''),('EXIT','Exit only',''),('REPEAT','Evenly repeated',''),('NONE','None','')],default='ENDS',update=queue_update)
    arrow_offset: FloatProperty(name='Distance from opening',default=.075,min=.015,max=.5,subtype='DISTANCE',update=queue_update)
    arrow_width: FloatProperty(name='Arrow width',default=.03,min=.005,max=.1,subtype='DISTANCE',update=queue_update)
    arrow_length: FloatProperty(name='Arrow length',default=.036,min=.005,max=.15,subtype='DISTANCE',update=queue_update)
    arrow_spacing: FloatProperty(name='Arrow spacing',default=.08,min=.025,max=.5,subtype='DISTANCE',update=queue_update)
    exit_arrow_reverse: BoolProperty(name='Reverse exit arrow',default=False,update=queue_update)
    entrance_lamp: BoolProperty(name='Entrance lamp',default=True,update=queue_update)
    entrance_lamp_offset: FloatProperty(name='Entrance lamp distance',default=.065,min=.03,max=.4,subtype='DISTANCE',update=queue_update)
    entrance_lamp_size: FloatProperty(name='Entrance lamp size',default=.0354,min=.01,max=.1,subtype='DISTANCE',update=queue_update)
    max_segment: FloatProperty(name='Maximum mesh span',default=.028,min=.007,max=.1,subtype='DISTANCE',update=queue_update)
    tolerance: FloatProperty(name='Mesh error tolerance',default=.0002,min=.00005,max=.002,precision=5,update=queue_update)
    triangle_budget: IntProperty(name='Triangle budget',default=6000,min=1000,max=50000,update=queue_update)


def spec_for(obj):
    from . import modifier
    return modifier.read(obj) or TrackSpec.from_dict({key:getattr(obj.pb_track,key) for key in TrackSpec.__dataclass_fields__})


def configure_track(obj, spec):
    p = obj.pb_track
    p.auto_update = False; p.enabled = False
    for key,value in spec.to_dict().items(): setattr(p,key,value)
    from . import modifier
    modifier.create(obj,spec)
    p.enabled = True; p.auto_update = True


def signature(obj):
    data=[]
    for spline in obj.data.splines:
        data.append([spline.type,spline.use_cyclic_u])
        if spline.type=='BEZIER':data.extend([list(p.co)+list(p.handle_left)+list(p.handle_right) for p in spline.bezier_points])
        else:data.extend(list(p.co) for p in spline.points)
    return hashlib.sha256(json.dumps([data,[list(row) for row in obj.matrix_local],spec_for(obj).to_dict()],sort_keys=True).encode()).hexdigest()


def curve_points(obj, spacing=.007, parent_space=True):
    if len(obj.data.splines) != 1: raise ValueError('Use one spline per track object')
    spline = obj.data.splines[0]
    if spline.type == 'BEZIER':
        points = spline.bezier_points; out=[]
        segments = len(points) if spline.use_cyclic_u else len(points)-1
        for i in range(segments):
            a,b=points[i],points[(i+1)%len(points)]
            out.extend(interpolate_bezier(a.co,a.handle_right,b.handle_left,b.co,max(12,obj.data.resolution_u))[:-1])
        out.append(points[0].co.copy() if spline.use_cyclic_u else points[-1].co.copy())
    elif spline.type == 'POLY':
        out=[Vector(p.co[:3]) for p in spline.points]
        if spline.use_cyclic_u: out.append(out[0].copy())
    else: raise ValueError('Convert this spline to Bézier or Poly first')
    if len(out)<2: raise ValueError('The path needs at least two points')
    if parent_space: out=[obj.matrix_local @ p for p in out]
    lengths=arc_lengths(out)
    count=max(2,math.ceil(lengths[-1]/spacing))
    out=[sample(out,lengths,lengths[-1]*i/count)[0] for i in range(count+1)]
    if spline.use_cyclic_u:
        gap=spec_for(obj).loop_gap*.5
        out=trimmed(out,gap,gap)
    return out


DEFAULT_COLORS={'plate_frame':(.62,.63,.66,1),'channel_entry':(.72,.6,.38,1),'accent':(.85,.62,.24,1),'metal':(.9,.86,.75,1),'channel_floor':(.52,.57,.61,1),'channel_liner':(.29,.35,.40,1),
                'channel_aluminum':(.66,.71,.75,1),'channel_shell':(.35,.40,.44,1),
                'dark':(.025,.035,.045,1),'channel_arrow':(1,.12,.025,1)}


def ensure_material(role):
    for m in bpy.data.materials:
        if m.get('pb_surface_role')==role: return m
    m=bpy.data.materials.new(role);m['pb_surface_role']=role;m.use_nodes=True
    color=DEFAULT_COLORS.get(role,(.15,.25,.35,1));m.diffuse_color=color
    bsdf=m.node_tree.nodes.get('Principled BSDF');bsdf.inputs['Base Color'].default_value=color
    bsdf.inputs['Metallic'].default_value=.8 if role.startswith('channel_') else 0
    bsdf.inputs['Roughness'].default_value=.32
    if role=='channel_arrow':
        bsdf.inputs['Emission Color'].default_value=color;bsdf.inputs['Emission Strength'].default_value=.7
    return m


def object_from_mesh_data(name, data, collection, material_map=None):
    mesh=bpy.data.meshes.new(name);mesh.from_pydata(data.vertices,[],data.faces);mesh.update()
    roles=list(dict.fromkeys(data.roles)); materials=material_map or {}
    for role in roles:
        material=materials.get(role) or ensure_material(role)
        material['pb_surface_role']=role;mesh.materials.append(material)
    index={role:i for i,role in enumerate(roles)}
    for face,role in zip(mesh.polygons,data.roles):face.material_index=index[role];face.use_smooth=True
    layer=mesh.uv_layers.new(name='UV')
    for loop in mesh.loops:layer.data[loop.index].uv=data.uvs[loop.vertex_index]
    work=bmesh.new();work.from_mesh(mesh)
    for edge in work.edges:
        if len(edge.link_faces)==2:
            limit=min(data.sharp[face.index] for face in edge.link_faces)
            edge.smooth=edge.calc_face_angle(0)<=math.radians(limit)
    work.to_mesh(mesh);work.free()
    if data.normals:
        mesh.update()
        normals=[data.normals.get(loop.vertex_index,mesh.corner_normals[loop.index].vector) for loop in mesh.loops]
        mesh.normals_split_custom_set(normals)
    obj=bpy.data.objects.new(name,mesh);collection.objects.link(obj);obj['pb_generated']=True;obj.hide_select=True
    return obj


def rebuild_track(obj, material_map=None, support_filter=None):
    global _busy
    _busy=True
    try:
        table=None
        if support_filter is None and obj.parent and obj.parent.get('pb_kind')=='table':
            from .levels import table_dict
            from .geometry import clear_support
            table=table_dict(bpy.context.scene)
            support_filter=lambda xy,r,tight=False:clear_support(table,xy,r,tight)
        path=curve_points(obj);spec=spec_for(obj)
        data=build_track(path,spec,support_filter)
        # The lamp itself is a gameplay element the exporter generates. In a level, show where it goes.
        if spec.entrance_lamp and obj.parent and obj.parent.get('pb_kind')=='table':
            centre,heading=entrance_lamp(path,spec,table);side=Vector((-heading.y,heading.x));size=spec.entrance_lamp_size
            tip=[centre+heading*size,centre-heading*size*.5+side*size*.54,centre-heading*size*.5-side*size*.54]
            data.add([(q.x,q.y,.002) for q in tip],[(0,1,2)],'channel_arrow')
        from . import modifier
        scene=bpy.context.scene
        collection=scene.get('pb_cache_collection')
        if not collection:
            collection=bpy.data.collections.new('Pinball • Generated • '+scene.name)
            scene.collection.children.link(collection);scene['pb_cache_collection']=collection
        old=[o for o in bpy.data.objects if o.get('pb_track_owner')==obj and o.get('pb_generated')]
        mesh=object_from_mesh_data(obj.name+' • Cached mesh',data,collection,material_map)
        mesh['pb_track_owner']=obj
        mesh.parent=obj.parent
        mesh.hide_render=True
        mesh.hide_set(True)
        current_modifier=modifier.find(obj)
        if current_modifier.node_group.users>1:current_modifier.node_group=current_modifier.node_group.copy()
        modifier.attach(obj,mesh)
        for child in old:
            block=child.data;bpy.data.objects.remove(child,do_unlink=True)
            if block and block.users==0:bpy.data.meshes.remove(block)
        obj['pb_build_signature']=signature(obj)
        obj['pb_build_error']='';obj['pb_triangle_count']=data.triangles
        obj['pb_support_count']=data.metadata['support_count'];obj['pb_arrow_count']=data.metadata['arrow_count']
        obj['pb_track_spec']=json.dumps(spec_for(obj).to_dict(),sort_keys=True)
        return mesh,data
    finally:_busy=False


def wall_points(obj):
    return [tuple((obj.matrix_local@Vector(p.co[:3]))[:2]) for p in obj.data.splines[0].points]


def wall_signature(obj):
    from . import modifier
    return hashlib.sha256(json.dumps([wall_points(obj),modifier.read_wall(obj)]).encode()).hexdigest()


def rebuild_wall(obj):
    """Regenerate the cached mesh behind a wall line's Pinball Wall modifier."""
    global _busy
    from . import modifier
    _busy=True
    try:
        radius,height=modifier.read_wall(obj)
        data=build_wall(wall_points(obj),radius,height)
        scene=bpy.context.scene
        collection=scene.get('pb_cache_collection')
        if not collection:
            collection=bpy.data.collections.new('Pinball • Generated • '+scene.name)
            scene.collection.children.link(collection);scene['pb_cache_collection']=collection
        old=[o for o in bpy.data.objects if o.get('pb_track_owner')==obj and o.get('pb_generated')]
        mesh=object_from_mesh_data(obj.name+' • Cached mesh',data,collection)
        mesh['pb_track_owner']=obj;mesh.parent=obj.parent;mesh.hide_render=True;mesh.hide_set(True)
        modifier.find_wall(obj).node_group.nodes['Generated channel'].inputs['Object'].default_value=mesh
        for child in old:
            block=child.data;bpy.data.objects.remove(child,do_unlink=True)
            if block and block.users==0:bpy.data.meshes.remove(block)
        obj['pb_build_signature']=wall_signature(obj);obj['pb_build_error']=''
    finally:_busy=False


def configure_wall(obj,radius,height):
    from . import modifier
    modifier.create_wall(obj,radius,height)
    rebuild_wall(obj)


class PB_OT_add_track(bpy.types.Operator):
    bl_idname='pinball.add_track';bl_label='Add Parametric Track';bl_options={'REGISTER','UNDO'}
    def execute(self,context):
        curve=bpy.data.curves.new('Track path','CURVE');curve.dimensions='3D';curve.resolution_u=24
        spline=curve.splines.new('BEZIER');spline.bezier_points.add(3)
        for p,co in zip(spline.bezier_points,[(0,0,0),(-.15,.3,.10),(-.10,.55,.13),(.1,.55,.13)]):
            p.co=co;p.handle_left_type=p.handle_right_type='AUTO_CLAMPED'
        obj=bpy.data.objects.new('Track',curve);context.collection.objects.link(obj);obj.location=context.scene.cursor.location
        from .levels import root_for, unique_id
        obj.parent=root_for(context.scene)
        obj.show_in_front=False;configure_track(obj,TrackSpec());obj['pb_kind']='ramps';obj['pb_id']=unique_id(context.scene,'ramp')
        rebuild_track(obj)
        bpy.ops.object.select_all(action='DESELECT');obj.select_set(True);context.view_layer.objects.active=obj
        return {'FINISHED'}


class PB_OT_use_curve(bpy.types.Operator):
    bl_idname='pinball.use_curve';bl_label='Make Selected Curve a Track';bl_options={'REGISTER','UNDO'}
    @classmethod
    def poll(cls,context):return context.object and context.object.type=='CURVE'
    def execute(self,context):
        from .levels import root_for,unique_id
        obj=context.object;configure_track(obj,TrackSpec());obj['pb_kind']='ramps';obj['pb_id']=obj.get('pb_id',unique_id(context.scene,'ramp'))
        if not obj.parent:obj.parent=root_for(context.scene)
        try:rebuild_track(obj)
        except Exception as error:self.report({'ERROR'},str(error));return {'CANCELLED'}
        return {'FINISHED'}


class PB_OT_rebuild_track(bpy.types.Operator):
    bl_idname='pinball.rebuild_track';bl_label='Rebuild Track';bl_options={'REGISTER','UNDO'}
    @classmethod
    def poll(cls,context):return track_object(context.object) is not None
    def execute(self,context):
        try:rebuild_track(track_object(context.object))
        except Exception as error:self.report({'ERROR'},str(error));return {'CANCELLED'}
        return {'FINISHED'}


class PB_OT_export_level(bpy.types.Operator):
    bl_idname='pinball.export_level';bl_label='Export Playable Level'
    def execute(self,context):
        from . import levels
        try:
            result=levels.export_playable(context.scene,Path(bpy.path.abspath(context.scene.pb_project_root)))
            self.report({'INFO'},result)
        except Exception as error:self.report({'ERROR'},str(error));return {'CANCELLED'}
        return {'FINISHED'}


class PB_OT_import_level(bpy.types.Operator):
    bl_idname='pinball.import_level';bl_label='Import Game Table';bl_options={'REGISTER','UNDO'}
    filepath:StringProperty(subtype='FILE_PATH')
    def execute(self,context):
        from . import levels
        try:levels.import_level(Path(self.filepath),context.scene.pb_project_root)
        except Exception as error:self.report({'ERROR'},str(error));return {'CANCELLED'}
        return {'FINISHED'}
    def invoke(self,context,event):context.window_manager.fileselect_add(self);return {'RUNNING_MODAL'}


class PB_OT_add_element(bpy.types.Operator):
    bl_idname='pinball.add_element';bl_label='Add Gameplay Element';bl_options={'REGISTER','UNDO'}
    kind:EnumProperty(name='Type',items=[(x,x.title(),'') for x in ('bumpers','posts','lamps','rollovers','saucers','slingshots','dropTargets','standups','spinners','gates','kickbacks','magnets','captiveBalls','flashers','flippers','walls','plastics','decor','groups')])
    def invoke(self,context,event):return context.window_manager.invoke_props_dialog(self)
    def execute(self,context):
        from .levels import add_element
        try:obj=add_element(context.scene,self.kind,context.scene.cursor.location)
        except Exception as error:self.report({'ERROR'},str(error));return {'CANCELLED'}
        bpy.ops.object.select_all(action='DESELECT');obj.select_set(True);context.view_layer.objects.active=obj
        return {'FINISHED'}


class PB_OT_refresh_level(bpy.types.Operator):
    bl_idname='pinball.refresh_level';bl_label='Refresh Gameplay Preview';bl_options={'REGISTER','UNDO'}
    def execute(self,context):
        from .levels import refresh_level
        try:refresh_level(context.scene)
        except Exception as error:self.report({'ERROR'},str(error));return {'CANCELLED'}
        return {'FINISHED'}


class PB_PT_builder(bpy.types.Panel):
    bl_label='Pinball Builder';bl_idname='PB_PT_builder';bl_space_type='VIEW_3D';bl_region_type='UI';bl_category='Pinball'
    def draw(self,context):
        layout=self.layout;layout.prop(context.scene,'pb_project_root')
        row=layout.row();row.operator('pinball.import_level',text='Import Table');row.operator('pinball.export_level',text='Export Playable')
        layout.operator('pinball.add_track');layout.operator('pinball.use_curve')
        row=layout.row();row.operator('pinball.add_element');row.operator('pinball.refresh_level',text='Refresh Preview')
        obj=track_object(context.object)
        if obj:
            p=obj.pb_track;layout.prop(p,'auto_update');layout.operator('pinball.rebuild_track')
            layout.label(text='Edit parameters in the Pinball Ramp modifier.')
            layout.label(text='Tab: edit the path; generated mesh stays internal.')
            layout.label(text=f"{obj.get('pb_triangle_count',0):,} triangles • {obj.get('pb_support_count',0)} columns")
            if obj.get('pb_build_error'):layout.label(text=obj['pb_build_error'],icon='ERROR')
        active=context.object
        if active and active.get('pb_kind'):
            box=layout.box();box.label(text='Gameplay object: '+active['pb_kind'])
            for key in sorted(active.keys()):
                if (key.startswith('game_') and key not in ('game_angle','game_restAngle')) or key in ('pb_id',):box.prop(active,'["'+key+'"]',text=key.removeprefix('game_'))


classes=(PBTrackSettings,PB_OT_add_track,PB_OT_use_curve,PB_OT_rebuild_track,PB_OT_export_level,PB_OT_import_level,PB_OT_add_element,PB_OT_refresh_level,PB_PT_builder)


def register():
    if hasattr(bpy.types.Object,'pb_track'):return
    for cls in classes:bpy.utils.register_class(cls)
    bpy.types.Object.pb_track=PointerProperty(type=PBTrackSettings)
    bpy.types.Scene.pb_project_root=StringProperty(name='Pinball project',subtype='DIR_PATH',default='')
    bpy.app.handlers.depsgraph_update_post.append(paths_changed)
    bpy.app.handlers.load_post.append(file_loaded)


def unregister():
    if paths_changed in bpy.app.handlers.depsgraph_update_post:bpy.app.handlers.depsgraph_update_post.remove(paths_changed)
    if file_loaded in bpy.app.handlers.load_post:bpy.app.handlers.load_post.remove(file_loaded)
    if bpy.app.timers.is_registered(flush_updates):bpy.app.timers.unregister(flush_updates)
    _dirty.clear()
    if hasattr(bpy.types.Object,'pb_track'):del bpy.types.Object.pb_track
    if hasattr(bpy.types.Scene,'pb_project_root'):del bpy.types.Scene.pb_project_root
    for cls in reversed(classes):bpy.utils.unregister_class(cls)
