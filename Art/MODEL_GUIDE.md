# Blender hardware kit

Visual target: `Art/Concepts/premium-directions.png`.
Editable master: `Art/Models/premium-hardware.blend`.
COLLADA sources: `Art/Models/premium/*.dae`. Shipped scenes: `GameData/Models/premium/*.scn`.

iOS SceneKit cannot read COLLADA at runtime, and a missing or unreadable model silently falls back
to procedural geometry. The game therefore only loads compiled `.scn` files.

Kit parts, built to unit radius (or unit half length) and scaled by the table:

- `bumper-base`, `bumper-cap`: stepped flange, cushion, a ring of lit jewels around the cap, enamel crown and raised jewel.
- `insert-bezel`, `insert-arrow`: round and triangular bezels with clear lenses over the painted insert.
- `post`, `flipper`, `target`, `flasher-cage`.
- `gear`, `medallion`, `piston`, `bracket`: decor, placed from the table's `decor` list.

Table-specific parts, in table coordinates, so **rebuild them whenever the JSON moves**:

- `<table>-<ramp>`: clear channel on the physics spline, rolled rims, bolted clamps, end flanges and supports.
- `<table>-walls`: guide plates with enamel inlay and rivets.
- `<table>-plastics`: art plates, housings, frames and standoffs.
- `<table>-dmd`: the display frame.

Blender is Z-up; the exporter converts to SceneKit's Y-up. Each asset is merged to one mesh per material
role, and `PBTableScene` binds `metal`, `accent`, `rubber`, `dark`, `glass`, `lens`, `glow`, `cap_art`,
`wall_art`, `plastic_art`, `block_art`, `flipper_art`, `target_art` and `flipper_rubber` to the selected skin.
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
