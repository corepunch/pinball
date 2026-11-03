# Development workflow

Read [AGENTS.md](AGENTS.md) before changes and [ARCHITECTURE.md](ARCHITECTURE.md) to find the
owner of the behavior. Specialist guides are indexed in [docs/README.md](docs/README.md).

## Environment

Use macOS with full Xcode selected, its command-line tools, Python 3, and zsh. The generated project
targets iOS 17+; headless XCTest runs on macOS. No third-party dependency download is needed for
the standard scene compiler, previews, or test suite. Keep existing build caches instead of routinely
cleaning them. Follow the 500 MB disk rule in AGENTS.md before large jobs or new SDK/runtime installs.

The two schemes are `Pinball` and `PinballCoreTests`. `make help` lists supported commands.
`make iphone` discovers the team from an installed Apple Development certificate; set `TEAM=<id>`
to override it. `CONFIG=Debug` changes the default Release device build.

## Change and verify

1. Inspect the existing diff; preserve unrelated work.
2. Edit the owning source. For table/hardware geometry, change `Scenes/` and run `make scenes`.
   Include regenerated tables, COLLADA, manifest, and compiled SceneKit models in the change.
3. Add meaningful regressions for changed behavior. Prefer production game-update paths over
   isolated helper assertions; timing/motion tests must sample full display frames.
4. After code or scene changes, run these sequentially:

   ```sh
   make test
   make iphone
   ```

5. For presentation changes, inspect actual renders at gameplay size and relevant phone sizes.
   Geometry needs an oblique/isometric check; animation needs a normal-speed check.
6. Run `git diff --check`, update affected documentation, and report verification/limitations.
   Documentation-only edits need consistency and local-link checks; they do not require a build.

`make test` runs scene/compiler checks, native flipper-shot probes, strict Aurora route contracts, macOS XCTest, and
`make ui-check`. The last command exercises actual UI nodes, touch routing, materials, camera,
and mesh transforms without requiring a graphics device. It does not capture screenshots.

Use `make analysis-test` when changing analysis code. For level/layout changes, also use
`make spacing`, `make shots`, and the relevant `make playtest` or `make analysis TABLE=aurora`
workflow. Read the analysis/level guides before treating exploratory results as acceptance criteria.
`make playtest PLAYTEST=--tune` changes level goals/stars; use it only when tuning is intended.

## Real captures

The native render scripts compile production source and read working assets through a resource
bundle. They need no app build or installation. Run from the repository root:

```sh
zsh tools/render_preview.sh /tmp/pinball-world orbital
zsh tools/render_ui_preview.sh - /tmp/pinball-ui
```

`-` selects live working assets for the UI tool. Supply an app/resource bundle path instead to
inspect that bundle. Set `PB_PREVIEW_TABLE=<id>` for another compiled table and pass a skin name
such as `orbital` or `abyss` to the world renderer.

| World-render option | Purpose |
| --- | --- |
| `--ball-realtime` | Normal-speed gameplay framing and close-up through regular game updates |
| `--ball-deformation` | Enlarged 4× slow motion and material comparison; secondary evidence |
| `--gate-physics` | Real plunge with fixed hinge, planar gate swing, passage/closure checks |
| `--shadow-compare` | Controlled 2K/4K/off captures and shadow-coverage verification |

For example:

```sh
zsh tools/render_preview.sh /tmp/pinball-ball orbital --ball-realtime
```

Normal-speed GIFs use matching 0.02-second simulation/playback intervals (50 Hz, exact GIF timing).
Tests separately check live updates at 30/60/120 Hz. Premium world renders also export left/right
triangle isometry and fastener close-ups. Do not replace these with ImageGen concepts as proof.
Save useful final evidence in `Art/Previews/`; keep routine intermediates in temporary output folders.

## Run on a device

```sh
make list-devices
make iphone-deploy
```

Deployment builds, installs, and launches on the only available iPhone. Set `DEVICE=<identifier>`
when necessary. For the simulator, use `make simulator-run` and optionally `SIMULATOR=<name>`.
Installing a new simulator/runtime may exceed the disk threshold; check before doing so.

Useful app launch arguments: `-PBLevel 1`, `-PBTable aurora`, `-PBSkin orbital`, `-PBAutopilot 1`,
and `-PBStats 1`. Explicit table/autopilot launches bypass the normal level path. Autopilot also
skips normal menus and Game Center, so it cannot validate manual input or service behavior.

Use a real phone for haptics, shove nudges, performance, and Game Center account flows. A successful
build is distinct from deployment and from exercising those behaviors.

## Project and asset maintenance

New source files are discovered through synchronized Xcode groups. When targets/settings change,
edit `tools/make_xcodeproj.py`, run `python3 tools/make_xcodeproj.py`, and review the generated diff.
Preserve signing entitlements, GameKit settings, and the graphics-free test target boundaries.

Use one authored atlas for an icon set and its visual states. Retain licences/notices, including
those under `GameData/Fonts/`. For mesh/material edits, work in source rather than repainting an
image of the part. Detailed ownership and artwork rules are in the Art guides.

Native tests, `scntool`, signing, and Metal previews may need access to macOS services unavailable
inside a restricted sandbox. Use the supported permission mechanism when appropriate. Report the
specific blocked check; do not silently substitute stale assets, unsigned build claims, or concepts
for a real render. Avoid running Xcode test and app builds concurrently against shared build output.
