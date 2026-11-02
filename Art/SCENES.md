# Scenes

The board is text. `Scenes/` is the source, and nothing else is edited by hand:

```sh
make scenes    # Needs Python and Xcode's scntool, not Blender.
```

| Source | Becomes |
| --- | --- |
| `Scenes/tables/*.xml` | One table each: `GameData/Tables/*.json`, plus its own walls and plastics |
| `Scenes/base.xml` | What every table must have: flippers, slingshots, lanes, floors, plunger, lower lamps, scores. One shared model each |
| `Scenes/ramps.xml` | Ramp kits, with the walls that go with them. A table takes one for each side with `kits="longL longR"` |
| `Scenes/kit.xml` | Every reusable part |

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
| `<fillet radius>`, `<inset amount>` | Round the corners; move the outline in |
| `<sweep section>` | Run a (offset, height) section round the outline |
| `<dome rings apex>` | A moulded lens over the outline |

Also `<use prefab="…" at="x,y" name="value"…>` places a prefab with its variables set, and `<each-corner points inset>` repeats its contents at each corner. A `role` is a surface the game binds to the skin's material; see `skinModel` in `PBTableScene.m`.

## Tables

A table is its layout and rules. A plastic wall can name its kit prefab with `part`, as the floors under the flippers do. Ramps are a line (`points`, in table units with height) and `<authoring>` settings: width, walls, funnel, arrows. Funnel colliders, entrance lamps and ramp mouths are generated from them, so they are not in the XML. Keep at least 0.0625 of lane for the ball, or it becomes a trap.

### Layout rules

Judge a layout as the player sees it: through the 30 degree camera, on a phone, where a raised part appears higher up the screen than its coordinates say.

- **Leave 5 points of clear board between parts** (0.0127 of the table's width). `make spacing` measures this; closer than that reads as touching.
- **Keep the two sides the same.** Where an element is on one side, put its match on the other, mirrored around x = 0.4775: slingshots, walls, lanes, lamps, bars and floors. Differ only where the shooter lane or a table's own feature leaves no choice. A new part on one side needs a reason not to have a twin.
- **A wall under 0.01 radius is solid metal,** as the shooter lane's is: too thin for a coloured top (`THIN_WALL`).
- **The ball can always get under the flippers.** Below them the board stays open, and a low floor each side (`apronL`, `apronR`) slopes to the drain between them, so a ball falling behind rolls under and out. Their slope matches the flippers' at rest: any shallower and the ball wedges under a flipper's tip. Don't block this space.
- **Centre on one axis.** The bumpers, the top lanes and the column of lamps all sit on x = 0.4775, and the ramps' exits mirror around it (0.26 and 0.695). This is left of the screen's centre (0.5), because the shooter lane takes up the right side.
- **Fit lamps to their lanes.** A lane is about 0.0625 wide, so its lamp has `size="0.017"` and sits above the wall ends rather than beside them.
- **Rollover bars belong to a lamp.** Give the lamp `bar="<rollover id>"` and the rollover only its `id` and `r`. The compiler puts the bar and its switch directly below the lamp, always the same distance away (`BAR_BELOW_LAMP`), so moving the lamp moves both. Never position a bar by hand.
- **Change a ramp's shape smoothly.** The compiler rejects sudden changes in a ramp's curve, so blend a move over many points.
- **Rollover bars and stand-up targets lie flat,** like the lamps. Targets stay dark until hit, as an unlit lamp does.
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
