# Pinball

3D pinball in Objective-C and SceneKit, for iPhone with a Mac preview in a window the size of an
iPhone screen. Straight-down camera, table fills the screen.

Tables are JSON and skins are one JPEG, so another table costs kilobytes and another skin under 1 MB.
All meshes are generated in code and all sound is synthesized.

```bash
open Pinball.xcodeproj
```

Schemes: `Pinball-iOS`, `Pinball-macOS`, `PinballCoreTests`.

## Controls

| | iPhone | Mac preview |
|---|---|---|
| Flippers | Touch left or right half | `Z` / `/`, arrows, or Shift keys |
| Start | Either flipper | Either flipper, or `Space` |
| Plunger | Hold right side, release | Hold `Space`, release |
| Nudge | Shove the phone | `X` `C` `V` |
| Next skin | Three-finger tap | `S` |

Launch arguments: `-PBAutopilot 1` plays itself, `-PBSkin classic`, `-PBTable aurora`, `-PBStats 1`.

## Architecture

```
Shared/Core    PBTableDefinition  typed model of a table's JSON
               PBPhysicsWorld     960 Hz fixed-step physics, emits events
               PBRuleEngine       scoring, balls, modes, lamps
               PBGame             world + rules + input; no graphics, runs headless
Shared/Scene   PBTableScene       builds the SceneKit graph, mirrors game state each frame
               PBGeometry         procedural meshes
               PBPlayfieldPainter composites art with crisp lamps, wires, contact shadows
               PBSkin             slices the atlas
               PBDotMatrix        the score display
Shared/Audio   PBSoundEngine      synthesized sound
Shared/App     PBGameController   the frame loop, shared by both platforms
iOS, macOS                        thin hosts: a view and input
GameData                          tables, skins, atlas layout
```

Dependencies point one way: `Core` knows nothing about SceneKit, and scene code only reads game state.
The layout follows Apple's Fox sample: shared game logic in `renderer:updateAtTime:`, with small
per-platform hosts.

SCNPhysicsWorld is deliberately not used. Pinball needs exact control of bounce and kick, and flippers
tunnel at a generic physics step.

## Adding a table

1. Copy `GameData/Tables/aurora.json` and move things around. No code or project changes are needed.
2. Point the table test at it and run `PinballCoreTests`. An autopilot plays 25 simulated minutes and
   fails if a feature can't be reached or balls get trapped. This caught real layout bugs in Aurora.
3. `python3 tools/skin_tool.py template <table>` draws that table's guide for painting skins.

Wall surfaces facing up the table need a slope, or a ball can come to rest on them, and gaps need more
than a ball's width (0.05). Rollover roles come from id prefixes: `orbit*`, `outlane*`, `inlane*`.

## Skins

See [Art/SKIN_GUIDE.md](Art/SKIN_GUIDE.md).

`python3 tools/make_xcodeproj.py` regenerates the project if targets change. Source folders are
synchronized, so new files need no project edit.
