# Pinball

3D pinball in Objective-C and SceneKit, for iPhone. Straight-down camera, table fills the screen.

Tables are JSON; skins contain a hardware atlas, palette, and optionally a separate playfield painting.
Complete tables can be authored in Blender with the Pinball Builder curve modifier and gameplay properties, then exported to JSON and compiled SceneKit models. All sound is synthesized.

The default **Orbital** skin pairs illustrated space art with ivory/vermilion enamel and champagne trim.
**Abyss** uses deep-sea illustration, seafoam enamel and brass. Both follow the concepts in
`Art/Concepts/cadet-inspired-redesign.png`: a table that uses the phone's edges as its own, deep hook channels
with evenly spaced four-phase chevron lights, jewelled bumpers with authored idle/hit caps, low molded guide
housings and larger, fewer inserts. The ball is 20% larger, with clearances and progression retuned for it.
Backgrounds are full-bleed illustrations without printed rulers, compasses, borders or title panels. Classic and Neon remain available. The editable
Open `Art/Models/pinball-levels.blend` for the complete editable tables. The installable add-on and workflow are in [Art/BLENDER_AUTHORING.md](Art/BLENDER_AUTHORING.md); hardware rebuild details are in [Art/MODEL_GUIDE.md](Art/MODEL_GUIDE.md).

```bash
open Pinball.xcodeproj
```

Schemes: `Pinball` (iPhone app) and `PinballCoreTests` (headless tests on Mac).

Or from the command line, where `make help` lists everything:

```bash
make iphone-deploy
```

That builds a signed Release app, installs it on the only connected iPhone, and launches it. Set
`DEVICE=<name or identifier>` when several are connected (`make list-devices`), `TEAM=<id>` to override the
team taken from your Apple Development certificate, and `CONFIG=Debug` for a debug build.
`make simulator-run` does the same in the Simulator, and `make test` runs the headless tests.

`App/` contains all application source and the asset catalog, with modules for simulation,
rendering, audio, interface, and Game Center. Tests and standalone preview tools compile the
modules they need directly from `App/`. `GameData/` holds runtime resources. There is no Mac app target.
`Art/` holds source artwork and models; `Tests/` and `tools/` hold verification and asset tooling.
Use the iPhone Simulator for gameplay checks and a real iPhone for motion, haptics, and performance.

## Controls

| Action | iPhone |
|---|---|
| Flippers | Touch left or right half |
| Start / replay | PLAY / PLAY AGAIN |
| Pause / resume | Enamel pause button / RESUME |
| Plunger | Hold right side, release |
| Nudge | Shove the phone |
| Next skin | Settings → CHANGE, or three-finger tap |
| Game Center | SCORES on the main menu or results screen |

Launch arguments: `-PBAutopilot 1` plays itself, `-PBSkin classic`, `-PBTable aurora`, `-PBStats 1`.
Use `-PBSkin orbital` or `-PBSkin abyss` to preview either new set directly.

On iPhone, tilting the phone moves the table light and reflection environment, shifting highlights
and real shadows across the hardware. The initial grip is calibrated when the app becomes active;
motion is smoothed and limited so the table stays readable. Deliberate shoves still trigger nudges.

## Game interface

The app uses a custom SpriteKit overlay: opaque navy panels, brass trim, ivory typography, and
authored enamel buttons. It includes a main menu, gameplay HUD, pause, sound/haptic
settings, skin selection, controls help, final results, and confirmation before restarting or ending
a live game. The board fills the phone, with the flippers on its bottom edge. Score, ball and pause are small indicators beside the camera cutout, with the level goal and game messages below it. The pause button respects
the phone's safe area. Menu touches are consumed before they can operate a flipper.

Settings persist between launches. App inactivity pauses a live run and returns to the pause screen;
the player explicitly resumes. Results remain visible until choosing replay or the main menu. Autopilot
previews bypass the interface. See [Art/UI_GUIDE.md](Art/UI_GUIDE.md) for artwork, layout, and verification.

Haptics follow ball bounces, with stronger pulses for active elements and launch feedback scaled to
the plunger pull. Drawing the plunger ticks like a spring winding, tightening up to a firm stop at full pull. Tiny resting contacts stay quiet. Haptics can be disabled in Settings.

## Game Center

The app initializes GameKit once its window appears. The custom SCORES button opens
the Game Center dashboard, including leaderboards. The floating native access point is hidden.
Play pauses during sign-in, the dashboard, and app inactivity, without advancing the ball through
the time spent away. A live run stays at the pause menu until the player resumes.
Autopilot previews skip Game Center entirely.

At game over, the final score (including bonus) is submitted to the table's classic leaderboard.
Only games started and finished with the same authenticated Game Center player qualify. Signed-out
games still work and retain the existing local high score. Failed submissions persist as the best
pending score per player/table and retry on authentication, foregrounding, or the next completed game.
An account switch never uploads another player's pending scores.

Before testing live services:

1. Select your development team for the app target and enable Game Center for its App ID. The
   checked-in entitlements and generated Xcode target capabilities already request Game Center.
2. In App Store Connect, enable Game Center for the app and create a **classic leaderboard** with ID
   `com.igorchernakov.pinball.aurora.highscore`, named **Aurora High Scores**. Set score format to
   integer, sorting to **High to Low**, and submission policy to **Best Score**; add a localization
   and associate the leaderboard with the app version. Set it as the default leaderboard.
3. IDs are configured in `GameData/GameCenter.json`, keyed by table identifier.
   Use matching IDs in App Store Connect, or update this
   mapping to your existing IDs. A new table needs its own mapping.
4. Run a signed build with a Game Center test account, finish a manual game, then choose SCORES.
   Test cancellation, offline upload/retry, and changing accounts as well.

Unsigned builds verify compilation but cannot validate Game Center authentication or live uploads.
`python3 tools/make_xcodeproj.py` preserves the capability, entitlement path, and GameKit link settings.
Apple's [Game Center setup guide](https://developer.apple.com/documentation/gamekit/initializing-and-configuring-game-center)
and [leaderboard configuration guide](https://developer.apple.com/help/app-store-connect/configure-game-center/manage-leaderboards/)
cover the account-side configuration.

## Architecture

```
App/Core       PBTableDefinition  typed model of a table's JSON
               PBPhysicsWorld     960 Hz fixed-step physics, emits events
               PBRuleEngine       scoring, balls, modes, lamps
               PBGame             world + rules + input; no graphics, runs headless
App/Scene      PBTableScene       builds the SceneKit graph, mirrors game state each frame
               PBGeometry         procedural meshes
               PBPlayfieldPainter composites art with crisp lamps, wires, contact shadows
               PBSkin             loads per-skin layouts, sources, materials and atlas states
               PBModelLibrary     loads Blender mesh kits and isolates animated instances
App/Audio      PBSoundEngine      synthesized sound
App/UI         PBGameUI           menus and the gameplay HUD
               Model/PBMenuFlow   navigation and settings, independent of graphics
App/GameCenter PBGameCenter       authentication, leaderboards, and score submission
App            PBGameController   the app's frame loop
                                  iPhone host: view, input, lifecycle, and app icon
GameData                          tables, skins, atlas layout
```

Dependencies point one way: `Core` knows nothing about SceneKit, and scene code only reads game state.
The frame loop lives in `renderer:updateAtTime:`, while the iPhone view controller forwards input
and lifecycle events.

The app controller, audio, and Game Center use iPhone APIs directly. The standalone Mac preview tools
reuse rendering code; their only conditional bridge converts Core Graphics paths to SceneKit's native
path type inside `PBGeometry.m`. Interface artwork loads through ImageIO on both app and preview builds.

SCNPhysicsWorld is deliberately not used. Pinball needs exact control of bounce and kick, and flippers
tunnel at a generic physics step.

## Levels

`GameData/Levels.json` is the level list: each entry pairs a table and skin with a goal and two star scores.
There is one level for now, `aurora`, which is the bare base from `Scenes/base.xml` with nothing else on the board;
the old 30 levels were removed, and level 1 is being rebuilt from this empty board. `Tests/Fixtures/features.json`
keeps a full board (ramp, deck, drops, stand-ups, scoops, bumpers) so the rules those parts use stay tested.
The goal (`score`, or a count of `ramps`, `bumpers`, `drops`, `saucers`, `spinners`, `multiballs` or `jackpots`)
earns the first star and unlocks the next level; the two scores earn the others. Progress is saved by level id,
so levels can be reordered or added. `testEveryGoalIsReachableAndThreeStarsAreNotAutomatic` plays autopilot games
on each table, logs `BALANCE` percentiles for setting targets, and fails on a goal it never reaches.
Run with `-PBLevel <n>` to show that level's table behind the menus. `-PBTable <id>` or `-PBAutopilot YES` skip levels for free play.

## Adding a table

1. Copy a file in `GameData/Tables` and move things around. No code or project changes are needed.
2. Rebuild the meshes ([Art/MODEL_GUIDE.md](Art/MODEL_GUIDE.md)), which covers every table. A test fails if any are missing.
3. Run `PinballCoreTests`, which covers every table automatically. An autopilot plays 25 simulated minutes
   and fails if a feature can't be reached or balls get trapped. This caught real layout bugs in Aurora.
4. Run the app with `-PBTable <id>` to play it, or `PB_PREVIEW_TABLE=<id> tools/render_preview.sh` for a render.

`testNoTableHasOverlappingElements` runs on every JSON in `GameData/Tables`, with no setup. It projects each
drawn part through the table camera, at its drawn size, and fails on parts covering each other (flipper
sweeps and ramps included), solids closer than a ball's width, or anything off the table or on the apron. Parts
may only touch where one is built onto another. Collide-only walls (`"style": "none"`) are never seen, so they
are exempt, which is how a wall can run under a ramp.

Run the headless physics, layout, and score-persistence tests without building the app:

```bash
xcodebuild -project Pinball.xcodeproj -scheme PinballCoreTests \
  -destination 'platform=macOS' -derivedDataPath Build test
```

The standalone artwork renderer reads `GameData/` directly and needs no app build. See
[Art/SKIN_GUIDE.md](Art/SKIN_GUIDE.md) for its commands.

Wall surfaces facing up the table need a slope, or a ball can come to rest on them, and gaps need more
than a ball's width (0.05). The outer wall is invisible and follows the screen, with corners matching the phone's. `decor` lists static kit models, and a lamp's `"shape": "arrow"` with `"angle"`
makes a triangular insert pointing at its shot. Rollover roles come from id prefixes: `orbit*`, `outlane*`, `inlane*`.

## Skins

See [Art/SKIN_GUIDE.md](Art/SKIN_GUIDE.md).

`python3 tools/make_xcodeproj.py` regenerates the project if targets change. Source folders are
synchronized, so new files need no project edit.
