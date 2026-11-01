> **Superseded by [SCENES.md](SCENES.md).** Tables and parts now come from `Scenes/*.xml` with no Blender. The Blender steps below remain for reference until the add-on is removed; the materials and comparison notes still apply.

# Blender hardware kit

Visual target: `Art/Concepts/cadet-inspired-redesign.png`. Space Cadet reference: `Art/Concepts/space-cadet-resource-reference.png`.
Editable level source: `Art/Models/pinball-levels.blend`. See [BLENDER_AUTHORING.md](BLENDER_AUTHORING.md) for the curve modifier and complete playable-level workflow.
Reusable hardware master: `Art/Models/premium-hardware.blend`.
COLLADA sources: `Art/Models/premium/*.dae`. Shipped scenes: `GameData/Models/premium/*.scn`.

iOS SceneKit cannot read COLLADA at runtime, and a missing or unreadable model silently falls back
to procedural geometry. The game therefore only loads compiled `.scn` files.

Kit parts, built to unit radius (or unit half length) and scaled by the table:

- `bumper-base`, `bumper-cap`: a mushroom. A flared foot, a narrow black waist, and a wide cap that overhangs them and throws a shadow, painted at runtime from the skin's `capBase` and `capStar`, with a raised hub holding the jewel in its bore. No lit slots, bolts or thin bands: they break up into pixels at phone size.
- `insert-bezel`, `insert-arrow`: round and triangular bezels with clear lenses over the painted insert. Round bezels have broad raised chamfers, widened inward within the existing footprint.
- `post`, `target`, `flasher-cage`. A target is scaled to its edge's length with a fixed depth matching its collider; stand-ups are about 0.1 long so they read at phone size. Spinners are built in `buildSpinnersAndGates`: two posts, a thick axle and a framed plate spanning their lane.
- `arrow-lens`, `arrow-stack`, `bullet-cyan`, `bullet-amber`, `stud`, `mech-bracket`, `mech-piston`: decor, placed from the table's `decor` list. They are low relief, so a ball can pass over them without looking wrong. Physics ignores them; the layout test does not.

Table-specific parts, built for every JSON in `GameData/Tables`, in table coordinates, so **rebuild them whenever the JSON moves**:

- `<table>-<ramp>`: a brushed aluminum channel loft along the physics spline, with solid coloured outer walls and thin round gold rails 0.008 wide. The interior is 0.088 wide to clear the 0.060-diameter ball. Edited curves export directly as sampled physics paths, with no additional smoothing. The walls carry on past the mouth as a smooth funnel over a brushed gold floor, and the exit ends over a crossbar. Ramps float, with no pillars. The entire exported ramp must stay below 6,000 triangles.
- `mech-stud`, `mech-tower`: standing mechanisms. Give a table's `posts` entry a `model` to draw one, so the ball bounces off it instead of passing through.
- `<table>-flipper`: an ivory bat in a black rubber edge, with a lit inset and brass pivot, in that table's proportions.
- `<table>-walls`: thick pieces rising 0.03 out of the board, with round ends, a gold trim and the skin's wall colour, drawn at their collider's radius so the ball meets what it sees. Walls that meet are one wall with one path, so they merge into a single piece. To thicken one, grow it away from its ball lane by moving its centre line: lanes need about 0.0625 for the ball to pass, and narrower ones become traps.
- `<table>-plastics`: slingshots (rounded blocks with a coloured base and top, a cream band, an inset cream line and three screws) and housings.

Blender is Z-up; the exporter converts to SceneKit's Y-up. Kit parts stay live in `premium-hardware.blend`, each object a line or outline with modifiers rather than a baked mesh:

- Round parts (bumpers, round targets, buttons, studs, lamps, pivots) are a profile line with **Screw** and **Edge Split**. Edit the line's points to reshape the part, and the Screw steps to change its smoothness. Painted caps add the **Pinball Planar UV** nodes.
- Flat parts (target blocks) are an outline with **Bevel** for corners, **Solidify** for height and **Bevel** for the chamfer.
- Frames (triangular lamp bezels) are a closed line with the **Pinball Trim** nodes for width and height.
- Grey rollover bars are the **Pinball Rollover Bar** modifier, pure Geometry Nodes, which adds a bar to whatever object carries it. They are matte and out of the floor's reflection: a flat plate under a MatCap and a mirror image looks blotchy.

Walls and ramps use the Pinball Wall and Pinball Ramp modifiers in the level file. Flipper bodies, slingshot bodies, faceted lenses and housings are still scripted meshes. Objects are not joined: joining applies modifiers. Export groups triangles by material
role, and `PBTableScene` binds `metal`, `accent`, `rubber`, `enamel`, `dark`, `ramp_floor`, `lens`, `glow`,
`glow_amber`, `jewel`, `sling_lens`, `cap_art`, `wall_art`, `block_art`, `flipper_art` and `target_art` to the selected skin.
`Art/Models/manifest.json` records each model's real radius; `PinballCoreTests` checks the overlap test's
footprints still cover them, and that every decor model and ramp used by the table exists.

`modelKit: "premium"` in a skin palette selects these meshes. Skins without a kit keep procedural hardware.

## Reproduce via Blender MCP

The helper uses the installed Blender MCP add-on's local null-delimited JSON bridge, rather than
requiring another SDK. Start a dedicated session (leave an existing interactive Blender file alone):

```bash
/Applications/Blender.app/Contents/MacOS/Blender \
  --background --factory-startup --online-mode --addons bl_ext.user_default.mcp \
  --command blender_mcp --port 9877
```

In another terminal, from the repository root:

```bash
python3 tools/blender_mcp.py tools/build_hardware_models.py
tools/compile_models.sh
```

The script creates its own scene, saves the compressed `.blend` master, exports standard COLLADA,
and writes triangle counts and sizes to `Art/Models/manifest.json`. Its small exporter is included
because this Blender version no longer bundles its legacy COLLADA exporter. No export plugin is needed.
Stop the dedicated bridge with Ctrl-C when done. Started with `--port 9876` instead, the same session
also serves the `blender` MCP tools.

The playfield is full bleed. There is no screen-edge top arch. Both premium background masters have had their graphic overlays removed through ImageGen and now fill the whole source rectangle, so no gold bar or apron crosses the bottom edge.

## Metal

Gold and steel use a MatCap (sphere map) from `GameData/Materials`, rendered in colour by `tools/build_matcap.py` from
Blender's bundled CC0 rooms. A skin picks one for hardware (`materials.matcap`) and one for ramps (`materials.rampMatcap`), and tints them. The shader looks it up by the surface normal, rotated with the room, so highlights slide as
the phone tilts. The material uses Blinn lighting, so local bumper, slingshot and flasher lights illuminate nearby metal and the key light casts shadows. The satin channel floor keeps a broad silver base plus softer moving reflections; only the corners and rail caps are rounded. Molded guide housings use `cabinet_shell`; their inset strips use `guide_glow`.
Nothing thinner than about 0.004 table widths: it is finer than a pixel on a phone, and aliases. Only ramp brackets, slingshots and flippers carry bolts.

## Glow

Glowing parts light what is around them and put a rim on it: bumper jewels, slingshot lenses, lit lamps, ramp arrows and flashers, each with a colour, range and strength that follow its state in `updateGlowWithWorld:`. The 16 brightest go to the shader as one block each frame, as SceneKit lights are too costly for every lamp and have no rim. A material takes part through `receiveGlow:`. The playfield reads them in its surface modifier, because a fragment modifier on `SCNFloor` loses its planar reflection. Constant-lit parts such as jewels and lamp sprites, and painted bumper caps, stay out, so they keep their colour.

## Smooth ramps

`python3 tools/ramp_paths.py` checks every ramp's centre line and rail edges for folds, facets and curvature jumps,
and how far legacy mesh paths stray from the ball's path. Curves exported by Pinball Builder are used directly by both mesh and physics. The mesh build runs the same checks and refuses a ramp that fails.
The channel mesh merges nearly straight rings within 0.00012 table widths at both rail edges, retaining dense samples around bends. The floor remains planar across its width. The builder also checks that the larger ball clears the visible rail walls along the relaxed path. Keep ramp details readable: anything much under 0.004 table widths is finer than a pixel on a phone, and aliases.

## Comparing with the concept

The camera is orthographic and leans 30° toward the player, so walls, flippers and ramp sides show their height (`PBTableCameraTilt`). On a phone this leaves a band above the board's far end, where the art carries on, dimmed, behind the indicators.

In the bridge session, after the build, this lays the kit out on the table in Cycles from the game's camera.
It is for close-ups of geometry; its materials only approximate SceneKit:

```bash
python3 tools/blender_mcp.py --port 9876 --env PB_BOARD_OUT=/tmp/pinball-board tools/render_board_blender.py
```

Judge the look on a real scene render, which takes seconds, with side-by-side crops per board area:

```bash
tools/render_preview.sh /tmp/pinball-game orbital
python3 tools/compare_concept.py /tmp/pinball-game/orbital.png /tmp/pinball-compare orbital
```

Use the standalone `tools/render_preview.sh` to validate imported models, skin crops, bumper
collision → authored hit state → idle, and actual game screenshots. `*-hit.png` previews show the
fixture collision with a real simulated ball. The tool reads `GameData/` directly with no app build.
Physics tests are still run through `PinballCoreTests`.
The preview also exports `*-local-off.png` and `*-local-on.png` with identical geometry, camera and lamp sprites, varying only actual omni lights. Compare hardware pixels to verify coloured illumination, rather than a glow sprite. Actual iPhone GPU performance should be checked on device before shipping.

For motion-lighting QA, the preview tool also exports opposite-tilt PNGs and checks smoothing, tilt
limits, invalid samples, and neutral restoration. Append `--tilt-animation` after the skin name to
export a looping close-up GIF of the actual hardware under a simulated phone tilt:

```bash
tools/render_preview.sh /tmp/pinball-lighting orbital --tilt-animation
```

To inspect the real rounded-square section from an oblique angle, after building in the same bridge:

```bash
python3 tools/blender_mcp.py tools/render_ramp_detail.py
```

This writes `/tmp/pinball-ramp-detail.png` without changing the saved master. Set
`--env PB_RAMP_DETAIL_OUT=<path>` to choose a destination. The design study is
`Art/Concepts/cadet-inspired-redesign.png`; its ImageGen prompt is in `Art/Prompts/cadet-inspired-redesign.txt`.

## Channel finish and lights

The floor is brushed aluminum: `tools/build_brushed.py` paints short streaks along the ramp into `GameData/Materials/brushed-aluminum.png`, which tints the `channel_floor` MatCap. Its normals lean along the path, as brushed metal catches light by the direction of its grain, so the sheen sweeps around a bend and moves with tilt. Rails, brackets, columns and arrow bezels use `accent`, so they follow the skin's gold. Inner walls use `channel_liner` and outer walls `channel_shell`.
Entrance and exit triangle inlays are centered on the curve. Their position, dimensions, direction and optional equal-distance repetition are modifier parameters.

The older ImageGen `ramp-chase.png` atlas remains available for the previous textured-deck style. Current aluminum
channels use small geometric arrow inlays, leaving the metal exposed. The preview's `*-chase.gif` now shows the
actual lamp animation and larger ball fixture on this design; if a textured-deck model is loaded, it also verifies
all four authored chase groups. No authored state image is recolored or synthesized.

## Artwork sources

The built-in ImageGen tool produced the approved concept (`Art/Concepts/cadet-inspired-redesign.png`),
the two cleaned full-height masters (`Art/Masters/orbital-playfield.png` and
`Art/Masters/abyss-playfield.png`), and the complete glow atlas (`Art/Masters/ramp-chase.png`).
Exact prompts are preserved in `Art/Prompts/cadet-inspired-redesign.txt`,
`Art/Prompts/orbital-playfield-clean.txt`, `Art/Prompts/abyss-playfield-clean.txt`,
and `Art/Prompts/ramp-chase.txt`. Background exports are JPEG compression only; the atlas is
shipped unchanged. Final native animations and screenshots are in `Art/Previews/`:
`orbital-chase.gif`, `abyss-chase.gif`, `orbital-gameplay.png`, `abyss-gameplay.png` and
`channel-detail.png` (the actual Blender geometry under studio lighting).

The Space Cadet sheet is retained as a design reference, not shipped as game artwork.
With the 20% larger ball, the table clearances and flipper gap were widened; the docking
mechanism now needs one lock, launch ball save is 12 seconds, and two late-level goals were
rebalanced. The full headless suite verifies every feature remains reachable, no persistent
traps develop, all level goals are achievable, and three stars are not automatic.
