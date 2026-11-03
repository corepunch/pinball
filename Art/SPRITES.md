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

The export needs macOS. On a pull request from this repository, the `Sprite atlases` workflow runs
`make ui-check`, exports all three tables and commits any changed atlases back to the branch.

Each export writes `sprites.png` and `sprites.json` under `Art/Sprites/<table>/`. The PNG is one
transparent rectangular atlas containing complete assemblies: a bumper includes its rings, a
flipper its hinge detail, and a slingshot its rounded body and corner bolts. Every
collider-backed shape is the collider's own outline: a wall is its points swept by its radius
(closed walls include their inside), so corners are rounded exactly where the ball meets them, and
each slingshot bolt sits on the centre of a corner arc. Arrow lamps keep their faces with rounded
corners. The long shooter divider remains one intact image, suitable for a future themed treatment
such as a candy cane.

Packing trims fully transparent pixels, deduplicates byte-identical images, then packs each image by
its own outline rather than its bounding box: per pixel row, its opaque extent. Small parts settle
into the hollows of triangles, aprons and guides, and any image may be stored in one of four
quarter turns. At least two clear pixels separate any two outlines. Canvas widths are searched for
the smallest rectangle; there is no square or power-of-two padding, no splitting and no scaling:
**1200 pixels per table unit**, matching the live rasterizer. Repeated bumpers, lamps and flippers
share one placement. `opaqueCoverage` in the manifest is opaque pixels over canvas area.

Because outlines nest, bounding boxes overlap: **draw each sprite with its mesh, never by cropping
its rect.** Each `mesh` is a strip of trapezoids, two triangles each, following the outline within
one pixel. `mesh.positions` are source-image pixels (top-left, y down, the image as drawn on the
table) and `mesh.uvs` the matching atlas pixels (top-left). `atlasRotation` gives the degrees the
image is stored turned anticlockwise; `rect` is the stored image's atlas bounding box. To rebuild a
node, draw the mesh triangles with those positions and UVs, use `localBounds[2:4]` as the size of
the source image, set its normalized anchor to `(-localBounds[0]/width, -localBounds[1]/height)`,
then apply the recorded transform.

`sprites.json` also records each part's ID, local bounds, pivot, table position, rotation, scale,
alpha and visibility at the initial game state. Pivots use source-image pixels; local
bounds/positions use table units with y up; rotations use radians. Pivots can sit outside the
image, especially for paths authored in absolute table coordinates. Deduplicated entries
deliberately share a placement and mesh. The solid-colour floor is excluded.

These are full-opacity source shapes, with live state kept separate: lamp brightness, target
drop state, gate angle, spinner scale and contact-driven ball strain still come from production
physics/rules. This export does not invent painted interaction states. Authored icon sets and their
states must still follow the single-atlas artwork rule in [AGENTS.md](../AGENTS.md).

For future skins, copy an exported sheet and manifest to a persistent art-master location before
painting. Preserve each silhouette, crop and pivot. Re-export after geometry changes and reconcile
the painted master; do not overwrite an irreplaceable painted source with generated output. These
PNGs are authoring deliverables; runtime loading of painted replacement atlases is a separate step.

The exporter validates that outlines and gutters never overlap, that every mesh covers all of its
image's pixels and no neighbour's, and that the recorded turn recovers every source pixel exactly. `make ui-check` runs these checks for all three tables without writing captures.
For assembled board evidence, use `PB_PREVIEW_TABLE=tide zsh tools/render_ui_preview.sh - /tmp/tide-ui`;
that is a software capture of the actual SpriteKit graph.
