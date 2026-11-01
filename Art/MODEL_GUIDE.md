# Blender hardware kit

Visual target: `Art/References/premium-pinball-target.png` (the user's selected reference).
Editable master: `Art/Models/premium-hardware.blend`.
Game meshes: `GameData/Models/premium/*.dae`.

These models were created through Blender 5.2.2 LTS's installed MCP add-on, in an isolated background
session. No modeling dependencies, remote models, or large caches were downloaded. The master packs
the original Orbital atlas so it stays editable without external image paths.

The kit contains:

- `bumper-base`: bevelled foot, rubber cushion, recessed actuator, twenty collar flutes and rolled lip.
- `bumper-cap`: curved enamel crown, concentric machined rings, jewel bezel and actual raised jewel.
- `insert-bezel`: recessed dark socket, thin decorative bezel and inner lens retainer.
- `aurora-ramp`: folded U-channel, rolled edges, narrow enamel navigation strip and flange rivets.

The bumper/insert assets have unit radius and are scaled to each table element. The ramp uses the
table's exact Catmull–Rom sampling (six subdivisions per authored segment) in metres. Blender is Z-up;
the exporter converts positions and smooth normals to SceneKit's Y-up coordinates. UVs and material
names survive export. `PBModelLibrary` clones geometry for each instance, and `PBTableScene` maps
`metal`, `channel`, `accent`, `rubber`, `dark`, `cap_art`, and `ramp_art` to the selected skin's materials.
Both cap artwork states are selected directly from the atlas, including on the modeled jewel.

`modelKit: "premium"` in a skin palette selects these meshes. Missing assets fall back to procedural
geometry; skins without a kit keep procedural hardware. Table-specific ramps are named
`<table-id>-<ramp-id>.dae`. If a ramp path changes, regenerate its mesh before shipping.

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
```

The script creates its own scene, saves the compressed `.blend` master, exports standard COLLADA,
and writes triangle counts and sizes to `Art/Models/manifest.json`. Its small exporter is included
because this Blender version no longer bundles its legacy COLLADA exporter. No export plugin is needed.
Stop the dedicated bridge with Ctrl-C when done.

Build the Mac target and use `tools/render_preview.sh` to validate imported models, skin crops, bumper
collision → authored hit state → idle, and actual game screenshots. `*-hit.png` previews show the
fixture collision with a real simulated ball. Physics tests are still run through `PinballCoreTests`.
Actual iPhone GPU performance should be checked on device before shipping.

For motion-lighting QA, the preview tool also exports opposite-tilt PNGs and checks smoothing, tilt
limits, invalid samples, and neutral restoration. Append `--tilt-animation` after the skin name to
export a looping close-up GIF of the actual hardware under a simulated phone tilt:

```bash
tools/render_preview.sh "$PWD/Build/Products/Debug/Pinball.app" /tmp/pinball-lighting orbital --tilt-animation
```
