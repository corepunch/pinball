# Architecture

Pinball is a portrait iPhone application in Objective-C with a custom simulation, a SpriteKit
playfield and HUD, and synthesized audio. The shipping view is `SKView`; there is no 3D renderer,
camera, lighting, shadow map or reflection pass.

See [AGENTS.md](AGENTS.md), [CONTRIBUTING.md](CONTRIBUTING.md), and [docs/README.md](docs/README.md).

## Ownership

| Location | Responsibility | Main types |
| --- | --- | --- |
| `App/` | UIKit lifecycle, composition, game updates | `PBGameViewController`, `PBGameController` |
| `App/Core/` | Physics, rules, atomic input, levels, projection, validation | `PBGame`, `PBPhysicsWorld`, `PBRuleEngine`, `PBTablePresentation` |
| `App/UI/` | Sprite playfield, HUD, menus, effects, pointer routing, palette loading | `PBTableSprites`, `PBGameUI`, `PBGameHUD`, `PBSkin` |
| `App/UI/Model/` | Graphics-free navigation | `PBMenuFlow` |
| `App/Audio/` | Synthesized audio | `PBSoundEngine` |
| `App/GameCenter/` | Authentication, score submission and persistence | `PBGameCenter`, `PBGameCenterScores` |

`App/Core` uses Foundation, Core Graphics and SIMD, independently of UI and rendering frameworks.
Both the game and analysis tools run production physics; SpriteKit physics is unused.

## Frame loop and threading

`PBGameUI.update:` drains `applyChange:` mutations and calls its frame handler during the same
SpriteKit update. The controller advances `PBGame`, synchronizes `PBTableSprites`, and forwards
impacts to the interface. This also runs while menus are visible, but pauses simulation and resets
its frame clock. The view requests 60 FPS. The controller serializes simulation/table replacement
with a recursive game lock. Live node attachment, layout and menu changes use `applyChange:`.

`PBGame` consumes atomic input, advances physics at 960 Hz with bounded catch-up, drains physics
events into rules and observers, and advances rule timers. Events are copied before dispatching;
the simulation owns event storage. Score/session snapshots dispatch to main for menu coordination.

UIKit callbacks offer pointers to menus first, then send primary presses through `PBGame`'s atomic
input. They do not inspect live balls. A press charges a waiting plunger ball; otherwise the lowest
free, non-captive ball's screen half selects a flipper until release. Extra fingers maintain the
press. Cancellation, interruption, restart and pause discard charge without firing. Direct
flipper/plunger controls remain available for tools. Core Motion supplies shove nudges only.

## Mini-pinball coordinates and scale

Table x runs across the board and y runs up-table. The nominal authored board is **1.0 × 1.6**,
shortened from 1.0 × 1.9. `PBTablePresentation` supplies a flat, overhead projection with no height
shift or perspective. SpriteKit converts the shared top-left screen coordinates to bottom-left.
HUD, physical display bounds, sprite placement and analysis use the same projection.

The screen-width reference is about ten match-3 pieces across: targets are 0.085 long, bumper
diameters are 0.136, and ball diameter is 0.06834 (about 1/15 of the display width). The ball radius
remains 0.03417 in both physics and its sprite silhouette. Lower lane clearance remains 0.08125,
with centred lamps/rollovers; the lower-kit axis is derived from the flipper pivots (currently
x = 0.457). The shared lower kit is preserved while upper shots move closer to it.

The field fills the width on supported portrait phones. Its background extends behind safe areas;
controls respect them. Physical outer bounds follow the fitted display edges and rounded upper
corners, open at the drain. The extra space on tall displays remains playable. No notch collider is
introduced. Public safe areas provide the corner-radius estimate.

## Sprite rendering

`PBTableSprites` rasterizes authored paths into textures once per table load. Walls, guides,
triangles, flippers, targets, rollovers and scoops use the actual table definitions. The live frame
moves textured quads, reads flipper/spinner/gate angles, drop state, bumper flashes and lamp modes,
and mirrors every ball's position and visibility. Gate swing uses `PBGateGeometry`'s opening sign.
`PBSoftBall` supplies the projected contact ellipse; physics keeps its spherical collision shape.

The petrol background is quiet; coral balls, warm targets and coloured bumper caps provide contrast.
The transparent `PBGameUI` scene owns the world behind its interface root. Menus dim the table.
Autopilot hides only the interface root, preserving the playfield. `PBGameHUD` retains the single
score/target row, pause control, shooter-channel gauge and dark drain well. Luckiest Guy's bundled
licence and notice remain included.

## Authoring and verification

`Scenes/base.xml` defines shared hardware and physics; `Scenes/tables/*.xml` add level pieces.
`make scenes` compiles the runtime JSON with `tools/scene/compile_scenes.py`; the sprites are drawn
from that JSON at table load. New source files are picked up by synchronized Xcode groups.

The campaign ships First Light (`aurora`), Crosswind (`meridian`) and Undertow (`tide`), each with
its own upper-field layout and collection/scoring goal. Shared physics and the lower kit stay fixed.
There is no ramp, lock or multiball. Measured route contracts live in `GameData/Analysis/<table>.json`;
see [the campaign workflow](docs/campaign.md). Fixtures cover advanced mechanics.

`make sprites TABLE=<id>` exports the shipping code-generated shapes as a transparent, rectangular
PNG atlas plus pivot/placement metadata. The native export trims alpha, shares byte-identical images
and packs without rotating or splitting long rails. Runtime continues to generate schematic textures
from geometry; exported PNGs are authoring deliverables. See [the sprite guide](Art/SPRITES.md).

The native UI preview exercises the shipping sprite nodes, projection, pointer routing and live
updates. Software captures composite their source texture pixels and transforms, allowing evidence
without Metal. They are labelled as software captures, not simulator/device or GPU screenshots.
Core XCTest, native route probes and scene checks retain their separate verification roles.

## Progress and services

`PBLevelCatalog` selects table/skin/goal pairs. `PBLevelSession` observes the simulation, and
`PBLevelProgress` persists improving stars and best scores by stable level ID. Menu flow decides
navigation; the controller coordinates starts, restarts, pause and results.

Game Center submits eligible manual scores under the authenticated player who began the game.
Its outbox retains the best pending score per player/table and retries without crossing accounts.
Mappings are in `GameData/GameCenter.json`; signing capabilities remain in the project generator
and entitlements. Authentication, haptics, shove nudges and performance require device verification.
