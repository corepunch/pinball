# Pinball Builder

Editable level source: [Models/pinball-levels.blend](Models/pinball-levels.blend).
Installable add-on: [Tools/pinball-builder.zip](Tools/pinball-builder.zip).
Source: `tools/blender_addons/pinball_builder/`.

## Start

Install the ZIP through Blender Preferences → Add-ons → Install from Disk, and enable **Pinball Builder**.
Open `Art/Models/pinball-levels.blend`. Choose either **Level • AURORA** or **Level • MERIDIAN** in the scene selector.
The separate hardware scene is the reusable model library.

The **Pinball** tab in the 3D View sidebar contains table import, element creation, preview refresh and playable export.
Its project folder should point to this repository. Units are normalized: a table is 1 metre wide in Blender.
The source camera matches the game's 18° orthographic view. Some gameplay entities use simple authoring proxies;
the native preview is the final material and lighting reference.

## Draw a channel

Use **Add Parametric Track**, or select a single Bézier/Poly curve and choose **Make Selected Curve a Track**.
Tab into Edit Mode to move points and handles; change Z to raise the track. Keep bends broad enough to fit the channel.
Existing tracks have approximately 10–15 Bézier control points rather than a dense editable mesh.

Select the curve's **Pinball Ramp** modifier:

| Panel | Controls |
| --- | --- |
| Channel | Inside width, wall height, round rail width, floor corner radius, floor thickness |
| Openings | Entrance plate and exit crossbar, flared or lowered entrance/exit walls, transition length, flare amount, cuts at either end, gap in a closed loop |
| Columns | Generate columns, maximum station spacing, shaft/foot radius, bracket length, ground height |
| Arrows | Entrance lamp toggle, distance and size; entrance/exit toggles, reverse exit direction, repeat along the whole path, opening offset, size and spacing |
| Mesh quality | Maximum span, geometric error tolerance and preview triangle budget |

The walls carry on past the mouth as a smooth funnel over its own brushed gold floor. **Funnel length** and **Funnel opening** set its size; **Funnel turn** faces it toward where the ball comes from; **Funnel skew** opens it more on one side when something stands close on the other. The exporter generates its colliders. Keep at least a ball's width, about 0.065, between a funnel and anything beside it, or the gap becomes a trap. The exit ends over a crossbar below the floor, so a ball leaves it freely. A flare takes precedence over lowered walls if both are checked. Cuts are measured along the path; closed curves receive a configurable opening.

The section has a flat brushed aluminum floor, straight inner walls, rounded floor transitions and round gold rails. Defaults are 0.088 inside width, 0.05 wall height, 0.008 rail width, 0.0035 inside radius and 0.002 floor thickness.

Entrance/exit arrows are small illuminated triangle inlays. Their geometric centers lie on the curve, aligned to its
local tangent. **Repeat arrows along path** overrides the end toggles and distributes arrows at equal arc distances.
They follow the floor height rather than floating above sloped sections. Color comes from the selected game skin.

Each ramp also generates its playfield **entrance lamp**: a magenta arrow ahead of the funnel, pointing into the ramp and lit when the ramp is hot. It starts on the curve's axis and swings to the nearest place clear of guide rods and other parts. Its distance and size are modifier parameters, and it follows the curve when you move it. It is exported as a lamp with a `ramp` field; don't place one by hand.

Ramps float by default. **Support columns** turns on brackets, which are spaced evenly and alternate sides. Each one carries a column when one fits there, and a bracket alone when not. Columns stand outboard of the rail, and never under a channel or in a bend too tight for them. Positions that obstruct other hardware or ball-width corridors are skipped, including the launch corridor. The two legs at each end of a raised ramp look along the rail for a place, leaving just a ball's width. Moving obstacles re-evaluates placement.
Column shafts have actual playfield colliders in the exported game.

Importing a table refits its curves, which can sharpen the tightest bends slightly. Edit and export from the saved `.blend`, rather than importing again after each export.

This is a native Geometry Nodes modifier interface backed by the add-on's Python mesh generator, rather than a
pure Geometry Nodes graph. Keep the add-on enabled for live editing. Each curve owns one hidden cached mesh in
its scene's **Pinball • Generated** collection. Supports and arrows are faces in that mesh, not separate objects.
Saved geometry remains visible when the add-on is disabled, but edits require the add-on to regenerate it.

Invalid parameters or a bend that folds its inner wall produce an error in the sidebar. The previous valid mesh
stays visible until corrected. **Rebuild Track** retries explicitly. Export enforces a 6,000-triangle ceiling per
complete track, even if its preview budget was increased.

## Draw a wall

A wall is a line with a **Pinball Wall** modifier, like a ramp. Edit the line's points in Edit Mode, and its **Thickness** and **Height** in the modifier; the thick extruded piece and its gold trim are generated from them, and the same values set the wall's collider. Leave at least 0.0625 for the ball between a wall's face and whatever it shares a lane with, or the lane becomes a trap: grow a wall away from its lane by moving its line. Walls that meet should be one line, so they merge into one piece.

## Grey rollover bars

Every rollover carries a **Pinball Rollover Bar** modifier, with **Half length** and **Half width**. Disable or remove it and the game shows no plate there. It is pure Geometry Nodes, so you can add it to any object from the Geometry Nodes modifier list. Keep a lamp and the plate under it 0.075 apart, so lane columns read the same across the table.

## Configure the complete level

Collections separate walls, posts, bumpers, ramps, flippers, targets, gates, rollovers, saucers, lamps, plastics,
decor and other mechanisms. Select an element to edit its **Gameplay object** values in the Pinball sidebar.

- `pb_id` is its persistent gameplay ID. IDs start with a letter and contain letters, digits, `_` or `-`.
- Move objects to change positions; rotate edge curves to change target/gate alignment. Edit wall/edge curve points to change collision outlines.
- Scale round elements to change radii. Flipper X scale changes length; Y scale changes its end radii. Update the corresponding `game_*` values to set exact dimensions.
- `game_*` properties hold the engine's other settings: kick/eject speed, gate pass direction, magnet hold time, lamp color/icon/binding, wall style/layers, decorative model and mounting height, etc.
- **Add Gameplay Element** copies a preset of the chosen type from this table with a unique ID. Native duplication is also supported; assign a new ID before exporting.
- **Refresh Gameplay Preview** rebuilds visual proxies after changing dimensions or model fields. Moving a shape alone does not require a refresh for its position to export.
- Rule-group objects in **Groups** hold members, linked lamps, actions, completion scores and messages. Lists and dictionaries are JSON strings in their custom properties.
- The **Table • …** object holds table size, skin, physics, ball radius, number of balls, rules, all scores, and `game_campaign`: the campaign entries, goals and star scores belonging to this table.

Rule actions are `bonusX`, `resetGroup`, `lightLock`, `resetDrops`, `armKickback`, `armMagnet`, `addBonus`,
or `flash:<flasher ID>`. Preserve the engine's `orbit`, `inlane` and `outlane` ID prefixes when creating those rollovers.
Delete unused gameplay objects to remove them from a level; viewport/render hiding alone keeps their gameplay data.
Renaming an ID requires updating its rule references and the skill-shot target. Export checks these references.

To start another table, duplicate a level scene using **Full Copy**, change the Table object's `pb_id` and name,
assign new IDs to its `game_campaign` entries (or set that array to `[]` for a default first level), then Refresh Preview.
Campaign IDs belonging to another table are rejected instead of replacing that table's entries.

## Export and play

Save the `.blend`, set the project directory in the Pinball sidebar and click **Export Playable**.
This project targets macOS/iOS, so native export requires the local Blender and Xcode tools already used by the game.

The exporter derives the ball path and centered entrance mouth directly from the edited curve. The game uses those
samples without smoothing them into a different path. The table JSON includes the modifier settings and generated
column collision positions. There is no second hand-authored ramp path to synchronize.

Before replacing game files, export stages and checks:

1. Unique object/group/campaign IDs, valid rule/skill-shot/flasher references, finite dimensions and ball clearance.
2. The engine's projected layout checks for overlaps, narrow gaps and bounds.
3. Full-power launch into the upper table, followed by 40 simulated minutes of autoplay: finite physics, scoring,
   every ramp completed, every rollover and stand-up reached, and the table's other gameplay mechanisms exercised.
4. Channel mesh quality and triangle budgets, COLLADA export and native SceneKit compilation.

Only after these succeed are `GameData/Tables`, this table's `GameData/Levels.json` entries, the hardware manifest,
model sources and compiled game models replaced. The editable source file remains the authoring source.
The export does not install an app on the phone. Build/run normally, or use `make iphone-deploy` when ready.

For verification from the repository root:

```sh
make test
# No signing required for a build check:
xcodebuild -project Pinball.xcodeproj -scheme Pinball -configuration Debug \
  -destination generic/platform=iOS -derivedDataPath Build CODE_SIGNING_ALLOWED=NO build
# Render the actual game, reading the exported GameData directly:
PB_PREVIEW_TABLE=meridian tools/render_preview.sh /tmp/pinball-preview abyss
```

## Reproduce the source and package

The add-on has no downloaded dependencies. The source files and packed `.blend` masters are small.
Through the dedicated Blender MCP bridge described in `MODEL_GUIDE.md`:

```sh
python3 tools/blender_mcp.py tools/build_hardware_models.py
python3 tools/blender_mcp.py tools/build_blender_levels.py
python3 tools/package_blender_addon.py
```

For the add-on integration checks, including save/load, both complete gameplay round trips, live modifier inputs,
centered arrows, generated mesh output and repeated rebuilds without object growth:

```sh
/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
  --python-exit-code 1 --python tools/test_blender_builder.py
```
