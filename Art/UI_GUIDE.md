# Arcade interface

The shipping interface is `App/UI/PBGameUI.m`, a SpriteKit scene assigned to the SceneKit view's
`overlaySKScene`. It uses opaque navy cabinet panels, brass trim, ivory condensed type, red enamel
primary buttons, and blue enamel icon keys. It uses no system material, blur, or Liquid Glass controls.
The title artwork is the selected app-icon concept 10.

Screens: home, playing, paused, settings, how to play, results, end-game confirmation, restart
confirmation. The gameplay score occupies the apron; pause stays clear of the home indicator and
the central top lanes. Menus scale to smaller phones while preserving button hit areas.

## Artwork

- Original complete ImageGen atlas: `Art/Masters/arcade-ui-controls.png`.
- Exact prompt: `Art/Prompts/arcade-ui-controls.txt`.
- Runtime copy, unchanged: `GameData/UI/controls.png`.
- Measured source rectangles and state ordering: `GameData/UI/controls.json`.
- Title artwork: `GameData/UI/title-art.png`, copied from `Art/Masters/app-icon-10.png`.

All ten glyph controls and both blank text-button faces were drawn together in one built-in
ImageGen call with five authored state rows: normal, selected, pressed, hover, disabled. The actual
output is 1920×819; the two blank faces are wider than the icon keys. The manifest records the
actual fixed slots, rather than assuming the requested equal-cell layout. Every row uses the same
source geometry. The loader samples those authored regions directly, with no state recoloring,
state synthesis, per-cell correction, or press displacement. Text labels are rendered separately.
Resizable text-button faces use nine-slicing, with source-pixel cap insets stored in `nineSliceInsets`
(left, bottom, right, top). Nine SpriteKit patches explicitly preserve corner dimensions in the
SceneKit overlay: corners scale uniformly to the control height, edges stretch along one axis, and
the center fills the remaining area. All five authored states share the same patch geometry.
Each wide cell is uploaded directly from its fixed source rectangle before subdivision, preserving
its authored pixels and avoiding nested atlas UVs in the overlay.
Corners and rim thickness stay consistent across narrow toggles and wide action buttons. Fixed icon
keys retain their original proportions so the glyphs remain intact.
The sampled artwork has true alpha around opaque enamel faces. At gameplay sizes the shallow
bevels and glyphs remain readable; slight painted highlight variations are retained in the source.

## Behavior

`App/UI/Model/PBMenuFlow` owns navigation independently of graphics. Home and results require an
explicit Play action. Returning from settings/help restores the originating screen. Abandon/restart
require confirmation, and cancellation preserves the current run.

`PBGameController` pauses the simulation while a menu is open. It snapshots score/ball state on
the render thread, then updates UI on main. Starting/replaying queues `PBGame.requestNewGame`,
which the simulation consumes on its own thread. Restarting clears the previous plunger charge.
Only completed manual games reach the existing Game Center submission path.

`App/PBGameViewController` routes each touch to the menu first. A cancelled or dragged-off button
does not activate, menu background touches cannot start a game, and gameplay touches outside the
pause button still reach the flippers. Menu interaction remains available while simulation is paused.
Sound mutes the audio mixer; haptics gate impact feedback. Both preferences persist.

## Verification

Build the iPhone app with scheme `Pinball`. The headless `PinballCoreTests` target includes six
`PBInterfaceTests` covering navigation, confirmation, replay and restarting while charging.

Render the real SpriteKit interface over the real table using the standalone local graphics tool:

```bash
zsh tools/render_ui_preview.sh "$PWD/Build/Products/Debug-iphoneos/Pinball.app" "$PWD/Art/Previews"
```

Pass the actual built app path if Xcode uses a different products directory. This requires local
macOS graphics access and existing Xcode tools, with no dependency downloads. It exports every
screen plus smaller-phone home/settings previews, and checks pointer capture, cancellation and
gameplay passthrough. Previews live at `Art/Previews/ui-*.png`. They use representative scores for
layout verification, not a live leaderboard result.
