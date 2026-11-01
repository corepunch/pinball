"""Paint the metal MatCap, via Blender MCP, using Blender's image and numpy.

A MatCap (material capture, or sphere map) stores how a material looks for every facing
direction, so a shader needs only the surface normal to look it up. Every metal in the game
uses this one image, tinted by the skin: a metal's reflections take its colour, so a single
neutral capture serves brass, aluminium and chrome.

Painted rather than rendered, for direct control over the polished look of the concept's
ramps: a mid-tone body with fine bright streaks. The camera's tilt puts a flat part's normal
at BODY, so that is where the base tone sits, and parts that curve away sweep across the bands.
Writes GameData/Materials/matcap-metal.png.
"""
import bpy
import numpy
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'GameData/Materials'
OUT.mkdir(parents=True, exist_ok=True)
SIZE = 512
BODY = (0.0, 0.31)  # sin(18°): an up-facing normal, seen by the tilted camera.

axis = (numpy.arange(SIZE) + .5) / SIZE * 2 - 1
x, y = numpy.meshgrid(axis, axis[::-1])  # Rows run from the top of the image.
radius = numpy.sqrt(x * x + y * y)
dx, dy = x - BODY[0], y - BODY[1]
d = numpy.sqrt(dx * dx + dy * dy)
angle = numpy.arctan2(dy, dx)


def band(distance, width):
    return numpy.exp(-(distance / width) ** 2)


# Streaks break up around the sphere, as light from long strip lamps does. A ramp's floor spans
# only a small patch around BODY, turning as the ramp bends, so its glints come from the inner bands.
glints = numpy.clip(numpy.cos(5 * angle + .7), 0, 1) ** 2
glints_b = numpy.clip(numpy.cos(3 * angle - 1.3), 0, 1) ** 2
broken_c = .5 + .5 * numpy.cos(2 * angle - 1.1)

tone = .54 + .18 * y
tone += .5 * band(d - .1, .045) * glints         # Fine glints on the floor's gentle curve.
tone -= .12 * band(d - .17, .03)
tone += .7 * band(d - .25, .055) * glints_b      # Where the floor starts to bank.
tone -= .2 * band(d - .4, .07)                    # Dark valley, for contrast along the walls.
tone += .85 * band(d - .6, .06) * broken_c        # The bright streak on banked parts.
tone -= .22 * band(d - .8, .075)                  # Dark before the edge.
tone += .85 * band(x + .36, .1) * band(y - .62, .14)  # Hot window highlight, upper left.
tone += .5 * band(x - .46, .05) * band(y - .55, .3)   # Slim strip, upper right.
tone += .55 * numpy.clip(radius, 0, 1) ** 8       # Grazing rim.
tone = numpy.clip(tone, 0, 1)

pixels = numpy.ones((SIZE, SIZE, 4), dtype=numpy.float32)
pixels[..., :3] = tone[..., None]
image = bpy.data.images.get('matcap-metal') or bpy.data.images.new('matcap-metal', SIZE, SIZE, alpha=False)
image.colorspace_settings.name = 'Non-Color'
image.pixels.foreach_set(pixels[::-1].ravel())  # Blender stores rows from the bottom.
image.filepath_raw = str(OUT / 'matcap-metal.png')
image.file_format = 'PNG'
image.save()
bpy.data.images.remove(image)
result = {'matcap': str(OUT / 'matcap-metal.png')}
