"""Lets the add-on's geometry run without Blender: a small stand-in for mathutils.Vector,
and a way to import pinball_builder's plain-Python modules without its bpy-bound package."""
import importlib
import math
import sys
import types
from pathlib import Path


class Vector:
    __slots__ = ('v',)

    def __init__(self, values=(0, 0, 0)):
        self.v = tuple(float(c) for c in values)

    x = property(lambda self: self.v[0])
    y = property(lambda self: self.v[1])
    z = property(lambda self: self.v[2] if len(self.v) > 2 else 0.0)
    xy = property(lambda self: Vector(self.v[:2]))
    length_squared = property(lambda self: sum(c * c for c in self.v))
    length = property(lambda self: math.sqrt(self.length_squared))

    def __iter__(self):
        return iter(self.v)

    def __len__(self):
        return len(self.v)

    def __getitem__(self, i):
        return self.v[i]

    def __add__(self, o):
        return Vector(a + b for a, b in zip(self.v, o))

    def __sub__(self, o):
        return Vector(a - b for a, b in zip(self.v, o))

    def __neg__(self):
        return Vector(-a for a in self.v)

    def __mul__(self, k):
        return Vector(a * k for a in self.v)

    __rmul__ = __mul__

    def __truediv__(self, k):
        return Vector(a / k for a in self.v)

    def copy(self):
        return Vector(self.v)

    def to_3d(self):
        return Vector((self.x, self.y, self.z))

    def dot(self, o):
        return sum(a * b for a, b in zip(self.v, o))

    def cross(self, o):
        a, b = self.to_3d(), Vector(o).to_3d()
        return Vector((a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x))

    def lerp(self, o, t):
        return Vector(a + (b - a) * t for a, b in zip(self.v, o))

    def normalized(self):
        size = self.length
        return Vector(a / size for a in self.v) if size > 0 else Vector(self.v)


ROOT = Path(__file__).resolve().parents[2]
if 'mathutils' not in sys.modules:
    sys.modules['mathutils'] = types.SimpleNamespace(Vector=Vector)
package = types.ModuleType('pinball_geometry')
package.__path__ = [str(ROOT / 'tools/blender_addons/pinball_builder')]
sys.modules['pinball_geometry'] = package
geometry = importlib.import_module('pinball_geometry.geometry')
sys.path.insert(0, str(ROOT / 'tools'))
import ramp_paths  # noqa: E402
