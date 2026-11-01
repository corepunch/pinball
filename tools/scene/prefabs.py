"""Prefabs: parts built from shapes and the modifiers nested inside them, in the manner of scener.

    <prefab id="button">
      <let name="R" value="1"/>
      <circle radius="{R}" role="accent"><extrude amount=".2"/><bevel amount=".02"/></circle>
      <lathe role="metal" segments="24" points="{R*.8},.2 .2,.3 .001,.32"/>
    </prefab>

Any attribute may hold {expressions}. <use prefab="…"> places another prefab, its other attributes
becoming its variables. Shapes give an outline, modifiers run in order, and the last makes the mesh.
"""
import ast
import math
import operator
import re

import mesher

OPS = {ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul, ast.Div: operator.truediv, ast.Pow: operator.pow, ast.USub: operator.neg}
FUNCS = {'cos': math.cos, 'sin': math.sin, 'sqrt': math.sqrt, 'radians': math.radians, 'min': min, 'max': max}


def evaluate(node, names):
    if isinstance(node, ast.Expression):
        return evaluate(node.body, names)
    if isinstance(node, ast.Constant):
        return node.value
    if isinstance(node, ast.Name):
        if node.id == 'pi':
            return math.pi
        return names[node.id]
    if isinstance(node, ast.BinOp):
        return OPS[type(node.op)](evaluate(node.left, names), evaluate(node.right, names))
    if isinstance(node, ast.UnaryOp):
        return OPS[type(node.op)](evaluate(node.operand, names))
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in FUNCS:
        return FUNCS[node.func.id](*(evaluate(a, names) for a in node.args))
    raise ValueError(f'Not allowed in an expression: {ast.dump(node)}')


def fill(text, names):
    def value(match):
        result = evaluate(ast.parse(match.group(1), mode='eval'), names)
        return format(result, '.8g') if isinstance(result, (int, float)) else str(result)
    return re.sub(r'\{([^{}]+)\}', value, text)


def pairs(text):
    return [tuple(float(c) for c in word.split(',')) for word in text.split()]


class Attributes:
    def __init__(self, element, names):
        self.tag = element.tag
        self.values = {key: fill(text, names) for key, text in element.attrib.items()}

    def get(self, key, default=None):
        return self.values.get(key, default)

    def number(self, key, default=None):
        return float(self.values[key]) if key in self.values else default

    def vector(self, key, default=(0, 0)):
        return tuple(float(c) for c in self.values[key].replace(',', ' ').split()) if key in self.values else default


def arrowhead(radius, narrow, corner):
    """A rounded triangle, apex on +x, narrowed across so it has a direction."""
    out = []
    for a in (0, math.tau / 3, 2 * math.tau / 3):
        cx, cy = math.cos(a) * radius * (1 - corner), math.sin(a) * radius * (1 - corner)
        for s in range(7):
            b = a - math.pi / 3 + s * (math.tau / 3) / 6
            out.append((cx + radius * corner * math.cos(b), (cy + radius * corner * math.sin(b)) * narrow))
    return out


def capsule(base, tip, length, arc=8):
    """A tapered bar from a circle at the origin to a smaller one along +x, counter-clockwise."""
    # The straight sides are tangent to both circles.
    tilt = math.asin((base - tip) / length)
    low, high = -math.pi / 2 + tilt, math.pi / 2 - tilt
    out = [(length + tip * math.cos(low + (high - low) * i / (arc * 2)), tip * math.sin(low + (high - low) * i / (arc * 2))) for i in range(arc * 2 + 1)]
    return out + [(base * math.cos(high + (math.tau - (high - low)) * i / (arc * 2)), base * math.sin(high + (math.tau - (high - low)) * i / (arc * 2))) for i in range(arc * 2 + 1)]


def outline_of(a):
    tag = a.tag
    if tag == 'rect':
        w, h = a.vector('size')
        out = [(-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2)]
    elif tag == 'rounded-rect':
        w, h = a.vector('size')
        out = mesher.filleted([(-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2)], a.number('radius'), int(a.number('arc', 4)))
    elif tag == 'circle':
        r, n = a.number('radius'), int(a.number('segments', 32))
        out = [(r * math.cos(i * math.tau / n), r * math.sin(i * math.tau / n)) for i in range(n)]
    elif tag == 'arrowhead':
        out = arrowhead(a.number('radius', 1), a.number('narrow', .62), a.number('corner', .2353))
    elif tag == 'capsule':
        out = capsule(a.number('base'), a.number('tip'), a.number('length', 1))
    elif tag == 'polygon':
        out = pairs(a.get('points'))
    else:
        return None
    k = a.number('scale', 1)
    flip = a.number('mirror', 1)
    dx, dy = a.vector('at')
    out = [(dx + flip * p[0] * k, dy + flip * p[1] * k) for p in out]
    return out[::-1] if flip < 0 else out


class Builder:
    def __init__(self, prefabs):
        self.prefabs = prefabs

    def build(self, name, names=None):
        data = mesher.MeshData()
        self.run(self.prefabs[name], data, dict(names or {}))
        return data

    def run(self, element, data, names, at=(0, 0)):
        for child in element:
            if not isinstance(child.tag, str):
                continue
            if child.tag == 'let':
                names[child.get('name')] = self.value(fill(child.get('value'), names))
            else:
                self.node(child, data, names, at)

    @staticmethod
    def value(text):
        try:
            return float(text)
        except ValueError:
            return text

    def node(self, element, data, names, at):
        a = Attributes(element, names)
        tag = element.tag
        role, sharp = a.get('role'), a.number('sharp')
        place = a.vector('at')
        xy = (at[0] + place[0], at[1] + place[1])
        if tag == 'use':
            inner = {key: self.value(value) for key, value in a.values.items() if key not in ('prefab', 'at')}
            self.run(self.prefabs[a.get('prefab')], data, {**names, **inner}, xy)
        elif tag == 'lathe':
            mesher.lathe(data, pairs(a.get('points')), role, int(a.number('segments', 48)), xy, a.number('planar'), sharp if sharp is not None else 38)
        elif tag == 'torus':
            mesher.ring(data, a.number('major'), a.number('minor'), a.number('z'), role, xy, int(a.number('segments', 48)), int(a.number('sides', 8)))
        elif tag == 'polyline':
            self.line(element, a, data, names, xy)
        elif tag == 'each-corner':
            outline = mesher.ccw(pairs(a.get('points')))
            for corner in mesher.inset_polygon(outline, a.number('inset', 0)):
                self.run(element, data, names, (corner[0], corner[1]))
        else:
            outline = outline_of(a)
            if outline is None:
                raise ValueError(f'Unknown element <{tag}>')
            self.shape(element, a, outline, data, names)

    def line(self, element, a, data, names, xy):
        path = pairs(a.get('points'))
        for modifier in element:
            m = Attributes(modifier, names)
            if modifier.tag != 'sweep':
                raise ValueError(f'<polyline> takes <sweep>, not <{modifier.tag}>')
            mesher.sweep(data, path, pairs(m.get('section')), a.get('role'), m.get('closed') == 'true', None, a.number('sharp', 38))

    def shape(self, element, a, outline, data, names):
        """Modifiers run in order. A shape with none lies flat at its height."""
        role, sharp, z = a.get('role'), a.number('sharp'), a.number('z', 0)
        uv = a.vector('uv', None) if a.get('uv') else None
        extrude = bevel = None
        made = False
        for modifier in element:
            if not isinstance(modifier.tag, str):
                continue
            m = Attributes(modifier, names)
            if modifier.tag == 'fillet':
                outline = mesher.filleted(mesher.ccw(outline), m.number('radius'), int(m.number('arc', 8)))
            elif modifier.tag == 'inset':
                outline = mesher.inset_polygon(mesher.ccw(outline), m.number('amount'))
            elif modifier.tag == 'extrude':
                extrude = m.number('amount')
            elif modifier.tag == 'bevel':
                bevel = m.number('amount')
            elif modifier.tag == 'sweep':
                mesher.sweep(data, [(*p, z) for p in outline], pairs(m.get('section')), role, True, None, sharp if sharp is not None else 38)
                made = True
            elif modifier.tag == 'dome':
                mesher.dome(data, outline, pairs(m.get('rings')), m.number('apex'), role, sharp if sharp is not None else 60, (0, 0) if m.get('centre') == 'origin' else None)
                made = True
            else:
                raise ValueError(f'Unknown modifier <{modifier.tag}>')
        if extrude is not None:
            mesher.plate(data, outline, z, extrude, role, 0, bevel or 0, sharp if sharp is not None else 40, uv)
        elif not made:
            mesher.flat(data, outline, z, role, sharp if sharp is not None else 90, uv)
