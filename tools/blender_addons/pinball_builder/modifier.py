"""Native Geometry Nodes modifier interface; optimized mesh generation is handled by the add-on."""
import json
import bpy
from .geometry import TrackSpec

BOOL_FIELDS={
    'entry_flare':('Flared entrance','Openings'), 'exit_flare':('Flared exit','Openings'),
    'entry_runout':('Lower entrance walls','Openings'), 'exit_runout':('Lower exit walls','Openings'),
    'entry_arrow':('Entrance arrow','Arrows'), 'exit_arrow':('Exit arrow','Arrows'),
    'repeat_arrows':('Repeat arrows along path','Arrows')}
FIELD_LABELS={
 'width':('Inside width','Channel'),'wall_height':('Wall height','Channel'),'rail_width':('Rounded lip width','Channel'),
 'corner_radius':('Floor corner radius','Channel'),'floor_thickness':('Floor thickness','Channel'),
 'end_hardware':('Exit crossbar','Openings'),'entrance_funnel':('Entrance funnel','Openings'),'funnel_length':('Funnel length','Openings'),'funnel_width':('Funnel opening','Openings'),'funnel_turn':('Funnel turn','Openings'),'funnel_skew':('Funnel skew','Openings'),'end_length':('Transition length','Openings'),'flare':('Flare width factor','Openings'),
 'trim_start':('Entrance cut distance','Openings'),'trim_end':('Exit cut distance','Openings'),'loop_gap':('Opening in closed loop','Openings'),
 'supports':('Support columns','Columns'),'support_spacing':('Column spacing','Columns'),
 'support_radius':('Column radius','Columns'),'foot_radius':('Foot radius','Columns'),'clamp_length':('Bracket length','Columns'),'base_height':('Ground height','Columns'),
 'arrow_offset':('Distance from opening','Arrows'),'arrow_width':('Arrow width','Arrows'),'arrow_length':('Arrow length','Arrows'),
 'arrow_spacing':('Repeated arrow spacing','Arrows'),'exit_arrow_reverse':('Reverse exit arrow','Arrows'),
 'entrance_lamp':('Entrance lamp','Arrows'),'entrance_lamp_offset':('Entrance lamp distance','Arrows'),'entrance_lamp_size':('Entrance lamp size','Arrows'),
 'max_segment':('Maximum mesh span','Mesh quality'),'tolerance':('Mesh error tolerance','Mesh quality'),
 'triangle_budget':('Triangle budget','Mesh quality')}


def find(obj):
    return next((m for m in obj.modifiers if m.type=='NODES' and m.node_group and m.node_group.get('pb_ramp_modifier')),None)


def values(spec):
    d=spec.to_dict()
    d.update(entry_flare=spec.entrance=='FLARED',exit_flare=spec.exit=='FLARED',
             entry_runout=spec.entrance=='RUNOUT',exit_runout=spec.exit=='RUNOUT',
             entry_arrow=spec.arrow_mode in ('ENDS','ENTRY'),exit_arrow=spec.arrow_mode in ('ENDS','EXIT'),
             repeat_arrows=spec.arrow_mode=='REPEAT')
    return d


def set_input(modifier,identifier,value):
    # Blender 5.2 stores typed socket groups under properties.inputs; 4.x/5.0 use ID props.
    if hasattr(modifier,'properties') and hasattr(modifier.properties,'inputs'):
        modifier.properties.inputs[identifier]['value']=value
    else:modifier[identifier]=value


def get_input(modifier,identifier):
    if hasattr(modifier,'properties') and hasattr(modifier.properties,'inputs'):
        return modifier.properties.inputs[identifier]['value']
    return modifier.get(identifier)


def create(obj,spec):
    m=find(obj)
    # A modifier saved by an older add-on lacks the newer settings: recreate it.
    if m and set(FIELD_LABELS)-set(json.loads(m.node_group['pb_socket_map'])):
        obj.modifiers.remove(m);m=None
    if not m:
        m=obj.modifiers.new('Pinball Ramp','NODES')
        group=bpy.data.node_groups.new('Pinball Ramp • '+obj.name,'GeometryNodeTree');group['pb_ramp_modifier']=True
        group.interface.new_socket(name='Geometry',in_out='INPUT',socket_type='NodeSocketGeometry')
        group.interface.new_socket(name='Geometry',in_out='OUTPUT',socket_type='NodeSocketGeometry')
        panels={name:group.interface.new_panel(name=name) for name in ('Channel','Openings','Columns','Arrows','Mesh quality')}
        settings=values(spec);mapping={}
        for key,(label,panel) in {**FIELD_LABELS,**BOOL_FIELDS}.items():
            value=settings[key]
            kind='NodeSocketBool' if isinstance(value,bool) else 'NodeSocketInt' if isinstance(value,int) else 'NodeSocketFloat'
            socket=group.interface.new_socket(name=label,in_out='INPUT',socket_type=kind,parent=panels[panel])
            socket.default_value=value
            if kind=='NodeSocketFloat':
                socket.min_value=0 if key not in ('base_height','funnel_turn','funnel_skew') else -180
                socket.max_value=10 if key!='funnel_turn' else 180
                if key not in ('flare','tolerance','funnel_turn','funnel_skew'):socket.subtype='DISTANCE'
            if kind=='NodeSocketInt':socket.min_value=1000;socket.max_value=50000
            mapping[key]=socket.identifier
        group['pb_socket_map']=json.dumps(mapping)
        group.nodes.new('NodeGroupInput').location=(-500,0)
        output=group.nodes.new('NodeGroupOutput');output.location=(300,0)
        source=group.nodes.new('GeometryNodeObjectInfo');source.name='Generated channel';source.label='Optimized parametric channel';source.transform_space='RELATIVE'
        source.inputs['As Instance'].default_value=False
        group.links.new(source.outputs['Geometry'],output.inputs['Geometry'])
        m.node_group=group
    mapping=json.loads(m.node_group['pb_socket_map'])
    for key,value in values(spec).items():
        if key in mapping:set_input(m,mapping[key],value)
    return m


def read(obj):
    m=find(obj)
    if not m:return None
    mapping=json.loads(m.node_group['pb_socket_map'])
    d={key:get_input(m,identifier) for key,identifier in mapping.items()}
    d['entrance']='FLARED' if d.pop('entry_flare') else 'RUNOUT' if d.pop('entry_runout') else 'OPEN'
    d['exit']='FLARED' if d.pop('exit_flare') else 'RUNOUT' if d.pop('exit_runout') else 'OPEN'
    repeat,entry,exit=d.pop('repeat_arrows'),d.pop('entry_arrow'),d.pop('exit_arrow')
    d['arrow_mode']='REPEAT' if repeat else 'ENDS' if entry and exit else 'ENTRY' if entry else 'EXIT' if exit else 'NONE'
    return TrackSpec.from_dict(d)


def attach(obj,generated):
    m=find(obj)
    m.node_group.nodes['Generated channel'].inputs['Object'].default_value=generated


def find_wall(obj):
    return next((m for m in obj.modifiers if m.type=='NODES' and m.node_group and m.node_group.get('pb_wall_modifier')),None)


def create_wall(obj,radius,height):
    """The native modifier on a wall's line: its thickness and height, with the mesh generated from them."""
    m=find_wall(obj)
    if not m:
        obj.data.bevel_depth=0
        m=obj.modifiers.new('Pinball Wall','NODES')
        group=bpy.data.node_groups.new('Pinball Wall • '+obj.name,'GeometryNodeTree');group['pb_wall_modifier']=True
        group.interface.new_socket(name='Geometry',in_out='INPUT',socket_type='NodeSocketGeometry')
        group.interface.new_socket(name='Geometry',in_out='OUTPUT',socket_type='NodeSocketGeometry')
        mapping={}
        for key,label,value,low in (('thickness','Thickness',radius*2,.012),('height','Height',height,.008)):
            socket=group.interface.new_socket(name=label,in_out='INPUT',socket_type='NodeSocketFloat')
            socket.default_value=value;socket.min_value=low;socket.max_value=1;socket.subtype='DISTANCE'
            mapping[key]=socket.identifier
        group['pb_socket_map']=json.dumps(mapping)
        group.nodes.new('NodeGroupInput').location=(-500,0)
        output=group.nodes.new('NodeGroupOutput');output.location=(300,0)
        source=group.nodes.new('GeometryNodeObjectInfo');source.name='Generated channel';source.label='Generated wall';source.transform_space='RELATIVE'
        source.inputs['As Instance'].default_value=False
        group.links.new(source.outputs['Geometry'],output.inputs['Geometry'])
        m.node_group=group
    mapping=json.loads(m.node_group['pb_socket_map'])
    set_input(m,mapping['thickness'],radius*2);set_input(m,mapping['height'],height)
    return m


def read_wall(obj):
    """(radius, height), or None for a line with no wall modifier."""
    m=find_wall(obj)
    if not m:return None
    mapping=json.loads(m.node_group['pb_socket_map'])
    return get_input(m,mapping['thickness'])*.5,get_input(m,mapping['height'])


def rollover_bar_group(frame,slot):
    """A pure Geometry Nodes modifier: attach it to any object and it adds a rollover switch's plate there."""
    group=bpy.data.node_groups.get('Pinball Rollover Bar')
    if group:return group
    group=bpy.data.node_groups.new('Pinball Rollover Bar','GeometryNodeTree');group['pb_rollover_bar']=True;group.use_fake_user=True
    group.interface.new_socket(name='Geometry',in_out='INPUT',socket_type='NodeSocketGeometry')
    for label,value in (('Half length',.03),('Half width',.0138)):
        socket=group.interface.new_socket(name=label,in_out='INPUT',socket_type='NodeSocketFloat');socket.default_value=value;socket.min_value=.001;socket.subtype='DISTANCE'
    for label,material in (('Frame',frame),('Slot',slot)):
        group.interface.new_socket(name=label,in_out='INPUT',socket_type='NodeSocketMaterial').default_value=material
    group.interface.new_socket(name='Geometry',in_out='OUTPUT',socket_type='NodeSocketGeometry')
    nodes,links=group.nodes,group.links
    source,output=nodes.new('NodeGroupInput'),nodes.new('NodeGroupOutput')
    join=nodes.new('GeometryNodeJoinGeometry')
    links.new(source.outputs['Geometry'],join.inputs[0])
    def layer(scale_width,scale_length,corner,lift,material):
        # A rounded rectangle lying flat, its size a share of the bar's: width, length and corner.
        def share(name,amount):
            math_node=nodes.new('ShaderNodeMath');math_node.operation='MULTIPLY';math_node.inputs[1].default_value=amount
            links.new(source.outputs[name],math_node.inputs[0]);return math_node.outputs[0]
        rectangle=nodes.new('GeometryNodeCurvePrimitiveQuadrilateral')
        links.new(share('Half width',2*scale_width),rectangle.inputs['Width'])
        links.new(share('Half length',2*scale_length),rectangle.inputs['Height'])
        fillet=nodes.new('GeometryNodeFilletCurve')
        fillet.inputs['Mode'].default_value='Poly'
        fillet.inputs['Count'].default_value=4
        links.new(rectangle.outputs[0],fillet.inputs['Curve'])
        links.new(share('Half width',corner),fillet.inputs['Radius'])
        fill=nodes.new('GeometryNodeFillCurve')
        links.new(fillet.outputs[0],fill.inputs['Curve'])
        raised=nodes.new('GeometryNodeSetPosition')
        offset=nodes.new('ShaderNodeCombineXYZ')
        links.new(share('Half length',lift),offset.inputs['Z'])
        links.new(fill.outputs[0],raised.inputs['Geometry'])
        links.new(offset.outputs[0],raised.inputs['Offset'])
        paint=nodes.new('GeometryNodeSetMaterial')
        links.new(raised.outputs[0],paint.inputs['Geometry'])
        links.new(source.outputs[material],paint.inputs['Material'])
        links.new(paint.outputs[0],join.inputs[0])
    layer(1,1,.42,.02,'Frame')
    layer(.6,.84,.3,.03,'Slot')
    layer(.2,.62,.18,.04,'Frame')
    links.new(join.outputs[0],output.inputs['Geometry'])
    return group


def find_rollover_bar(obj):
    return next((m for m in obj.modifiers if m.type=='NODES' and m.node_group and m.node_group.get('pb_rollover_bar')),None)


def attach_rollover_bar(obj,frame,slot,half_length=.03,half_width=.0138):
    m=find_rollover_bar(obj) or obj.modifiers.new('Pinball Rollover Bar','NODES')
    m.node_group=rollover_bar_group(frame,slot)
    tree=m.node_group.interface.items_tree
    for label,value in (('Half length',float(half_length)),('Half width',float(half_width)),('Frame',frame),('Slot',slot)):
        set_input(m,tree[label].identifier,value)
    return m
