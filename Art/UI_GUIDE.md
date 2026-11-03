# Game interface

Peggle Blast is the framing and HUD reference: almost full-width play, continuous illustrated scenery,
a slim contour, and compact readable UI. Space Cadet guides the dark playfield and glowing-lamp contrast. The approved direction is in [AGENTS.md](../AGENTS.md).
`App/UI/PBGameUI.m` is the transparent SpriteKit scene assigned to `overlaySKScene`; its
`PBGameHUD` draws one row, `score / level target`, in Luckiest Guy with a cream-to-amber gradient,
a sage outline and a small shadow. No Ball, Save, level caption, or event-message row is drawn.
There is no HUD panel and no reserved header strip. Pause uses the authored control atlas with a
finger-sized hit area. The menu flow remains unchanged. A slim vertical gauge fills from bottom to
top along the outside of the shooter channel; its centre stays clear for the ball. The gauge uses
`PBLevelDef.goalCount`, saturates at completion and empties on restart. Non-score goals use
`PBLevelSession.progress` and show their compact count/unit beside the score; free play has no gauge.

The unmodified font and Apache 2.0 license ship in `GameData/Fonts/`, with source attribution in
`NOTICE.txt`. The font is registered from the supplied resource bundle for both iOS and macOS
previews. CoreText glyph paths supply the gradient text texture; unchanged captions reuse it.

The illustration extends behind the HUD and notch to the edges of the display. There is no inset
Roman arch, top border, or decorative side frame: the device's rounded screen is the surround.
The drain keeps a dark well on the actual playfield axis. No white/gold contour is drawn along
the apron, drain opening or shooter channel; the underlying board geometry supplies their edges.
The ball mesh and collision sphere share radius 0.03417, 15% smaller than the previous visible ball.
Their undeformed centres coincide; rubber deformation alone adjusts floor/contact support. The invisible
outer collider now follows the display sides and rounded top corners instead of the old Roman arch.
`PBTableDisplayBoundary` converts the display contour through the shared camera projection;
`PBPhysicsWorld` updates its fixed outer segments and broad-phase grid when the viewport changes.
The corner radius is an approximation from safe-area insets (UIKit has no public display-radius API).
There is no Dynamic Island collider. The drain remains open; the lower corners sit behind the apron.

`PBTablePresentation` shares safe-area layout and orthographic projection between SceneKit,
the HUD and headless checks. The camera looks up-table from the flippers, 20 degrees from overhead.
The score and pause follow the reference native title/avatar row: 20-point side margins and a
76-point centre on the 402-point authoring canvas, shifted together when the top safe area requires it.
The floating text and pause clear the actual top safe-area inset, including on Dynamic Island phones;
background artwork continues behind the cutout. Pause has at least a 44-point physical hit area.
Decorative nodes never capture gameplay input. Menus scale to small phones and consume their touches.
Flying score awards share the HUD's Luckiest Guy glyph renderer and warm gradient, with a black
outline for contrast over the board. Their base font size is 15 points; pop/rise/fade timing is unchanged.

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
Gameplay uses one anywhere-press input. On the simulation thread, a fresh press charges the spring
if a ball is waiting at the plunger; otherwise it raises the flipper on the ball's screen half.
The choice stays fixed until release, so a held finger does not switch sides automatically. The
shared orthographic projection puts screen centre at table x = width / 2. During multiball the
lowest free, non-captive ball chooses the side. Extra fingers keep the current press held until
the last gameplay finger lifts. Pause, interruptions and cancelled touches discard spring charge
without firing. Starting/restarting requires a fresh press. Help uses the same anywhere wording.
Sound mutes the audio mixer; haptics gate impact feedback. Both preferences persist.

## Verification

Build the iPhone app with scheme `Pinball`. The headless `PinballCoreTests` target includes six
`PBInterfaceTests` covering navigation, confirmation, replay and restarting while charging.

Render the real SpriteKit interface over the real table from working assets:

```bash
zsh tools/render_ui_preview.sh - "$PWD/Art/Previews"
```

An app/resource bundle path can replace `-`. A local Metal device is required to export screenshots.
The tool exports every screen and smaller-phone previews, and verifies pointer capture,
cancellation, gameplay passthrough, extreme-score bounds, gauge progress/reset and Dynamic Island clearance.
Representative preview scores do not come from a live leaderboard.

Without Metal, run the same real UI-node and input assertions plus a comparison of SceneKit's
actual camera matrix against the shared 2D projection:

```bash
make ui-check
```

This mode does not export or claim screenshots. `Tests/PBPresentationTests.m` additionally checks
phone-size framing, consistent orthographic scale, safe-area changes, authoring projection,
and physical bounces at the screen top/corners after resizing.
Hit scores use readable Avenir labels; sparks use normal alpha blending to avoid smoky grey overlays.
