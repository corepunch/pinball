#!/usr/bin/env python3
"""Skin pipeline for the pinball tables. Needs only Pillow.

  skin_tool.py template [table]        Draw the layout guides to hand to an image model.
  skin_tool.py demo                    Paint the Classic and Neon skins procedurally.
  skin_tool.py ingest art.png NAME     Validate a painted atlas and install it as a skin.

One atlas image per skin: a 2:3 canvas, which is the tall format image models produce
natively. The table's aspect is the phone's, so at full canvas height the playfield
takes the left 69% and small parts share the right column. Nothing is lost by combining
them, and one image keeps the style of all the parts coherent.
"""
import json, math, pathlib, random, sys
from PIL import Image, ImageChops, ImageDraw, ImageEnhance, ImageFilter, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent.parent
RES = ROOT / "GameData"
LAYOUT = json.loads((RES / "atlas_layout.json").read_text())
CANVAS = tuple(LAYOUT["canvas"])
SLOTS = LAYOUT["slots"]
FONT = "/System/Library/Fonts/Helvetica.ttc"


def font(size):
    return ImageFont.truetype(FONT, size)


def rect(slot):
    x, y, w, h = SLOTS[slot]["rect"]
    return x, y, x + w, y + h


def load_table(name):
    return json.loads((RES / "Tables" / f"{name}.json").read_text())


def expand(points):
    out = []
    for p in points:
        if isinstance(p, dict):
            cx, cy, r, a0, a1, n = p["arc"]
            for i in range(n + 1):
                a = math.radians(a0 + (a1 - a0) * i / n)
                out.append((cx + r * math.cos(a), cy + r * math.sin(a)))
        else:
            out.append(tuple(p[:2]))
    return out


class Mapper:
    """Table coordinates (widths, y up) to atlas pixels in the playfield slot."""

    def __init__(self, table):
        x, y, w, h = SLOTS["playfield"]["rect"]
        self.scale = w / table["size"][0]
        self.ox, self.oy, self.h = x, y, h
        self.th = table["size"][1]

    def __call__(self, p):
        return (self.ox + p[0] * self.scale, self.oy + self.h - p[1] * self.scale)

    def many(self, pts):
        return [self(p) for p in pts]


# ---------------------------------------------------------------- templates


def draw_slot_guides(d, labels):
    glyph = (70, 70, 80)
    for name, slot in SLOTS.items():
        if name == "playfield":
            continue
        x0, y0, x1, y1 = rect(name)
        d.rectangle((x0, y0, x1 - 1, y1 - 1), outline=(120, 120, 130), width=3, fill=(214, 214, 220))
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        w, h = x1 - x0, y1 - y0
        if name == "bumper_cap":
            d.ellipse((x0 + 12, y0 + 12, x1 - 12, y1 - 12), outline=glyph, width=6)
        elif name == "flipper":
            d.rounded_rectangle((x0 + 20, y0 + 30, x1 - 20, y1 - 30), radius=45, outline=glyph, width=6)
            d.ellipse((x0 + 34, cy - 22, x0 + 78, cy + 22), outline=glyph, width=5)
        elif name == "slingshot":
            d.polygon([(x0 + 40, y0 + 25), (x0 + 40, y1 - 60), (x1 - 40, y1 - 25)], outline=glyph, width=6)
        elif name == "ramp":
            d.line((x0 + 30, y1, x0 + 30, y0), fill=glyph, width=4)
            d.line((x1 - 30, y1, x1 - 30, y0), fill=glyph, width=4)
        elif name == "inserts":
            for i in range(1, 4):
                d.line((x0 + w * i / 4, y0, x0 + w * i / 4, y1), fill=glyph, width=3)
                d.line((x0, y0 + h * i / 4, x1, y0 + h * i / 4), fill=glyph, width=3)
        elif name == "dmd_bezel":
            d.rectangle((x0 + 50, y0 + 22, x1 - 50, y1 - 22), fill=(40, 40, 46))
        elif name in ("drop_target", "standup", "spinner", "gate"):
            d.rectangle((x0 + 14, y0 + 14, x1 - 14, y1 - 14), outline=glyph, width=4)
        if labels:
            size = 21 if w > 200 else 15
            text = slot["label"]
            d.text((x0 + 8, y0 + 6), text, fill=(180, 0, 60), font=font(size))


def draw_template(table, labels):
    img = Image.new("RGB", CANVAS, (232, 232, 236))
    d = ImageDraw.Draw(img)
    m = Mapper(table)
    px0, py0, px1, py1 = rect("playfield")
    d.rectangle((px0, py0, px1, py1), fill=(248, 248, 250))
    draw_slot_guides(d, labels)

    wall, moving, lamp_c, active = (90, 90, 100), (40, 110, 200), (235, 150, 20), (200, 60, 150)

    # Apron and the Dynamic Island band: flat art zones, drawn at table scale.
    ax0, ay0 = m((0, table["apron"]["y"]))
    ax1, ay1 = m((1.0, 0))
    d.rectangle((ax0, ay0, ax1, ay1), fill=(226, 226, 232))

    for w in table["walls"]:
        if w.get("style") == "none":
            continue
        pts = m.many(expand(w["points"]))
        if w.get("closed"):
            pts.append(pts[0])
        d.line(pts, fill=wall, width=max(4, int(w["radius"] * 2 * m.scale)), joint="curve")
    for p in table["posts"]:
        cx, cy = m((p["x"], p["y"]))
        r = p["r"] * m.scale
        d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=wall)
    for b in table["bumpers"]:
        cx, cy = m((b["x"], b["y"]))
        r = b["r"] * m.scale
        d.ellipse((cx - r, cy - r, cx + r, cy + r), outline=active, width=8)
    for s in table["slingshots"]:
        d.line([m(s["a"]), m(s["b"])], fill=active, width=9)
    for f in table["flippers"]:
        a = math.radians(f["restAngle"])
        tip = (f["pivot"][0] + f["length"] * math.cos(a), f["pivot"][1] + f["length"] * math.sin(a))
        d.line([m(f["pivot"]), m(tip)], fill=moving, width=int(f["baseRadius"] * 2 * m.scale))
    for key in ("dropTargets", "standups", "spinners"):
        for e in table[key]:
            d.line([m(e["a"]), m(e["b"])], fill=moving, width=9)
    for g in table["gates"]:
        d.line([m(g["a"]), m(g["b"])], fill=(150, 150, 160), width=3)
    for r in table["rollovers"]:
        cx, cy = m((r["x"], r["y"]))
        s = r["r"] * m.scale * 0.6
        d.line((cx, cy - s, cx, cy + s), fill=(150, 150, 160), width=3)
    for s in table["saucers"]:
        cx, cy = m((s["x"], s["y"]))
        r = s["r"] * m.scale
        d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(60, 60, 66))
    for ramp in table["ramps"]:
        pts = m.many(ramp["points"])
        d.line(pts, fill=(170, 170, 200), width=int(ramp["width"] * m.scale), joint="curve")
    for l in table["lamps"]:
        cx, cy = m((l["x"], l["y"]))
        r = l["size"] * m.scale
        d.ellipse((cx - r, cy - r, cx + r, cy + r), outline=lamp_c, width=5)
    for f in table["flashers"]:
        cx, cy = m((f["x"], f["y"]))
        d.ellipse((cx - 26, cy - 26, cx + 26, cy + 26), outline=(235, 60, 40), width=5)

    if labels:
        legend = [("WALLS & POSTS  raised, engine-drawn", wall), ("KICKERS  bumpers, slingshots", active),
                  ("MOVING PARTS  flippers, targets", moving), ("INSERT LAMPS  engine draws lens here", lamp_c),
                  ("RAMP  transparent, art shows through", (150, 150, 190))]
        y = 2820
        d.text((1437, y), "LEGEND", fill=(0, 0, 0), font=font(26))
        for text, color in legend:
            y += 34
            d.rectangle((1437, y + 4, 1467, y + 24), fill=color)
            d.text((1477, y), text, fill=(0, 0, 0), font=font(19))
        for name, pos in (("PLAYFIELD ART: paint edge to edge", (0.17, 0.72)), ("APRON", (0.08, 0.20)),
                          ("TOP BAND: hidden behind the phone's island", (0.12, 2.10))):
            d.text(m(pos), name, fill=(180, 0, 60), font=font(28))
    return img


def cmd_template(table_name="aurora"):
    table = load_table(table_name)
    out = ROOT / "Art" / "Templates" / table_name
    out.mkdir(parents=True, exist_ok=True)
    draw_template(table, labels=False).save(out / "layout_for_imagegen.png")
    draw_template(table, labels=True).save(out / "layout_annotated.png")
    print("wrote", out)


# ---------------------------------------------------------------- demo art


def vgrad(size, stops):
    """Vertical gradient from (position, rgb) stops."""
    w, h = size
    col = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / max(h - 1, 1)
        for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
            if t0 <= t <= t1:
                k = (t - t0) / max(t1 - t0, 1e-5)
                col.putpixel((0, y), tuple(int(a + (b - a) * k) for a, b in zip(c0, c1)))
                break
    return col.resize((w, h))


def glow_layer(size, draw_fn, blur):
    layer = Image.new("RGB", size, (0, 0, 0))
    draw_fn(ImageDraw.Draw(layer))
    return layer.filter(ImageFilter.GaussianBlur(blur))


def add(img, layer):
    return ImageChops.add(img, layer)


def noise_tile(size, base, amount, seed, blur=0.7):
    rng = random.Random(seed)
    data = bytes(max(0, min(255, base + rng.randint(-amount, amount))) for _ in range(size * size))
    tile = Image.frombytes("L", (size, size), data)
    return tile.filter(ImageFilter.GaussianBlur(blur)) if blur else tile


def star_points(cx, cy, r, inner=0.42, n=5, rot=-90):
    pts = []
    for i in range(n * 2):
        a = math.radians(rot + i * 180 / n)
        rr = r if i % 2 == 0 else r * inner
        pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
    return pts


PLAYFIELD_SIZE = (851, 1848)
PAINT_SCALE = 2


def radial_fade(size, centre, radius, inner=255, outer=0):
    """A mask falling from inner at the centre to outer at the radius, drawn small as it is smooth anyway."""
    w, h = size[0] // 8, size[1] // 8
    mask = Image.new("L", (w, h))
    cx, cy, r = centre[0] / 8, centre[1] / 8, radius / 8
    for y in range(h):
        for x in range(w):
            k = min(math.hypot(x - cx, y - cy) / r, 1)
            mask.putpixel((x, y), int(inner + (outer - inner) * k * k * (3 - 2 * k)))
    return mask.resize(size, Image.Resampling.BICUBIC)


def vignette(img, strength):
    w, h = img.size
    mask = radial_fade(img.size, (w / 2, h * .55), h * .62, 255, int(255 * (1 - strength)))
    return ImageChops.multiply(img, Image.merge("RGB", [mask] * 3))


def fill_through(base, colour, mask):
    return Image.composite(Image.new("RGB", base.size, colour), base, mask)


def finish_playfield(img):
    img = img.resize(PLAYFIELD_SIZE, Image.Resampling.LANCZOS)
    grain = noise_tile(PLAYFIELD_SIZE[0], 128, 16, 5, .6).resize(PLAYFIELD_SIZE)
    return ImageChops.overlay(img, Image.merge("RGB", [grain] * 3))


def paint_classic_playfield():
    """A 1960s backglass sunburst, seen dim: its colour comes up only near the middle of the board."""
    size = (w, h) = (PLAYFIELD_SIZE[0] * PAINT_SCALE, PLAYFIELD_SIZE[1] * PAINT_SCALE)
    base = vgrad(size, [(0, (18, 7, 12)), (.45, (50, 15, 16)), (.72, (44, 13, 15)), (1, (14, 6, 10))])
    cx, cy = w * .5, h * .52

    rays = Image.new("L", size)
    d = ImageDraw.Draw(rays)
    count = 24
    for i in range(0, count, 2):
        a0, a1 = [math.radians(-90 + (i + o) * 360 / count) for o in (0, 1)]
        d.polygon([(cx, cy), (cx + 4 * h * math.cos(a0), cy + 4 * h * math.sin(a0)), (cx + 4 * h * math.cos(a1), cy + 4 * h * math.sin(a1))], fill=255)
    rays = rays.filter(ImageFilter.GaussianBlur(3))
    near = radial_fade(size, (cx, cy), h * .6, 255, 96)
    base = fill_through(base, (128, 54, 20), ImageChops.multiply(rays, near).point(lambda v: v * .82))

    # A soft-edged sun hides where the rays meet, with no hard circle to fight the parts on top of it.
    glow = radial_fade(size, (cx, cy), w * .4, 255, 0).point(lambda v: min(v * 1.7, 225))
    base = fill_through(base, (142, 66, 22), glow)

    # Broad scalloped bands, the era's other trademark, at the head and foot of the board.
    bands = Image.new("L", size)
    d = ImageDraw.Draw(bands)
    for r in (h * .34, h * .395, h * .45):
        d.arc((cx - r, cy - r, cx + r, cy + r), 0, 360, fill=255, width=int(w * .024))
    base = fill_through(base, (24, 12, 22), bands.filter(ImageFilter.GaussianBlur(2)).point(lambda v: v * .6))

    stars = Image.new("L", size)
    d = ImageDraw.Draw(stars)
    rng = random.Random(21)
    for _ in range(46):
        x, y = rng.uniform(0, w), rng.uniform(0, h)
        if math.hypot(x - cx, y - cy) < w * .3:
            continue
        d.polygon(star_points(x, y, rng.uniform(.012, .03) * w, rot=rng.uniform(-110, -70)), fill=rng.randint(130, 210))
    base = fill_through(base, (206, 168, 104), stars.filter(ImageFilter.GaussianBlur(1)))
    return finish_playfield(vignette(base, .42))


def paint_neon_playfield():
    """A synthwave night drive under an aurora, dim enough for the board's own lamps to lead."""
    size = (w, h) = (PLAYFIELD_SIZE[0] * PAINT_SCALE, PLAYFIELD_SIZE[1] * PAINT_SCALE)
    horizon = h * .7
    base = vgrad(size, [(0, (5, 3, 20)), (.4, (17, 7, 46)), (.69, (58, 13, 74)), (.7, (10, 4, 26)), (1, (4, 2, 14))])

    def ribbons(d):
        for colour, y0, amp, width in (((18, 118, 116), .15, .035, 54), ((92, 30, 148), .21, .045, 76), ((22, 90, 130), .34, .03, 48)):
            points = [(x, h * (y0 + amp * math.sin(x / w * 7 + y0 * 20) + amp * .4 * math.sin(x / w * 17))) for x in range(-40, w + 60, 24)]
            d.line(points, fill=colour, width=width * PAINT_SCALE, joint="curve")
    base = add(base, glow_layer(size, ribbons, 46))

    rng = random.Random(7)
    stars = Image.new("L", size)
    d = ImageDraw.Draw(stars)
    for _ in range(170):
        x, y, r = rng.uniform(0, w), rng.uniform(0, horizon * .92), rng.uniform(1.6, 4.5)
        d.ellipse((x - r, y - r, x + r, y + r), fill=rng.randint(70, 190))
    base = fill_through(base, (206, 202, 236), stars)

    # A sun sinking behind the hills, cut by the usual bands. Soft, and far below full colour.
    cx, cy, r = w * .5, horizon - w * .13, w * .33
    disc = Image.new("L", size)
    d = ImageDraw.Draw(disc)
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=255)
    y, step = cy - r * .42, r * .17
    while y < cy + r:
        d.rectangle((0, y, w, y + step * (.2 + .32 * (y - cy + r * .42) / (r * 1.42))), fill=0)
        y, step = y + step, step * .94
    d.rectangle((0, horizon, w, h), fill=0)
    disc = disc.filter(ImageFilter.GaussianBlur(3))
    sun = vgrad(size, [(0, (186, 118, 44)), (.5, (196, 124, 48)), (.58, (178, 62, 70)), (.7, (128, 18, 92)), (1, (128, 18, 92))])
    base = Image.composite(sun, base, disc.point(lambda v: v * .6))
    base = add(base, Image.merge("RGB", [radial_fade(size, (cx, cy), r * 2.1, v, 0) for v in (46, 10, 52)]))

    hills = Image.new("L", size)
    d = ImageDraw.Draw(hills)
    points = [(0, horizon)]
    x = 0
    while x < w:
        x += rng.uniform(.06, .13) * w
        side = abs(x / w - .5) * 2
        points.append((x, horizon - rng.uniform(.25, 1) * (.018 + .085 * side ** 1.3) * h))
        x += rng.uniform(.04, .1) * w
        points.append((x, horizon - rng.uniform(.0, .25) * .03 * h))
    points.append((w, horizon))
    d.polygon(points, fill=255)
    base = fill_through(base, (10, 4, 28), hills)

    def grid(d):
        vx, vy = w * .5, horizon
        for i in range(-13, 14):
            d.line((vx + i * w * .018, vy, vx + i * w * .27, h), fill=(96, 20, 112), width=5 * PAINT_SCALE)
        y = 0.008
        while y < 1:
            d.line((0, vy + y * (h - vy), w, vy + y * (h - vy)), fill=(96, 20, 112), width=max(3, int(10 * y ** .5)) * PAINT_SCALE)
            y = y * 1.48 + .012
    ground = add(Image.new("RGB", size), glow_layer(size, grid, 2))
    base = add(base, ImageChops.multiply(ground, vgrad(size, [(0, (0, 0, 0)), (.7, (255, 255, 255)), (.85, (170, 170, 170)), (1, (60, 60, 60))])))
    return finish_playfield(vignette(base, .5))


def recolour_atlas(hues):
    """The finished Orbital atlas in another palette. Only hue moves, keeping all its painted light;
    its gold and cream sit outside the hue ranges and stay as they are."""
    h, s, v = Image.open(ROOT / "Art/Masters/orbital-hardware.png").convert("HSV").split()

    def moved(value):
        degrees = value * 360 / 255
        for (low, high), target in hues:
            if low <= degrees <= high or low <= degrees - 360 <= high:
                return int(target * 255 / 360) % 256
        return value
    return Image.merge("HSV", (h.point(moved), s, v)).convert("RGB")


# Reds are 345 to 20 degrees, Orbital's navy 195 to 255. The MatCaps and the room stay shared, like the kit.
PREMIUM_BASE = {
    "white": [1, 0.92, 0.72], "accent": [1, 0.9, 0.71], "ambient": 0.82, "key": [1, 0.94, 0.82], "keyIntensity": 1050, "plasticOpacity": 0.96,
    "metal": [1, 0.975, 0.9], "rubber": [0.94, 0.89, 0.75], "modelKit": "premium",
    "materials": {"metalness": 0.88, "roughness": 0.24, "playfieldReflectivity": 0.15, "bloom": 0.34, "rampOpacity": 1.0,
                  "matcap": "studio", "rampMatcap": "studio", "rampBlur": 2.5, "rampGloss": 0.1},
}
PREMIUM_SKINS = {
    "classic": {
        "name": "Classic", "paint": paint_classic_playfield, "hues": [((-15, 20), 22), ((195, 255), 218)],
        "lamps": {"cyan": [0.48, 0.74, 0.78], "amber": [1, 0.65, 0.16], "magenta": [0.96, 0.36, 0.22], "green": [0.55, 0.85, 0.4], "red": [1, 0.2, 0.12], "bumper": [1, 0.62, 0.14]},
        "shell": [0.06, 0.13, 0.32], "flipperRubber": [0.62, 0.17, 0.03], "dmd": [1, 0.55, 0.13], "slingLens": [1, 0.3, 0.05],
        "capBase": [0.92, 0.84, 0.66], "capStar": [0.68, 0.2, 0.04], "rampGlass": [0.1, 0.055, 0.03],
    },
    "neon": {
        "name": "Neon", "paint": paint_neon_playfield, "hues": [((-15, 20), 322), ((195, 255), 268)],
        "lamps": {"cyan": [0.2, 0.85, 1], "amber": [1, 0.65, 0.14], "magenta": [1, 0.18, 0.68], "green": [0.25, 0.95, 0.55], "red": [1, 0.2, 0.2], "bumper": [0.2, 0.85, 1]},
        "shell": [0.42, 0.05, 0.42], "flipperRubber": [0.05, 0.27, 0.42], "dmd": [1, 0.32, 0.72], "slingLens": [0.9, 0.1, 0.55],
        "capBase": [0.1, 0.07, 0.24], "capStar": [1, 0.32, 0.72], "rampGlass": [0.07, 0.03, 0.12],
    },
}


# What an ingested atlas starts from.
NEON_PALETTE = {
    "lamps": {"cyan": [0.2, 0.85, 1.0], "white": [1.0, 0.95, 0.9], "amber": [1.0, 0.65, 0.12], "magenta": [1.0, 0.15, 0.7], "green": [0.2, 1.0, 0.45], "red": [1.0, 0.16, 0.12]},
    "rubber": [0.95, 0.95, 0.98], "metal": [0.82, 0.84, 0.9], "ambient": 1.0, "key": [1.0, 0.94, 0.9], "keyIntensity": 900, "dmd": [1.0, 0.32, 0.72], "plasticOpacity": 0.72,
}


def install(atlas, name, palette):
    out = RES / "Skins"
    out.mkdir(parents=True, exist_ok=True)
    atlas.convert("RGB").save(out / f"{name}.jpg", quality=88, subsampling=0, optimize=True)
    (out / f"{name}.json").write_text(json.dumps({"id": name, **palette}, indent=2) + "\n")
    print(f"installed {name}: {(out / f'{name}.jpg').stat().st_size // 1024} KB")


def cmd_demo():
    layout = json.loads((RES / "Skins/orbital.json").read_text())["atlasLayout"]
    for name, spec in PREMIUM_SKINS.items():
        spec = dict(spec)
        slots = {slot: dict(value) for slot, value in layout["slots"].items() if not slot.startswith("ramp_chase")}
        slots["playfield"]["file"] = f"{name}-playfield.jpg"
        out = RES / "Skins"
        recolour_atlas(spec.pop("hues")).save(out / f"{name}.jpg", quality=92, subsampling=0, optimize=True)
        spec.pop("paint")().save(out / f"{name}-playfield.jpg", quality=92, subsampling=0, optimize=True)
        lamps = {**spec.pop("lamps"), "white": PREMIUM_BASE["white"]}
        materials = {**PREMIUM_BASE["materials"], "rampGlass": spec.pop("rampGlass")}
        base = {k: v for k, v in PREMIUM_BASE.items() if k not in ("white", "materials")}
        palette = {"id": name, "name": spec.pop("name"), "atlasLayout": {**layout, "slots": slots}, "lamps": lamps, **base, **spec, "materials": materials}
        (out / f"{name}.json").write_text(json.dumps(palette, indent=2) + "\n")
        print(f"installed {name}")


# ---------------------------------------------------------------- ingest


def dominant_lamps(atlas):
    """Keeps lamp hues readable against whatever was painted: lamps stay saturated primaries,
    only warmed or cooled slightly toward the art's average colour."""
    pf = atlas.crop(rect("playfield")).resize((1, 1), Image.Resampling.BOX).getpixel((0, 0))
    avg = [c / 255 for c in pf]
    palette = json.loads(json.dumps(NEON_PALETTE))
    for key, value in palette["lamps"].items():
        palette["lamps"][key] = [round(v * .9 + a * .1, 3) for v, a in zip(value, avg)]
    env = atlas.crop(rect("environment")).resize((1, 1), Image.Resampling.BOX).getpixel((0, 0))
    palette["dmd"] = [round(0.5 + c / 510, 3) for c in env]
    return palette


def cmd_ingest(path, name):
    src = Image.open(path).convert("RGB")
    ratio, expected = src.width / src.height, CANVAS[0] / CANVAS[1]
    if abs(ratio - expected) > 0.02:
        print(f"note: aspect {ratio:.3f} differs from {expected:.3f}. Fitting by cover-crop; ask for a 2:3 image for exact placement.")
        if ratio > expected:
            w = int(src.height * expected)
            src = src.crop(((src.width - w) // 2, 0, (src.width + w) // 2, src.height))
        else:
            h = int(src.width / expected)
            src = src.crop((0, (src.height - h) // 2, src.width, (src.height + h) // 2))
    atlas = src.resize(CANVAS, Image.Resampling.LANCZOS)
    # Image models soften at this scale; gentle sharpening restores edges before compression.
    atlas = atlas.filter(ImageFilter.UnsharpMask(radius=2.2, percent=55, threshold=2))
    install(atlas, name, dominant_lamps(atlas))


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args or args[0] not in ("template", "demo", "ingest"):
        print(__doc__)
    elif args[0] == "template":
        cmd_template(*args[1:])
    elif args[0] == "demo":
        cmd_demo()
    else:
        cmd_ingest(args[1], args[2])
