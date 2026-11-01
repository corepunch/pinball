#!/usr/bin/env python3
"""Side-by-side crops of the concept and a board render, area by area.

The concept's panel is narrower than the table, so areas are matched by hand: each gives the
concept's rectangle in its image, and the table rectangle showing the same part of the board.

Usage: tools/compare_concept.py render.png output-directory [orbital|abyss]
"""
import math
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
PANELS = {'orbital': 18, 'abyss': 401}
PANE = (760, 900)
# The camera puts the table's foot on the image's lower edge.
FORESHORTEN = math.cos(math.radians(30))

# name: (concept x0, y0, x1, y1 relative to the panel), (table x0, y0, x1, y1)
AREAS = {
    'top': ((0, 10, 360, 150), (0, 1.78, 1, 2.168)),
    'bumpers': ((90, 110, 360, 300), (.15, 1.46, .85, 1.86)),
    'ramp-left': ((0, 40, 170, 370), (0, 1.0, .36, 2.0)),
    'ramp-right': ((190, 40, 360, 370), (.62, 1.0, 1, 2.0)),
    'centre': ((60, 290, 300, 520), (.2, .95, .75, 1.45)),
    'left-side': ((0, 320, 120, 720), (0, .5, .2, 1.3)),
    'right-side': ((240, 320, 360, 720), (.78, .5, 1, 1.3)),
    'slings': ((0, 660, 360, 800), (0, .42, 1, .72)),
    'flippers': ((0, 740, 360, 930), (0, .22, 1, .52)),
}


def remap(y):
    """Area coordinates predate the layout that fills the phone."""
    return y - .2 + (.318 if y > 1.48 else 0)


def fit(image):
    scale = min(PANE[0] / image.width, PANE[1] / image.height)
    return image.resize((round(image.width * scale), round(image.height * scale)), Image.LANCZOS)


def main():
    render = Image.open(sys.argv[1]).convert('RGB')
    output = Path(sys.argv[2])
    output.mkdir(parents=True, exist_ok=True)
    skin = sys.argv[3] if len(sys.argv) > 3 else 'orbital'
    concept = Image.open(ROOT / 'Art/Concepts/premium-directions.png').convert('RGB')
    panel = PANELS[skin]
    scale = render.width
    for name, ((cx0, cy0, cx1, cy1), (x0, y0, x1, y1)) in AREAS.items():
        left = fit(concept.crop((panel + cx0, cy0, panel + cx1, cy1)))
        right = fit(render.crop((round(x0 * scale), round(render.height - remap(y1) * FORESHORTEN * scale),
                                 round(x1 * scale), round(render.height - remap(y0) * FORESHORTEN * scale))))
        sheet = Image.new('RGB', (left.width + right.width + 12, max(left.height, right.height)), (255, 0, 255))
        sheet.paste(left, (0, 0))
        sheet.paste(right, (left.width + 12, 0))
        sheet.save(output / f'{skin}-{name}.png')


if __name__ == '__main__':
    main()
