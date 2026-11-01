# Scenes

The board is text. `Scenes/*.xml` is the source, and nothing else is edited by hand:

```sh
make scenes    # About 5 seconds. Needs Python and Xcode's scntool, not Blender.
```

| Source | Becomes |
| --- | --- |
| `Scenes/aurora.xml`, `meridian.xml` | `GameData/Tables/*.json`, plus each table's flippers, walls, plastics and ramps |
| `Scenes/kit.xml` | Every reusable part |

`GameData/Tables`, `Art/Models/premium/*.dae` and `GameData/Models/premium/*.scn` are compiled output. `GameData/Levels.json` (the campaign) and the skins are still edited directly.

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

A table is its layout and rules. Ramps are a line (`points`, in table units with height) and `<authoring>` settings: width, walls, funnel, arrows. Funnel colliders, entrance lamps and ramp mouths are generated from them, so they are not in the XML. Keep at least 0.0625 of lane for the ball, or it becomes a trap.

## Checking a change

```sh
make scenes && make test
tools/render_preview.sh /tmp/board orbital
```

`python3 tools/scene/compare_models.py <old-dae-dir> <new-dae-dir>` lists models whose triangles, bounds or facing changed. `make test` fails if the compiled tables are out of date, or the format breaks.
