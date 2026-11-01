#!/usr/bin/env python3
"""Skin pipeline for the pinball tables. Needs only Pillow.

  skin_tool.py template [table]        Draw the layout guides to hand to an image model.
  skin_tool.py demo                    Paint the built-in demo skins procedurally.
  skin_tool.py ingest art.png NAME     Validate a painted atlas and install it as a skin.

One atlas image per skin: a 2:3 canvas, which is the tall format image models produce
natively. The table's aspect is the phone's, so at full canvas height the playfield
takes the left 69% and small parts share the right column. Nothing is lost by combining
them, and one image keeps the style of all the parts coherent.
"""
import json, math, pathlib, random, sys
from PIL import Image, ImageChops, ImageDraw, ImageEnhance, ImageFilter, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent.parent
RES = ROOT / "Pinball" / "GameData"
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
    dx, dy, dw, dh = table["apron"]["dmd"]
    d.rectangle((*m((dx, dy + dh)), *m((dx + dw, dy))), fill=(46, 46, 52))

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


def draw_inserts(atlas):
    """16 white-on-black lamp icons. The engine tints them per lamp."""
    x0, y0, x1, y1 = rect("inserts")
    cell = (x1 - x0) // 4
    sheet = Image.new("L", (cell * 4, cell * 4), 0)
    d = ImageDraw.Draw(sheet)

    def box(i):
        return (i % 4) * cell, (i // 4) * cell

    def centered(i, text, size):
        ox, oy = box(i)
        f = font(size)
        l, t, r, b = d.textbbox((0, 0), text, font=f)
        d.text((ox + (cell - (r - l)) / 2 - l, oy + (cell - (b - t)) / 2 - t), text, fill=255, font=f)

    def poly(i, pts):
        ox, oy = box(i)
        d.polygon([(ox + x * cell, oy + y * cell) for x, y in pts], fill=255)

    poly(0, [(.25, .62), (.5, .3), (.75, .62), (.75, .78), (.5, .48), (.25, .78)])  # chevron
    ox, oy = box(1); d.polygon(star_points(ox + cell / 2, oy + cell / 2, cell * .4), fill=255)
    centered(2, "2X", 62); centered(3, "3X", 62); centered(4, "5X", 62)
    poly(5, [(.5, .1), (.9, .5), (.5, .9), (.1, .5)])  # diamond
    poly(6, [(.58, .08), (.28, .55), (.47, .55), (.4, .92), (.72, .42), (.53, .42)])  # bolt
    poly(7, [(.5, .1), (.85, .52), (.64, .52), (.64, .9), (.36, .9), (.36, .52), (.15, .52)])  # arrow
    ox, oy = box(8); d.ellipse((ox + cell * .22, oy + cell * .22, ox + cell * .78, oy + cell * .78), fill=255)
    ox, oy = box(9); d.ellipse((ox + cell * .15, oy + cell * .15, ox + cell * .85, oy + cell * .85), outline=255, width=16)
    ox, oy = box(10); d.rounded_rectangle((ox + cell * .12, oy + cell * .36, ox + cell * .88, oy + cell * .64), radius=12, fill=255)
    poly(11, [(.5, .12), (.82, .3), (.82, .7), (.5, .88), (.18, .7), (.18, .3)])  # hex
    poly(12, [(.2, .15), (.8, .15), (.8, .55), (.5, .9), (.2, .55)])  # shield
    poly(13, [(.15, .78), (.1, .28), (.33, .5), (.5, .18), (.67, .5), (.9, .28), (.85, .78)])  # crown
    poly(14, [(.5, .1), (.85, .4), (.7, .88), (.3, .88), (.15, .4)])  # gem
    ox, oy = box(15); d.polygon(star_points(ox + cell / 2, oy + cell / 2, cell * .42, inner=.6, n=9), fill=255)

    sheet = sheet.filter(ImageFilter.GaussianBlur(0.7))
    atlas.paste(Image.merge("RGB", (sheet, sheet, sheet)).resize((x1 - x0, y1 - y0)), (x0, y0))


def paint_common_parts(atlas, p):
    """Paints every right-column slot from a palette, so a demo skin is complete."""
    def slot_image(name):
        x0, y0, x1, y1 = rect(name)
        return Image.new("RGB", (x1 - x0, y1 - y0)), (x0, y0)

    # Bumper cap.
    img, pos = slot_image("bumper_cap")
    w, h = img.size
    d = ImageDraw.Draw(img)
    img.paste(vgrad(img.size, [(0, p["cap_a"]), (1, p["cap_b"])]))
    d.ellipse((w * .1, h * .1, w * .9, h * .9), outline=p["accent"], width=12)
    d.polygon(star_points(w / 2, h / 2, w * .3), fill=p["accent2"])
    atlas.paste(img, pos)

    for name in ("slingshot", "plastic"):
        img, pos = slot_image(name)
        img.paste(vgrad(img.size, [(0, p["plastic_a"]), (1, p["plastic_b"])]))
        d = ImageDraw.Draw(img)
        for i in range(6):
            y = img.size[1] * (i + .5) / 6
            d.line((0, y + 40, img.size[0], y - 40), fill=p["accent"], width=5)
        atlas.paste(img, pos)

    img, pos = slot_image("wall_top")
    img.paste(Image.new("RGB", img.size, p["wall"]))
    atlas.paste(ImageChops.multiply(img, Image.merge("RGB", [noise_tile(img.size[0], 215, 30, 3, 1.2)] * 3)), pos)

    img, pos = slot_image("side_rail")
    img.paste(Image.new("RGB", img.size, p["rail"]))
    grain = noise_tile(img.size[0], 200, 45, 4, 0).resize((img.size[0] * 4, img.size[1])).resize(img.size)
    atlas.paste(ImageChops.multiply(img, Image.merge("RGB", [grain] * 3)), pos)

    img, pos = slot_image("flipper")
    img.paste(vgrad(img.size, [(0, p["flipper_a"]), (.5, p["flipper_b"]), (1, p["flipper_a"])]))
    d = ImageDraw.Draw(img)
    d.line((60, img.size[1] / 2, img.size[0] - 40, img.size[1] / 2), fill=p["accent2"], width=10)
    atlas.paste(img, pos)

    img, pos = slot_image("ramp")
    img.paste(vgrad(img.size, [(0, p["ramp_a"]), (1, p["ramp_b"])]))
    d = ImageDraw.Draw(img)
    for i in range(5):
        y = img.size[1] * (i + .5) / 5
        d.polygon([(40, y + 34), (img.size[0] / 2, y - 26), (img.size[0] - 40, y + 34), (img.size[0] - 40, y + 66), (img.size[0] / 2, y + 6), (40, y + 66)], fill=p["accent"])
    atlas.paste(img, pos)

    for name, text in (("drop_target", "D"), ("standup", "S"), ("spinner", "*"), ("gate", "")):
        img, pos = slot_image(name)
        img.paste(vgrad(img.size, [(0, p["accent"]), (1, p["accent3"])]))
        d = ImageDraw.Draw(img)
        d.rectangle((6, 6, img.size[0] - 7, img.size[1] - 7), outline=(255, 255, 255), width=5)
        atlas.paste(img, pos)

    img, pos = slot_image("environment")
    w, h = img.size
    img.paste(vgrad(img.size, [(0, p["env_top"]), (.48, p["env_mid"]), (.52, p["env_low"]), (1, (6, 6, 8))]))
    light = glow_layer(img.size, lambda d: [d.rounded_rectangle((w * i / 3 + 30, h * .1, w * i / 3 + w / 3 - 30, h * .2), radius=8, fill=(255, 250, 235)) for i in range(3)], 3)
    atlas.paste(add(img, light), pos)

    img, pos = slot_image("dmd_bezel")
    img.paste(vgrad(img.size, [(0, p["bezel"]), (1, tuple(c // 2 for c in p["bezel"]))]))
    d = ImageDraw.Draw(img)
    d.rectangle((50, 22, img.size[0] - 51, img.size[1] - 23), fill=(4, 4, 6))
    atlas.paste(img, pos)

    img, pos = slot_image("detail")
    atlas.paste(Image.merge("RGB", [noise_tile(img.size[0], 128, 14, 9, 0.5)] * 3), pos)

    draw_inserts(atlas)


def paint_neon(table):
    size = (SLOTS["playfield"]["rect"][2], SLOTS["playfield"]["rect"][3])
    w, h = size
    m = Mapper(table)
    base = vgrad(size, [(0, (8, 2, 30)), (.35, (32, 6, 74)), (.62, (96, 14, 110)), (.72, (190, 34, 110)), (.74, (18, 6, 44)), (1, (6, 2, 20))])

    # Aurora ribbons across the upper playfield.
    def ribbons(d):
        for k, color in enumerate(((0, 255, 170), (80, 170, 255), (220, 90, 255))):
            pts = []
            for i in range(60):
                x = w * i / 59
                y = h * (.2 + .05 * k) + math.sin(i * .22 + k * 1.8) * 90 + math.sin(i * .07 + k) * 150
                pts.append((x, y))
            d.line(pts, fill=color, width=42)
    base = add(base, glow_layer(size, ribbons, 34))

    # Stars.
    rng = random.Random(7)
    def stars(d):
        for _ in range(420):
            x, y = rng.uniform(0, w), rng.uniform(0, h * .66)
            r = rng.choice((1, 1, 2, 2, 3))
            c = rng.randint(120, 255)
            d.ellipse((x - r, y - r, x + r, y + r), fill=(c, c, 255))
    base = add(base, glow_layer(size, stars, 0.8))

    # Sun over the horizon, with slats.
    cx, cy, sun_r = w * .48, h * .69, w * .3
    def sun(d):
        d.ellipse((cx - sun_r, cy - sun_r, cx + sun_r, cy + sun_r), fill=(255, 120, 60))
    sun_layer = glow_layer(size, sun, 2)
    sun_grad = vgrad(size, [(0, (255, 235, 90)), (.55, (255, 220, 90)), (.72, (255, 40, 130)), (1, (255, 40, 130))])
    mask = sun_layer.convert("L").point(lambda v: 255 if v > 30 else 0)
    slats = ImageDraw.Draw(mask)
    for i in range(7):
        y = cy + i * 34 - 20
        slats.rectangle((0, y, w, y + 6 + i * 3), fill=0)
    base.paste(sun_grad, (0, 0), mask)
    base = add(base, glow_layer(size, sun, 90).point(lambda v: v // 2))
    # Horizon line, below the sun's centre.
    horizon = h * .735
    def perspective(d):
        vanish = (w * .48, horizon)
        for i in range(-16, 17):
            d.line((vanish, (w * .48 + i * 150, h)), fill=(255, 40, 200), width=4)
        y, gap = horizon, 12.0
        while y < h:
            d.line((0, y, w, y), fill=(60, 200, 255), width=3 if gap < 40 else 4)
            y += gap
            gap *= 1.28
    base.paste((12, 3, 34), (0, int(horizon), w, h))
    base = add(base, glow_layer(size, perspective, 1))
    base = add(base, glow_layer(size, perspective, 10).point(lambda v: v // 2))

    # Lane stripes to suggest shot lines, which the art should do.
    def shots(d):
        for a, b, c in (((.48, .5), (.23, .95), (255, 60, 200)), ((.48, .5), (.43, 1.05), (70, 255, 160)), ((.48, .5), (.69, 1.0), (255, 170, 40)), ((.48, .5), (.08, .95), (70, 190, 255)), ((.48, .5), (.88, 1.0), (70, 190, 255))):
            pa, pb = m(a), m(b)
            d.line((pa, pb), fill=c, width=6)
    base = add(base, glow_layer(size, shots, 3))
    base = add(base, glow_layer(size, shots, 16).point(lambda v: v // 2))

    title = font(150)
    def write(d):
        d.text((w * .5, m((0, 1.04))[1]), "AURORA", fill=(255, 255, 255), font=title, anchor="mm")
    base = add(base, glow_layer(size, write, 18).point(lambda v: int(v * .35)))

    # Apron: painted in place.
    ax, ay = m((0, table["apron"]["y"]))
    apron = vgrad((w, h - int(ay)), [(0, (46, 12, 86)), (1, (10, 4, 26))])
    base.paste(apron, (0, int(ay)))
    d = ImageDraw.Draw(base)
    d.line((0, ay + 8, w, ay + 8), fill=(255, 60, 200), width=8)
    base = add(base, glow_layer(size, lambda g: g.line((0, ay + 8, w, ay + 8), fill=(255, 60, 200), width=14), 14))

    atlas = Image.new("RGB", CANVAS, (20, 20, 24))
    atlas.paste(base, (0, 0))
    paint_common_parts(atlas, dict(
        cap_a=(255, 60, 170), cap_b=(120, 10, 150), accent=(60, 220, 255), accent2=(255, 240, 120), accent3=(30, 90, 200),
        plastic_a=(255, 50, 170), plastic_b=(90, 30, 220), wall=(38, 18, 72), rail=(30, 14, 52),
        flipper_a=(240, 240, 255), flipper_b=(255, 255, 255), ramp_a=(70, 40, 170), ramp_b=(30, 110, 220),
        env_top=(30, 12, 70), env_mid=(255, 60, 170), env_low=(50, 10, 70), bezel=(90, 40, 160)))
    return atlas


def paint_classic(table):
    size = (SLOTS["playfield"]["rect"][2], SLOTS["playfield"]["rect"][3])
    w, h = size
    m = Mapper(table)
    base = vgrad(size, [(0, (120, 22, 18)), (.4, (196, 54, 22)), (.75, (230, 150, 40)), (1, (120, 40, 20))])
    d = ImageDraw.Draw(base)

    # 1970s sunburst.
    cx, cy = m((.4775, .72))
    for i in range(36):
        if i % 2:
            continue
        a0, a1 = math.radians(i * 10), math.radians((i + 1) * 10)
        d.polygon([(cx, cy), (cx + 3000 * math.cos(a0), cy + 3000 * math.sin(a0)), (cx + 3000 * math.cos(a1), cy + 3000 * math.sin(a1))], fill=(236, 170, 60))
    base = base.filter(ImageFilter.GaussianBlur(1.2))
    tint = vgrad(size, [(0, (255, 170, 150)), (.5, (255, 240, 210)), (1, (200, 130, 110))])
    base = ImageChops.multiply(base, tint)
    d = ImageDraw.Draw(base)
    for r, color in ((330, (30, 60, 110)), (310, (240, 225, 190)), (290, (170, 30, 26))):
        d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=color)
    rng = random.Random(21)
    for _ in range(60):
        x, y = rng.uniform(0, w), rng.uniform(0, h)
        s = rng.uniform(10, 34)
        if math.hypot(x - cx, y - cy) > 350:
            d.polygon(star_points(x, y, s), fill=rng.choice(((250, 240, 200), (30, 60, 110))))
    d.polygon(star_points(cx, cy, 200), fill=(250, 225, 110))

    ax, ay = m((0, table["apron"]["y"]))
    base.paste(vgrad((w, h - int(ay)), [(0, (240, 230, 205)), (1, (205, 190, 160))]), (0, int(ay)))
    d = ImageDraw.Draw(base)
    d.rectangle((0, ay, w, ay + 16), fill=(170, 30, 26))

    atlas = Image.new("RGB", CANVAS, (20, 20, 24))
    atlas.paste(base, (0, 0))
    paint_common_parts(atlas, dict(
        cap_a=(250, 225, 110), cap_b=(210, 60, 30), accent=(30, 60, 110), accent2=(170, 30, 26), accent3=(16, 30, 60),
        plastic_a=(240, 200, 90), plastic_b=(210, 70, 30), wall=(232, 218, 188), rail=(92, 52, 26),
        flipper_a=(232, 225, 205), flipper_b=(255, 250, 235), ramp_a=(200, 60, 30), ramp_b=(240, 170, 60),
        env_top=(90, 70, 50), env_mid=(250, 210, 150), env_low=(90, 40, 20), bezel=(70, 40, 20)))
    return atlas


NEON_PALETTE = {
    "lamps": {"cyan": [0.2, 0.85, 1.0], "white": [1.0, 0.95, 0.9], "amber": [1.0, 0.65, 0.12], "magenta": [1.0, 0.15, 0.7], "green": [0.2, 1.0, 0.45], "red": [1.0, 0.16, 0.12]},
    "rubber": [0.95, 0.95, 0.98], "metal": [0.82, 0.84, 0.9], "ambient": 1.0, "key": [1.0, 0.94, 0.9], "keyIntensity": 900, "dmd": [1.0, 0.32, 0.72], "plasticOpacity": 0.72,
}
CLASSIC_PALETTE = {
    "lamps": {"cyan": [0.55, 0.85, 1.0], "white": [1.0, 0.9, 0.72], "amber": [1.0, 0.68, 0.2], "magenta": [1.0, 0.3, 0.3], "green": [0.55, 1.0, 0.4], "red": [1.0, 0.2, 0.12]},
    "rubber": [0.97, 0.96, 0.92], "metal": [0.86, 0.84, 0.8], "ambient": 1.15, "key": [1.0, 0.9, 0.76], "keyIntensity": 800, "dmd": [1.0, 0.55, 0.12], "plasticOpacity": 0.85,
}


def install(atlas, name, palette):
    out = RES / "Skins"
    out.mkdir(parents=True, exist_ok=True)
    atlas.convert("RGB").save(out / f"{name}.jpg", quality=88, subsampling=0, optimize=True)
    (out / f"{name}.json").write_text(json.dumps({"id": name, **palette}, indent=2) + "\n")
    print(f"installed {name}: {(out / f'{name}.jpg').stat().st_size // 1024} KB")


def cmd_demo():
    table = load_table("aurora")
    install(paint_neon(table), "neon", NEON_PALETTE)
    install(paint_classic(table), "classic", CLASSIC_PALETTE)


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
