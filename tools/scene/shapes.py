"""Small helpers the table tools share: safe arithmetic for {expressions} in scene XML, and convex
outlines with round corners."""
import ast
import math
import operator

from vector import Vector

OPS = {ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul, ast.Div: operator.truediv, ast.Pow: operator.pow, ast.USub: operator.neg}
FUNCS = {'cos': math.cos, 'sin': math.sin, 'sqrt': math.sqrt, 'radians': math.radians, 'min': min, 'max': max}


def evaluate(node, names):
    """Arithmetic only: numbers, named values, + - * / **, and a few math functions."""
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


def signed_area(outline):
    return sum(outline[i][0] * outline[(i + 1) % len(outline)][1] - outline[(i + 1) % len(outline)][0] * outline[i][1] for i in range(len(outline))) * .5


def ccw(outline):
    return outline if signed_area(outline) > 0 else outline[::-1]


def filleted(outline, radius, arc=8):
    """A convex counter-clockwise polygon with round corners."""
    out = []
    n = len(outline)
    for i in range(n):
        p, a, b = Vector(outline[i]), Vector(outline[i - 1]), Vector(outline[(i + 1) % n])
        t0, t1 = (p - a).normalized(), (b - p).normalized()
        turn = math.acos(max(-1, min(1, t0.dot(t1))))
        reach = radius * math.tan(turn * .5)
        start = p - t0 * reach
        centre = start + Vector((-t0.y, t0.x)) * radius
        a0 = math.atan2((start - centre).y, (start - centre).x)
        for k in range(arc + 1):
            q = centre + Vector((math.cos(a0 + turn * k / arc), math.sin(a0 + turn * k / arc))) * radius
            out.append((q.x, q.y))
    return out
