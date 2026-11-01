# Painting a skin with ChatGPT

One skin is one image. Attach `Art/Templates/aurora/layout_for_imagegen.png`, paste the prompt
below with your theme, and ask for a **portrait 2:3** image (1024x1536 or larger).
`layout_annotated.png` is the same layout with labels, for you to read. Don't upload that one:
image models tend to copy text they can see.

Then install the result:

```bash
python3 tools/skin_tool.py ingest ~/Downloads/my_art.png volcano
```

It appears in the game right away: press `S` in the Mac preview, or tap with three fingers on iPhone.

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
