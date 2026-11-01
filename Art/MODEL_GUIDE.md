# Blender hardware kit

Visual target: `Art/Concepts/premium-directions.png`.
Editable master: `Art/Models/premium-hardware.blend`.
COLLADA sources: `Art/Models/premium/*.dae`. Shipped scenes: `GameData/Models/premium/*.scn`.

iOS SceneKit cannot read COLLADA at runtime, and a missing or unreadable model silently falls back
to procedural geometry. The game therefore only loads compiled `.scn` files.

Kit parts, built to unit radius (or unit half length) and scaled by the table:

- `bumper-base`, `bumper-cap`: bolted base flange, brass skirt with lit slots, black rubber ring, a cap painted at runtime from the skin's `capBase` and `capStar`, bolted collar and glass jewel.
- `insert-bezel`, `insert-arrow`: round and triangular bezels with clear lenses over the painted insert.
- `post`, `target`, `flasher-cage`.
- `arrow-lens`, `arrow-stack`, `bullet-cyan`, `bullet-amber`, `stud`, `mech-bracket`, `mech-piston`: decor, placed from the table's `decor` list. They are low relief, so a ball can pass over them without looking wrong. Physics ignores them; the layout test does not.

Table-specific parts, built for every JSON in `GameData/Tables`, in table coordinates, so **rebuild them whenever the JSON moves**:

- `<table>-<ramp>`: channel floor on the physics spline, broad brass side rails, a retaining rail on standoffs, clamps and mounting brackets.
- `mech-stud`, `mech-tower`: standing mechanisms. Give a table's `posts` entry a `model` to draw one, so the ball bounces off it instead of passing through.
- `<table>-flipper`: an ivory bat in a black rubber edge, with a lit inset and brass pivot, in that table's proportions.
- `<table>-walls`: thin polished guide lines, and the kite guards and foot rails under the inlanes.
- `<table>-plastics`: slingshots (black bands between three brass posts, around a lit panel) and housings.

Blender is Z-up; the exporter converts to SceneKit's Y-up. Each asset is merged to one mesh per material
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

The top rail is not a mesh. `PBTableScene` draws it at runtime along the screen's rounded top corners,
so it fits each phone: UIKit has no public corner radius, so `PBGameController` looks it up by screen size.

## Metal

All metal is one MatCap (sphere map), `GameData/Materials/matcap-metal.png`, painted by `tools/build_matcap.py`
and tinted per skin. The shader looks it up by the surface normal, rotated with the room, so highlights slide as
the phone tilts. It has no lights of its own, so give metal curved sections: a flat part shows one flat tone.
Walls and frames stay thin, with no fasteners. Only parts whose design shows them carry small bolts: bumpers, ramps, slingshots, flippers.

## Comparing with the concept

The camera is orthographic and leans 18° toward the player, as the concept is drawn (`PBTableCameraTilt`).

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
Actual iPhone GPU performance should be checked on device before shipping.

For motion-lighting QA, the preview tool also exports opposite-tilt PNGs and checks smoothing, tilt
limits, invalid samples, and neutral restoration. Append `--tilt-animation` after the skin name to
export a looping close-up GIF of the actual hardware under a simulated phone tilt:

```bash
tools/render_preview.sh /tmp/pinball-lighting orbital --tilt-animation
```
