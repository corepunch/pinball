# Agent guide: Pinball

Pinball is an Objective-C iPhone game with custom physics, SceneKit rendering, and a
transparent SpriteKit interface. Current user instructions take precedence over these defaults.
When an agreed change replaces a decision, update its documentation and regression checks.

## Read first

- [ARCHITECTURE.md](ARCHITECTURE.md): ownership, data flow, coordinates, and threading.
- [CONTRIBUTING.md](CONTRIBUTING.md): generation, build, test, and capture workflow.
- [docs/README.md](docs/README.md): index of specialist guides and historical references.
- Inspect `git status` and the affected files. Preserve existing work and unrelated changes.

Keep one canonical agent guide here. Avoid conflicting copies for individual agents, temporary
chat history, machine-specific paths, and unverified test results as project policy.

## Source of truth

- `Scenes/base.xml` defines shared hardware and physics; `Scenes/tables/*.xml` define table
  additions; `Scenes/kit.xml` defines prefabs; `Scenes/ramps.xml` defines ramp kits.
- Edit XML, then run `make scenes`. Never hand-edit `GameData/Tables/*.json`,
  `Art/Models/premium/*.dae`, `Art/Models/manifest.json`, or `GameData/Models/premium/*.scn`.
- Author `GameData/Levels.json`, skin JSON, atlas layout, UI control metadata, and Game Center
  mappings directly. `Tests/Fixtures/features.json` is a test fixture, not a shipped level.
- Xcode source folders are synchronized: new source files normally need no project edit.
  Change `tools/make_xcodeproj.py` and regenerate when target configuration changes.
- The current shipped level is `aurora` (First Light), with Orbital: three upper-right bumpers, three bonus lanes, a spinner and two stand-ups, all on one plane. Ramps are deferred for now. See
  [the shot plan](docs/aurora.md). Do not restore historical mechanisms from concepts or fixtures.

## Ownership and behavior

- Keep `App/Core` independent of SceneKit, SpriteKit, UIKit, and AppKit. Tests and tools must
  reuse production physics, rules, input, and projection rather than alternate implementations.
- `PBGame` consumes atomic input on the render thread. UIKit callbacks must not read or mutate
  live physics to select controls. Send gameplay presses through `setPrimaryPressed:`.
- Menus/pause receive pointers first. Press anywhere to charge a ball waiting at the plunger;
  otherwise the ball's screen half chooses a flipper. Latch until release. Multiball chooses the
  lowest free, non-captive ball. Cancellation/interruption discards charge without launching.
- `PBGameUI` owns the overlay, menus, effects, and input capture; `PBGameHUD` owns gameplay
  presentation. Decorative nodes pass touches through. Queue live SpriteKit mutations through
  `applyChange:`; a SceneKit transaction lock alone does not protect SpriteKit writes.
- `PBTablePresentation` owns shared orthographic framing, safe-area layout, projection, and
  fitted display bounds. Camera changes must update preview tools and projected checks together.
- Ball mesh and physical sphere share radius **0.03417** from source. No mesh-only enlargement
  or static centre lift. Preserve contact-driven, volume-preserving rubber strain and floor support.
  Verify readability at normal speed, not only in an enlarged slow-motion capture.
- The shooter gate rotates in the table plane around endpoint `a`. Solver and mesh share
  `PBGateGeometry`; it must not levitate. Triangle tops are level, bolts sit at rounded-corner
  arc centres, and trim is concentric. Preserve their geometry regressions.
- Return-lane guides are two thin plates at 50% and 100% height, supported by three hollow
  screw tubes; do not turn them back into solid blocks. Keep the shared collision outline.
  Flippers have a small, flat, contrasted detail centred on the hinge with a real shadow;
  there is no tip screw or large domed hub.
- Do not add mechanisms or change physics during a visual pass unless requested. Preserve the
  approved lower kit, centred left of the phone because the shooter lane occupies the right side.
- The four lower straight channels share **0.08125 clear width** between physical faces, with
  lamps/rollovers centred in each. The lower-kit axis is currently x = 0.457; derive it from the
  flipper pivots in tools. Use the same straight-section target for authored upper re-entry lanes;
  bends and mouths may need additional clearance. Do not measure between wall centrelines.

## Visual direction

- **Peggle Blast is the framing and HUD reference:**
  [official page](https://www.ea.com/games/peggle/peggle-blast). Use an almost full-width board,
  continuous illustrated scenery, readable HUD, and decoration concentrated at top and bottom.
- Let the rounded display bound the illustration. No inset Roman arch, top HUD panel, bulky 3D
  cabinet, decorative side columns, or white/gold drain/shooter outline. Keep the dark drain well.
- Use a dark navy/petrol playfield with restrained warm pinstripes, following Space Cadet
  for classic pinball contrast: real glowing lamps and the coral ball should stand out. Keep
  the centre quiet and low contrast. The audience still enjoys tactile, inviting pieces; avoid
  busy starfields, painted glowing lamps, neon overload and dot-matrix HUD readouts.
- Decorative surrounds belong in the 2D overlay, outside ball paths. Backgrounds extend behind
  the notch; readable text and finger-sized pause controls respect safe areas.
- Use a close orthographic camera, currently 20 degrees from overhead, looking from flippers
  toward the upper board. Blossom Blast Saga is the reference for readable angled presentation.
  Keep the complete playable boundary, shooter lane, and flippers visible across phone sizes.
- The compact HUD has one score/target row at top left, pause at top right, and a progress gauge
  along the shooter channel. Do not restore Ball/Save/event rows. Retain the bundled Luckiest Guy
  font's licence/notice files.
- The opaque coral-orange ball is **uncoated rubber**: metalness 0, roughness 0.68, clear coat 0,
  and subtle mould grain. No chrome or playfield-mirroring ball shader.
- Lighting stays fixed under phone tilt; motion supplies deliberate nudges only. Shadows have a
  hard **4096 × 2048** limit, one manually fitted projection, and 32 samples. Fit the projection
  to the visible screen; never raise resolution to 8K/16K or substitute square maps as a quick fix.
- Playfield reflections are disabled. Keep their retained implementation/settings available for
  future levels; do not delete them or globally restore reflections without a request.
- Display collisions follow rounded screen corners, with no Dynamic Island/notch obstacle.
  Public UIKit APIs do not expose exact corner radii; the current fit estimates from safe areas.

## Artwork and disk use

- Generate every icon in a set together as one strip/atlas in one ImageGen call. Author normal,
  selected, pressed, hover, and disabled states together when needed. Use authored states directly;
  never generate icons separately or derive states by script recolouring.
- Edit code-native meshes/materials in source. Verify with actual SceneKit/SpriteKit renders;
  label generated concepts separately. Preserve asset licences and notices.
- Before downloads/jobs, estimate total additional disk use, including dependencies, caches,
  intermediates, and duplicates. Above **500 MB**, run in the cloud when feasible. Keep large
  working files there, download deliverables only, and preserve irreplaceable masters in persistent
  storage with their location and reproduction steps recorded.
- If local hardware is required or cloud execution is unavailable, explain that constraint before
  creating more than 500 MB locally. Reuse caches; avoid gratuitous installs.

## Verification and handoff

- For code changes: `make test`, then `make iphone`. For scene edits: `make scenes` first.
  Run Xcode tests and app builds sequentially to avoid shared build-database contention.
- For visuals, use `tools/render_preview.sh` and/or `tools/render_ui_preview.sh`. Use isometry
  for geometry and normal-speed captures for motion. `make ui-check` without a GPU checks real
  nodes/input/projection, but does not produce screenshots.
- Run analysis tests when changing analysis tools. Documentation-only edits need link, command,
  and consistency checks rather than an app build.
- Report changes, evidence, and limitations. Distinguish builds, installation, and physical-device
  testing. Never claim checks or renders ran when blocked by Metal, signing, services, or devices.
