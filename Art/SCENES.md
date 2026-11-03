# Scenes

The board is text. `Scenes/` is the source, and nothing else is edited by hand:

```sh
make scenes    # Needs Python and Xcode's scntool.
```

| Source | Becomes |
| --- | --- |
| `Scenes/tables/*.xml` | One table each: `GameData/Tables/*.json`, plus its own walls and plastics |
| `Scenes/base.xml` | What every table must have: flippers, slingshots, steel inlane guides and outlanes with their lamps, floors, plunger, the reference rounded display boundary, scores. One shared model each |
| `Scenes/ramps.xml` | Ramp kits, with the walls that go with them. Optional ramp kits, selected with `kits="longL longR"` |
| `Scenes/kit.xml` | Every reusable part |

The table's legacy `padding="x y"` remains in source data. Runtime framing now uses `PBTablePresentation` to fit the complete board under the safe-area-aware HUD with minimal side margins. Scenery extends to the display edge. The invisible outer collider adapts to the viewport through `PBTableDisplayBoundary`; it has no Dynamic Island obstacle. `PBGameHUD` draws the dark drain well without a decorative contour. There is no 3D cabinet.

`GameData/Tables`, `Art/Models/premium/*.dae` and `GameData/Models/premium/*.scn` are compiled output. Skins, and `GameData/Levels.json` (the campaign), are edited directly; `make playtest PLAYTEST=--tune` sets a level's goal and stars.

A table only says what differs from the base. It can add elements, and replace one by giving its id, but `make test` fails if it changes a base part. Change the base to change every level.

## Parts are shapes with modifiers

There are no model files. A part is a `<prefab>` in the style of scener's scene files: shapes, with modifiers nested inside them that run in order.

```xml
<prefab id="button">
  <let name="R" value="1"/>
  <circle radius="{R}" role="accent"><extrude amount=".2"/><bevel amount=".02"/></circle>
  <lathe role="metal" segments="24" points="{R*.8},.2 .2,.3 .001,.32"/>
</prefab>
```

Any attribute can hold `{expressions}`: arithmetic, `pi`, `cos`, `sin`, `sqrt`, `radians`, `min`, `max`, and variables from `<let>` or the caller.

| Shapes | |
| --- | --- |
| `<rect size>`, `<rounded-rect size radius>`, `<circle radius segments>`, `<polygon points>` | Outlines |
| `<capsule base tip length>` | A tapered bar, as flippers are |
| `<arrowhead radius narrow corner>` | A rounded triangle with a direction |
| `<lathe points segments planar at>` | A (radius, height) profile turned upright; `planar` maps art from above |
| `<torus major minor z>`, `<polyline points>` | A ring; a line to sweep along |

All shapes take `role`, `sharp` (crease angle), `z`, `at`, `scale`, `mirror`, and `uv="u0 v0 u1 v1"`.

| Modifiers | |
| --- | --- |
| `<extrude amount>`, `<bevel amount>` | Height and a chamfered top edge |
| `<fillet radius>`, `<inset amount exact="true">` | Round the corners; move the outline in. `exact` preserves full miters so inset fillets remain concentric; omitted, long miters are limited |
| `<sweep section>` | Run a (offset, height) section round the outline |
| `<dome rings apex>` | A moulded lens over the outline |

Also `<use prefab="…" at="x,y" name="value"…>` places a prefab with its variables set, and `<each-corner points inset>` repeats its contents at each corner. A `role` is a surface the game binds to the skin's material; see `skinModel` in `PBTableScene.m`.

## Scripts

Flashers and other effects are not built in: a table's `<rules><script>` says what happens on a cue, with the same actions a group has.

```xml
<script>
 <on cue="ramp" actions="flash:flashTR" />
 <on cue="jackpot" actions="flash:flashTL flash:flashTR" />
</script>
```

Cues: `bumper`, `sling`, `drop`, `standup`, `saucer`, `spinner`, `ramp`, `lock`, `launch`, `drain`, and the fanfares `start`, `ballSave`, `multiball`, `jackpot`, `extraBall`, `wizard`, `tilt`, `gameOver`. A table without a script, or without flashers, simply does nothing extra.

## Tables

A table is its layout and rules. A plastic wall can name its kit prefab with `part`, as the floors under the flippers do. A rail with `closed="true"` is a steel plate whose `points` are its outline, grown by `radius`, which is also what the ball hits; its first edge carries the three screws, as the inlane guides do. Ramps are a line (`points`, in table units with height) and `<authoring>` settings: width, walls, funnel, arrows. Funnel colliders, entrance lamps and ramp mouths are generated from them, so they are not in the XML. Keep lane clearance wider than the 0.06834 ball diameter, or it becomes a trap.

### Layout rules

Judge a layout as the player sees it: through the 20-degree tilted orthographic camera, on a phone, where a raised part appears higher up the screen than its coordinates say.

- **Leave 5 points of clear board between parts** (0.0127 of the table's width). `make spacing` measures this; closer than that reads as touching.
- **Mirror only the lower kit.** Flippers, slingshots, inlanes, outlanes, their lamps and floors mirror around x = 0.457, derived from the current flipper pivots by tooling. Above the slingshots, a table should differ left to right, usually with one big feature taking over a side. `Art/TABLE_LAYOUT_GUIDE.md` covers historical research for the upper board.
- **The axis is the middle of the play area,** from the left wall to the shooter lane, so both outlanes come out the same width with no filler. `make spacing` compares the outlanes and each lower part with its twin (`MIRRORED`, `MIRRORED_LANES`).
- **A part that meets the screen's edge runs past it,** so its trim is off screen rather than drawn along the edge.
- **Parallel lines share a named angle.** `<angles>` in `Scenes/base.xml` holds them: `slope` for the flippers, inlanes, slingshot bases and floors, and `guide` for the orbit guides. Write such a line as a point then `dir(rotation,length)`, as in `0.123,0.2243 dir(-slope,0.14013)`, its mirror image as `dir(180+slope,...)`, a gate as `a`, `rotation`, `length`, and a flipper as `restAngle="-slope"`. Rotations are degrees anticlockwise from +x. Changing the number turns every line that uses it, though you may need to adjust lengths where lines must meet. `make spacing` fails when a line drifts off its angle (`MATCHED_ANGLES`).
- **Ramps are optional and currently deferred for shipped levels.** First Light stays on one plane. The current ramp solver only applies side rails to balls already on that ramp; it does not provide a solid, height-aware underside or block lateral entry through low sections. Before reintroducing a ramp, verify the mouth, side impacts, and every proposed underpass with the full ball diameter and actual renders. Retain the engine and kits for fixtures and future work. If requested later, use at most one aluminum ramp to keep the field readable.
- **The second level.** `<deck height="...">` sets its height, and a `plastic` wall with `part="deck"` is its raised block, solid to balls on the board. A ramp reaches it with `exitLayer="deck"`, and parts on it say `layers="deck"`: walls, stand-ups, a flipper, a hole. Keep it to about a quarter of the table's width at the back or side, and always give it a hole as the way down.
- **Drop holes.** A saucer with `comesUpAt="x y"` swallows the ball, and after `transitSeconds` brings it up there, moving along `ejectDirection`.
- **Check shots with `make shots`.** It fires real flipper shots on this Mac in seconds, and fails if no flipper reaches a ramp, hole or orbit. Use `--fan` through `tools/playtest/run_shots.py` to see each shot's heading, so parts can go on real shot lines.
- **Walls are planks**: plain sides and top in the skin's shell colour, with a small chamfer and no trim, and so are the housings, the deck and the captive pod. A `style="rubber"` wall is a black rubber band. One under 0.0075 radius is solid metal instead, too thin for a plank top (`THIN_WALL`). The shooter lane's wall is 0.008: a 1 cm plank.
- **Inlane guides are `style="rail"`:** two thin plates at half/full height on three hollow screw tubes, running down the flipper's slope and ending in an arc concentric with its pivot. Preserve the outer plan, collision outline and clear widths; leave the space between plates open so they cast separate shadows. `guide-plate`/`guide-tube` author the construction; `guide-cover`, `guide-fastener-band` and `guide-socket` author its colour layers. Keep the wrap short enough that a ball falling behind the flipper still rolls down the apron: the physics tests check it.
- **The ball can always get under the flippers.** Below them the board stays open, and a low floor each side (`apronL`, `apronR`) slopes to the drain between them, so a ball falling behind rolls under and out. Their slope matches the flippers' at rest: any shallower and the ball wedges under a flipper's tip. Don't block this space.
- **Centred parts sit on x = 0.457,** left of the screen's centre (0.5), because the shooter lane takes up the right side.
- **Equal clear lane widths.** Both inlanes and both outlanes have 0.08125 clear width at their straight entries (measured at y = 0.43), about 1.19 times the 0.06834 ball diameter. Measure between physical faces, including rail and backing-wall radii. The source display contour matches the runtime reference phone so the left screen edge is measured correctly.
- **Upper re-entry lanes use the same straight clearance target.** A pair of parallel separators of radius 0.0105 needs 0.10225 between centrelines to leave 0.08125 clear. Bends and entry mouths can flare wider to avoid clipping or pinching. Aurora uses this clear width between its two short internal dividers; its outer lane mouths open onto the field. Historical fixture dimensions are not the template for new geometry.
- **Fit lamps to their lanes.** Centre each lamp and rollover bar between the clear faces. Lower lane lamps have `size="0.017"` and sit above the wall ends rather than beside them; tests enforce their centring.
- **Arrows belong to a part.** Give a spinner, scoop, target, bumper, post or kickback `arrow="<colour>"` and the compiler puts an arrow lamp under it, centred on it and pointing at it, a fixed gap below its footprint; `arrowBind` lights it from the rules as a lamp's `bind` does. Never place an arrow by hand next to a part: it drifts when the part moves.
- **Rollover bars belong to a lamp.** Give the lamp `bar="<rollover id>"` and the rollover only its `id` and `r`. The compiler puts the bar and its switch directly below the lamp, always the same distance away (`BAR_BELOW_LAMP`), so moving the lamp moves both. Never position a bar by hand.
- **Change a ramp's shape smoothly.** The compiler rejects sudden changes in a ramp's curve, so blend a move over many points.
- **A rollover is a wheel in a flat frame** (`<wheel>` in the kit: radius, width, height, on an axle along x). **Stand-up targets lie flat,** like the lamps. Targets stay dark until hit, as an unlit lamp does.
- **Moving a part can trap the ball or block a shot.** Spacing alone doesn't show this, so always run `make test` afterwards. Moving the drop bank towards the captive pod opened a trap that only the tests caught.

### Popups

Every screen but the game itself is a popup. `PBGameUI` says when one appears or goes through `popupHandler`, and `PBGameController` blurs what's behind it with `PBBackdropBlur`, so a new screen gets the blur with no extra work. Don't add a blur or a heavy scrim to a screen.

### Level parts

The kits: `shortL`, `longL` on the left, `shortR`, `longR` on the right. Use a matching pair unless there's a reason not to.

| Feature | In a table |
| --- | --- |
| Third flipper | `<flipper>` with the same length; keep it clear of ramp walls, as the ball can wedge beside its base |
| Vari-target | `vari="true"` on a `<standup>`: scores up to five times as much by how hard it's hit |
| Centre post | `<stopper>` between the flippers, raised by the `armStopper` action for 20 seconds |
| Group `actions` | `playfieldX` (2X for 20 seconds), `lightMystery` (next scoop gives a surprise), `hurryUp` (next ramp or scoop collects a falling value), `holdBonus`, `armStopper`, `armKickback`, `armMagnet`, `lightLock` |
| Wizard mode | `wizard="true"` on `<rules>`: finishing every bank of targets in a game starts multiball at 3X |
| Lamps | `bind` to `playfieldX`, `mystery`, `hurryUp`, `stopper` or `bonusHeld` to show them |

Scoops next to a long ramp's entrance trap the ball: use one by a short ramp, or a centred one. A flat target can hold a ball on its top, so angle them. A captive pod sits at x = 0.485 beside `shortL`, 0.47 beside `shortR`.

## Checking a change

```sh
make scenes && make test
make spacing
tools/render_preview.sh /tmp/board orbital
```

`make playtest` plays every level with the autopilot and lists trapped balls with their position, parts never reached, layout problems, endless scoring loops, and goals never met. It must end with no problems, and its numbers make tuning honest, though the autopilot doesn't aim as a person does. `PLAYTEST="--only tide"` plays one.

`make spacing` runs `tools/scene/check_spacing.py --list 10`, which prints every pair that is too close, any centred row that is off centre, and the 10 tightest pairs that pass. Add `--svg DIR` when running the script directly to draw what it measured, with offenders in red, for comparing against a screenshot.

The checker takes its part sizes from how `PBTableScene.m` places the kit's models. If a part's size or height changes there, update `parts_of` to match. A lamp and the bar it owns are never measured against each other. Other parts that touch on purpose are listed in `ASSEMBLIES`; add to that list only when the parts are meant to read as one.

`python3 tools/scene/compare_models.py <old-dae-dir> <new-dae-dir>` lists models whose triangles, bounds or facing changed. `make test` fails if the compiled tables are out of date, the format breaks, or parts are too close.
