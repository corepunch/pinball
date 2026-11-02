# Skin artwork and materials

## Orbital and Abyss

Four art directions were explored in `Art/Concepts/premium-directions.png`. Orbital was selected for
its Space Cadet-inspired navy/ivory/vermilion space illustration; Abyss for its distinct petrol/brass
deep-sea illustration. The images are original artwork generated with the **built-in ImageGen tool**.
Exact prompts are preserved in `Art/Prompts/`, and lossless source PNGs in `Art/Masters/`.

Each set has a separate tall playfield painting and a compact hardware atlas. The atlas contains both
authored bumper states, plastics, trim, flipper surface, ramp, target faces, reflection environment,
all sixteen lamp glyphs, display bezel, and fine grain. All hardware and glyphs for a set were generated
together in one ImageGen call. The idle/hit bumper images are used directly; no state art is synthesized
or recoloured. Lamp glyphs act as masks for simulated lamp illumination.

Runtime artwork lives in `GameData/Skins/{orbital,abyss}{,-playfield}.jpg`, about 1.5 MB per set.
The matching JSON defines the palette, material values, and `atlasLayout`. Coordinates are measured
against the actual authored PNGs, including small deviations from the nominal regular grid.
`canvas` declares the atlas coordinate system; each slot has a `rect` and optional `bleed`. Slots may
declare their own `file` and `canvas`, which is how separate playfield sources work. The playfield art
fills the table's height and keeps its proportions, so its sides run off the phone's edges.
The `inserts` slot is a 4×4 glyph sheet with optional `cellBleed` to exclude its dividers.

Material controls under `materials` are `metalness`, `roughness`, `playfieldReflectivity`, `bloom`,
`rampOpacity` and `rampGlass` (the ramp's tint; opacity 1 is solid sheet metal). All metal is a tinted MatCap: `matcap` and `rampMatcap` name them (`courtyard`, `studio`, `sunrise`). `rampBlur` (a mip bias) and `rampGloss` (0 to 1) set how satin the channel looks. `capBase` and `capStar` paint the bumper caps. Palette
`shell` is the cabinet's and the walls' colour. `accent` controls decorative metal; `slingLens` the lit sling and arrow lenses; `flipperRubber` the bat
sleeves of skins with no model kit.
Printed enamel uses a restrained clear coat; metal rims, skirts, rails, and fasteners provide physical
reflections. `modelKit: "premium"` selects the compiled domed bumper, insert socket, and ramp
channel meshes; see [MODEL_GUIDE.md](MODEL_GUIDE.md). New decorative meshes do not alter collision
geometry or scoring.

To regenerate the compressed runtime JPEGs from the preserved masters, run:

```bash
tools/export_premium_art.sh
```

To validate every skin source and atlas crop and render real SceneKit previews (requires macOS with
Metal GPU access, no app build required):

```bash
tools/render_preview.sh "$PWD/Art/Previews" orbital
tools/render_preview.sh "$PWD/Art/Previews" abyss
```

Omit the last argument to render all skins. These are actual game scene renders, not concept mockups.
Run `-PBSkin orbital` or `-PBSkin abyss` to choose a set directly in the iPhone app, or
tap with three fingers to cycle. Orbital is Aurora's default; saved skin preferences persist.

## Classic and Neon

These have the same structure, painted by code instead of ImageGen. `python3 tools/skin_tool.py demo` writes
their JSON, `GameData/Skins/{classic,neon}{,-playfield}.jpg`, and nothing else: edit `PREMIUM_SKINS` and the two
`paint_*_playfield` functions there, not the output. Each hardware atlas is Orbital's master with its reds and
navy moved to another hue, so gold and cream stay. A playfield holds scenery only, dim, with no shapes of parts:
the board draws those on top. `shell` in the palette colours the walls and the outsides of the ramps.

## Painting a legacy single-atlas skin with ChatGPT

One skin is one image. Attach `Art/Templates/aurora/layout_for_imagegen.png`, paste the prompt
below with your theme, and ask for a **portrait 2:3** image (1024x1536 or larger).
`layout_annotated.png` is the same layout with labels, for you to read. Don't upload that one:
image models tend to copy text they can see.

Then install the result:

```bash
python3 tools/skin_tool.py ingest ~/Downloads/my_art.png volcano
```

It appears in the game right away: tap with three fingers on iPhone to cycle skins.

## The prompt

> Use the attached image as an exact layout guide and paint over it. Keep every region in the same
> position and size. It is a texture atlas for a top-down pinball game, so this is flat game art
> seen from straight above, with no perspective, no 3D cabinet and no pinball machine around it.
>
> Theme: **[YOUR THEME HERE]**. Rich colour, high contrast, airbrushed pinball playfield art.
>
> Left two-thirds (the tall panel): one continuous playfield painting, edge to edge, that fills the
> whole panel. Keep it mostly dark to mid-tone so that lights stand out. Paint scenery and
> characters freely, but ignore the grey lines, circles and shapes: the game draws walls, lights
> and parts on top, so don't paint them. The bottom band is a separate flat panel in the same style.
>
> Right column, one separate item per box, filling its box completely with no gaps or frames:
> - Round box: top view of a pop bumper cap with a bold central emblem.
> - Triangle box: glossy plastic art.
> - Two squares below it: seamless, tileable, subtle textures (dark trim material, then cabinet wood or metal).
> - Wide capsule box: a pale flipper bat seen from above, simple stripe, no text.
> - Tall box: repeating chevrons pointing up, for a ramp. Seamless top to bottom.
> - Square beside it: glossy plastic art.
> - Four small squares: bold simple target faces.
> - Wide box: an abstract view of a bright room, with a dark floor and bright ceiling lights near the top, for chrome reflections.
> - 4x4 grid: pure white icons on pure black, in order: chevron, star, "2X", "3X", "5X", diamond,
>   lightning bolt, up arrow, dot, ring, bar, hexagon, shield, crown, gem, sunburst. One centred icon per cell.
> - Wide box with a dark rectangle: a decorative frame, with the rectangle left solid black.
> - Square below it: seamless fine grain in neutral mid-grey, almost featureless.
>
> Leave out all labels and guide lines, and add no text except the 2X, 3X and 5X icons.

## Themes to try

- **Volcano:** molten lava rivers cracking through black basalt, ember sparks, a dragon coiled around the top.
- **Deep sea:** bioluminescent abyss, giant squid, shipwreck, shafts of teal light.
- **Haunted:** moonlit gothic mansion, purple fog, ravens, jack-o-lanterns.
- **Space race:** 1960s retro-futurist rockets, chrome and orange, a ringed planet at the top.
- **Tokyo night:** rain-slick neon streets, kanji-style shapes with no real text, koi, lanterns.
- **Wild West:** dusty sunset, saloon, wanted-poster textures, tooled leather and brass.

## If the result is off

- **Parts landed slightly out of place:** this is fine up to a few percent. Slots are sampled with a
  margin, and the art never has to line up with lamps or walls, because the game draws those on top.
- **Labels or guide lines were copied:** reply "same image, remove all lines and text".
- **Too bright:** reply "same image, darken the playfield by 40%, keep the parts as they are".
- **Wrong aspect ratio:** ingest centre-crops to fit and warns you, which can shift the parts. Ask again for 2:3.
- **Palette:** `GameData/Skins/<name>.json` holds lamp, display and light colours. Ingest writes a
  sensible starting point, which you can edit by hand.
