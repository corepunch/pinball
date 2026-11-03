#!/usr/bin/env python3
"""Paint the ramp floor's brushed aluminum: fine streaks along the path, darker toward the walls.

U runs along the ramp and repeats; V runs across its floor. Colour rather than grey, as 8-bit grey
textures crash the iOS simulator's Metal validation. Writes GameData/Materials/brushed-aluminum.png.
"""
import math
import random
from pathlib import Path

from PIL import Image

WIDTH, HEIGHT = 1024, 256
ROW_HEIGHT = 3
OUT = Path(__file__).resolve().parents[1] / 'GameData/Materials/brushed-aluminum.png'


def streaks(rng, wavelength):
    """One row's brightness along U, as smooth noise that repeats at the texture's width."""
    count = max(2, WIDTH // wavelength)
    knots = [rng.random() for _ in range(count)]
    row = []
    for x in range(WIDTH):
        f = x / WIDTH * count
        i = int(f)
        t = f - i
        t = t * t * (3 - 2 * t)
        row.append(knots[i % count] * (1 - t) + knots[(i + 1) % count] * t)
    return row


def main():
    rng = random.Random(41)
    image = Image.new('RGBA', (WIDTH, HEIGHT))
    pixels = image.load()
    # Soft patches, varying along the ramp as well as across it, so nothing runs as an endless line.
    columns, rows = 12, 6
    patches = [[rng.random() for _ in range(columns)] for _ in range(rows + 1)]
    grain = []
    # Rows are grouped: a single row is finer than a pixel on a phone, and would average away.
    for _ in range(HEIGHT // ROW_HEIGHT + 1):
        grain.append((streaks(rng, 34), streaks(rng, 110)))
    for y in range(HEIGHT):
        v = y / (HEIGHT - 1)
        # Ambient occlusion from the walls.
        edge = min(v, 1 - v) * 2
        occlusion = .66 + .34 * min(edge / .3, 1) ** .7
        short_streaks, long_streaks = grain[y // ROW_HEIGHT]
        for x in range(WIDTH):
            fx, fy = x / WIDTH * columns, v * rows
            ix, iy = int(fx), min(int(fy), rows - 1)
            tx, ty = fx - ix, fy - iy
            top = patches[iy][ix % columns] * (1 - tx) + patches[iy][(ix + 1) % columns] * tx
            low = patches[iy + 1][ix % columns] * (1 - tx) + patches[iy + 1][(ix + 1) % columns] * tx
            patch = top * (1 - ty) + low * ty
            value = occlusion * (.76 + .09 * patch + .15 * (short_streaks[x] * .65 + long_streaks[x] * .35))
            value = min(value, 1)
            pixels[x, y] = (round(value * 255), round(value * 250), round(value * 240), 255)
    image.save(OUT)


if __name__ == '__main__':
    main()
