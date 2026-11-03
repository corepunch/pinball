# Code shapes → compact PNG atlases

The current schematic art is deliberately editable geometry. `Scenes/*.xml` owns hardware
dimensions; `App/UI/PBTableSprites.m` owns the flat paths, colours and baked shading. The game
continues to rasterize those shapes at table load, so changing a collider changes its artwork.

Export the same shipping artwork, without a GPU, simulator, downloads or a device build:

```sh
make sprites TABLE=aurora
make sprites TABLE=meridian
make sprites TABLE=tide
# Optional destination; generated files there are replaced.
make sprites TABLE=tide SPRITE_OUT=/tmp/tide-sprites
```

Each export writes `sprites.png` and `sprites.json` under `Art/Sprites/<table>/`. The PNG is one
transparent rectangular atlas containing complete assemblies: a bumper includes its rings, and
a flipper includes its hinge detail. The long shooter divider remains one intact image, suitable
for a future themed treatment such as a candy cane. Other sprites pack alongside it.

Packing trims fully transparent pixels, deduplicates byte-identical images, then searches rectangular
MaxRects layouts with two transparent pixels around each image. It adds no square or power-of-two
padding, rotates no artwork and changes no resolution: **1200 pixels per table unit**, matching the
live rasterizer. Repeated bumpers, lamps and flippers can share rectangles while keeping independent
placements. Occupancy in the manifest includes the protective gutters and counts unique images.

`sprites.json` records each part's ID, atlas rectangle, local bounds, pivot, table position, rotation,
scale, alpha and visibility at the initial game state. Atlas rectangles and pivots use top-left
pixels; local bounds/positions use table units with y up; rotations use radians. Pivots can sit
outside a cropped image, especially for paths authored in absolute table coordinates. To rebuild
a node, crop its rectangle, use `localBounds[2:4]` as its size, and set its normalized anchor to
`(-localBounds[0]/width, -localBounds[1]/height)`, then apply the recorded transform. Deduplicated
entries deliberately reference the same rectangle. The solid-colour floor is excluded.

These are full-opacity source shapes, with live state kept separate: lamp brightness, target
drop state, gate angle, spinner scale and contact-driven ball strain still come from production
physics/rules. This export does not invent painted interaction states. Authored icon sets and their
states must still follow the single-atlas artwork rule in [AGENTS.md](../AGENTS.md).

For future skins, copy an exported sheet and manifest to a persistent art-master location before
painting. Preserve each silhouette, crop and pivot. Re-export after geometry changes and reconcile
the painted master; do not overwrite an irreplaceable painted source with generated output. These
PNGs are authoring deliverables; runtime loading of painted replacement atlases is a separate step.

The exporter validates non-overlapping allocations and exact pixel recovery for every atlas crop,
including aliases. `make ui-check` runs these checks for all three tables without writing captures.
For assembled board evidence, use `PB_PREVIEW_TABLE=tide zsh tools/render_ui_preview.sh - /tmp/tide-ui`;
that is a software capture of the actual SpriteKit graph.
