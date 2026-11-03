# Hardware kit

Every part of the hardware comes from `Scenes/kit.xml`, built by `make scenes` ([SCENES.md](SCENES.md)). This guide is about how the parts should look, and how to check them.

Framing/HUD reference: Peggle Blast ([AGENTS.md](../AGENTS.md)). Space Cadet guides the dark playfield and glowing-lamp contrast; concepts in `Art/Concepts/` remain historical hardware studies.
COLLADA output: `Art/Models/premium/*.dae`. Shipped scenes: `GameData/Models/premium/*.scn`.

iOS SceneKit cannot read COLLADA at runtime, and a missing or unreadable model silently falls back
to procedural geometry. The game therefore only loads compiled `.scn` files.

Kit parts, built to unit radius (or unit half length) and scaled by the table:

- `bumper-base`, `bumper-cap`: a mushroom. A flared foot, a narrow black waist, and a wide cap that overhangs them and throws a shadow, painted at runtime from the skin's `capBase` and `capStar`, with a raised hub holding the jewel in its bore. The jewel is a light bulb, always lit and past the bloom threshold; the star's triangles glow a deep red at rest and flare orange on a hit, while the cream stays paint. No lit slots, bolts or thin bands: they break up into pixels at phone size.
- `insert-bezel`, `insert-arrow`: round and triangular bezels with clear lenses over the painted insert. Round bezels have broad raised chamfers, widened inward within the existing footprint.
- `post`, `target`, `flasher-cage`. A target is scaled to its edge's length with a fixed depth matching its collider; stand-ups are about 0.1 long so they read at phone size. Spinners are built in `buildSpinnersAndGates`: two posts, a thick axle and a framed plate spanning their lane.
- `arrow-lens`, `arrow-stack`, `bullet-cyan`, `bullet-amber`, `stud`, `mech-bracket`, `mech-piston`: decor, placed from the table's `decor` list. They are low relief, so a ball can pass over them without looking wrong. Physics ignores them; the layout test does not.

Table-specific parts, built by `make scenes` for every table, in table coordinates, so **rebuild them whenever a table moves**:

- `<table>-<ramp>`: a brushed aluminum channel loft along the physics spline, with solid coloured outer walls and thin round gold rails 0.008 wide. The interior is 0.088 wide to clear the 0.06834-diameter ball. Edited curves export directly as sampled physics paths, with no additional smoothing. The walls carry on past the mouth as a smooth funnel over a brushed gold floor, and the exit ends over a crossbar. Ramps float, with no pillars. The entire exported ramp must stay below 6,000 triangles.
- `mech-stud`, `mech-tower`: standing mechanisms. Give a table's `posts` entry a `model` to draw one, so the ball bounces off it instead of passing through.
- `<table>-flipper`: an ivory bat in a black rubber edge, with a lit inset and brass pivot, in that table's proportions.
- `<table>-walls`: thick pieces rising 0.03 out of the board, with round ends, a gold trim and the skin's wall colour, drawn at their collider's radius so the ball meets what it sees. Walls that meet are one wall with one path, so they merge into a single piece. To thicken one, grow it away from its ball lane by moving its centre line: lanes must clear the 0.06834 ball diameter with a little margin, and narrower ones become traps.
- `<table>-plastics`: slingshots (rounded blocks with a coloured base and top, a cream band, an inset cream line and three screws) and housings.

Every part is a prefab in `Scenes/kit.xml`: shapes with modifiers ([SCENES.md](SCENES.md)). The compiler groups triangles by material
role, and `PBTableScene` binds `metal`, `accent`, `rubber`, `enamel`, `dark`, `ramp_floor`, `lens`, `glow`,
`glow_amber`, `jewel`, `sling_lens`, `cap_art`, `wall_art`, `block_art`, `flipper_art` and `target_art` to the selected skin.
`Art/Models/manifest.json` records each model's real radius; `PinballCoreTests` checks the overlap test's
footprints still cover them, and that every decor model and ramp used by the table exists.

`modelKit: "premium"` in a skin palette selects these meshes. Skins without a kit keep procedural hardware.

## Metal

Gold and steel use a MatCap (sphere map) from `GameData/Materials`, rendered once from CC0 studio rooms and
checked in. A skin picks one for hardware (`materials.matcap`) and one for ramps (`materials.rampMatcap`), and tints them. The shader looks it up by the surface normal in a fixed room. Phone tilt does not rotate lights or reflections. The material uses Blinn lighting, so local bumper, slingshot and flasher lights illuminate nearby metal and the key light casts shadows. The satin channel floor keeps a broad silver base plus softer moving reflections; only the corners and rail caps are rounded. Molded guide housings use `cabinet_shell`; their inset strips use `guide_glow`.
Nothing thinner than about 0.004 table widths: it is finer than a pixel on a phone, and aliases. Only ramp brackets, slingshots and flippers carry bolts.

### Return-lane guide covers

Closed `style="rail"` guides preserve their outer plan and collision outline, but are open
assemblies: two 0.0035-thick plates with top surfaces at 50% and 100% of `height`, supported by
three hollow screw tubes. Plate undersides are closed with downward-facing normals. There is
no continuous block filling the gap. Tube rims project 0.0075 above the upper plate, with dark
recesses so all three read as hardware and cast their own shadows.

Orbital uses uninterrupted teal upper covers, champagne bevels and tube rims, ivory face/frame,
and red lower edges/fastener surrounds. Colour separation keeps both guides
readable, while the gap and plate/tube shadows reveal their actual construction.

`guide-plate`, `guide-tube`, `guide-cover` and `guide-socket` in `Scenes/kit.xml`
author the assembly. All pieces stay within the existing footprint. Separate `guide_body`,
`guide_edge`, `guide_face`, `guide_inlay`, `guide_mark` and `guide_tube` roles define the finish.
`PBSkin` reads `guideBody`, `guideFace`, `guideEdge`, `guideInlay`
and `guideMark` colours, with defaults for other skins. The renderer uses Blinn paint with restrained
specular and a small colour fill, receiving local glow without a MatCap surface modifier.

Real examples: the [Toy Story 4 return-lane assembly](https://marketing.jerseyjackpinball.com/ts/Toy_Story_4_Manual_1_3_July_2023.pdf)
combines a plate, spacers and separate plastic; [Dialed In coloured protectors](https://www.pinballlife.com/PBL-300-0118-00)
show a coloured layer used around return guides. These are construction references, not copied art.
World previews export `lower-lanes-equal.png` and `lower-guides-fill-only.png`; the latter disables
the directional key to verify that colour separation survives without its highlights.
`lower-hardware-isometry.png` exposes the plate gap and tubes. Scene regressions verify both
plate elevations, exactly three connected tube components, and unchanged lane footprint.

### Flipper pivot

The flipper has one small, flat centre detail with a plain, unslotted cap at the physical hinge. Its dark washer and
warm cap use `pivot_ink`/`pivot_cap` paint instead of a domed MatCap, giving a clear silhouette and
a real cast shadow. Cap radius is one quarter of the flipper base radius. The large hub and the
bolt at the tip are removed. `flipper-pivot-detail.png` checks the flat top, contrast, centring,
shadow and clean tip in an actual oblique render; no flipper physics dimensions change.

### Slingshots

Slingshot fastener centres coincide with the centres of the .014-radius rounded corner arcs,
including the acute upper corner. The body and inset trim share those arc centres. The top is one
level face at .037, with upright normals and uniform colour; it has no painted radial lens shading
that could make it look domed. The real-scene preview exports `plasticSlingL-isometry.png` and
`plasticSlingR-isometry.png` with an orthographic camera equally offset on all three axes.
Slingshot flares and local glow anchor to the triangle's area centroid, not the midpoint of the
collision edge. The elevated flare light compensates for the camera tilt so its specular spot
lands on that centroid. Real-hit previews export peak/decay frames as `slingshot-flare-*.png`.

## Ball

The ball is warm coral-orange opaque, uncoated moulded rubber. Its PBR settings are metalness 0,
roughness 0.68 and clear coat 0. The previous resin setup (roughness 0.30, clear coat 0.35) made a
small lacquer sparkle; the rubber now has a broad, muted satin highlight. A deterministic 512×256
linear normal map adds fine mould grain at intensity 0.18, with periodic longitude, softened poles
and trilinear mip filtering. It is generated once in memory, follows the ball's UVs/rolling, and is
shared by all balls; no downloaded assets, baked lighting or extra render passes.

These are scene-tuned settings following [the Principled PBR roughness/coating model](https://docs.blender.org/manual/en/3.4/render/shader_nodes/shader/principled.html)
and [SceneKit's physically based material model](https://developer.apple.com/documentation/scenekit/scnmaterial/lightingmodel-swift.struct/physicallybased). It receives normal scene lighting; the old chrome shader that copied the playfield onto
the ball is removed. Mesh and solver share the authored radius 0.03417, equal to the previous
visible .03 × 1.34 radius reduced by 15%. There is no mesh-only enlargement or static centre lift.
Material changes do not alter mass or bounce tuning.

`PBSoftBall` adds contact-driven elastic deformation to the mesh. Real solver contacts with walls,
flippers, bumpers/slings, other balls, the plunger and landings excite a damped matrix spring at
960 Hz. The normal controls compression, impact speed controls its strength, and both transverse
axes bulge. The transform preserves volume and stays bounded under rapid/oblique contacts.
Compression remains readable for roughly 0.10–0.14 seconds, followed by a small stretch overshoot.
The spring uses omega 20, damping 12, and stronger response to moderate hits. Previously it had
nearly recovered within 50 ms; an enlarged 4× slow-motion capture hid that readability problem.
Tiny resting contacts do not keep it wobbling.
Serving/repositioning resets the shape. Deformation itself does not alter the shared spherical
collision radius, restitution or mass; the strain is passive presentation state.

`PBTableScene` applies the elastic transform before rolling rotation so the contact axis stays in
world space. It offsets the contact face and supports the deformed underside on the floor. This
changes actual geometry, lighting and the existing 4096×2048 shadows, with no extra render pass.
`PBSoftBallTests` cover volume, oblique contacts, recovery at different rates, rapid hits, invalid
input and production wall/flipper/ball contacts. A regression test samples complete live-game
frames at 30/60/120 Hz; the UI checker also verifies five consecutive 60 Hz mesh transforms.

Verify at normal speed and gameplay size first:

```bash
tools/render_preview.sh /tmp/pinball-soft-ball orbital --ball-realtime
```

This produces `ball-realtime.gif` (full gameplay framing), `ball-realtime-closeup.gif`, and a
gameplay-size impact still. Both GIFs use the regular `PBGame update:` + scene sync path, with
0.02-second simulation and playback intervals (50 Hz, matching GIF centisecond timing exactly).
They do not slow time or inject deformation; the original shooter wall supplies the collision.

Render a real collision with the existing shooter wall at 4× slow motion:

```bash
tools/render_preview.sh /tmp/pinball-soft-ball orbital --ball-deformation
```

The slow-motion preview writes `ball-deformation.gif`, four phase PNGs, and before/rubber material comparisons
with identical geometry, camera and lighting. It checks that the ball stays in
frame throughout compression, recoil and recovery. It adds no board mechanisms or fixture walls.

## Shooter gate

Gate passage uses the permitted **segment normal**, selected by `passDirection`, rather than
checking the sign of the ball's vertical velocity. Admission is latched per ball until its whole
body clears the gate sweep; a weak shot can turn and roll back without a collider appearing inside
it. The door rotates in the table plane around endpoint `a`, fixed at the shooter wall.
A visible bearing marks the hinge. The free end swings into the playfield and returns under a
damped spring to mechanical stops. The bar never rises or translates away from its hinge.
A fully closed door blocks reverse entry; a ball in the returning door's sweep holds it open.
Airborne balls above the bar do not actuate it.

`PBGateGeometry` shares wire radius, fixed bar height, opening sign and rotating endpoint with the
mesh. The collider uses the actual hinge-to-tip segment; the broad-phase grid includes its whole
rotational envelope. The capsule's centreline matches this segment, including its end caps.
`gateAngle:` returns the actual rotation in radians directly.

```bash
tools/render_preview.sh /tmp/pinball-gate orbital --gate-physics
```

This exports `shooter-gate.gif` from a real full-power plunge and checks the fixed hinge, constant
height, visible angular rotation, free-end/collider alignment and return to the closed stop. Regression tests also cover diagonal reverse
approaches, forward passage with a negative vertical velocity and weak-shot rollback.

## Glow

Solid walls and apron floors (`cabinet_shell`) use an opaque skin colour and real lighting. Do not project playfield artwork onto their tops: that made the old purple slabs appear transparent. The surrounding cabinet has been removed; its thin board boundary is drawn in the 2D UI.

Glowing parts light what is around them and put a rim on it: bumper jewels, slingshot lenses, lit lamps, ramp arrows and flashers, each with a colour, range and strength that follow its state in `updateGlowWithWorld:`. The 16 brightest go to the shader as one block each frame, as SceneKit lights are too costly for every lamp and have no rim. A material takes part through `receiveGlow:`. The playfield reads them alongside its artwork in its surface modifier. The field is matte on every level: planar reflections of the ball and hardware are disabled. Constant-lit parts such as jewels and lamp sprites, and painted bumper caps, stay out, so they keep their colour.

## Smooth ramps

`python3 tools/ramp_paths.py` checks every ramp's centre line and rail edges for folds, facets and curvature jumps,
and how far legacy mesh paths stray from the ball's path. A ramp's points are used directly by both mesh and physics. `make scenes` runs the same checks and refuses a ramp that fails.
The channel mesh merges nearly straight rings within 0.00012 table widths at both rail edges, retaining dense samples around bends. The floor remains planar across its width. The compiler also checks that the larger ball clears the visible rail walls along the relaxed path. Keep ramp details readable: anything much under 0.004 table widths is finer than a pixel on a phone, and aliases.

## Comparing with the concept

The camera is orthographic and leans 20° from overhead toward the flipper end (`PBTableCameraTilt`), so walls, flippers and ramp sides show their height without perspective growth. `PBTablePresentation` frames the board below the safe-area-aware HUD; the background continues behind the 2D UI.

Judge the look on a real scene render, which takes seconds, with side-by-side crops per board area:

```bash
tools/render_preview.sh /tmp/pinball-game orbital
python3 tools/compare_concept.py /tmp/pinball-game/orbital.png /tmp/pinball-compare orbital
```

Use the standalone `tools/render_preview.sh` to validate imported models, skin crops, bumper
collision → authored hit state → idle, and actual game screenshots. `*-hit.png` previews show the
fixture collision with a real simulated ball. The tool reads `GameData/` directly with no app build.
Physics tests are still run through `PinballCoreTests`.
The preview also exports `*-local-off.png` and `*-local-on.png` with identical geometry, camera and lamp sprites, varying only actual omni lights. Compare hardware pixels to verify coloured illumination, rather than a glow sprite. Actual iPhone GPU performance should be checked on device before shipping.

Lighting stays fixed, including the environment map and MatCap basis. Motion input only supplies
intentional gameplay nudges. The key is a directional light with a single 4096×2048 shadow map,
32 PCF samples and a 4-texel filter radius. The 4096-texel light-space axis is rolled along
the long playfield; the orthographic fit uses the map's 2:1 aspect. Automatic shadow fitting and cascades are disabled.
`PBTableScene` fits an orthographic light-space box to the shared camera's full-screen floor/caster
slab. It measures authored mesh height, reserves ball clearance, extends near depth for offscreen
casters, pads the receiver bounds and snaps the centre to shadow texels. Resize refits the box.
This avoids spreading shadow texels over the oversized background floor or a wide spot cone.
The map is hard-capped at 4096×2048 (32 MiB for 32-bit depth).
Actual allocation and frame time still need profiling on iPhone.

For shadow QA, render the same geometry, light and projection at 2K and 4K, plus a no-shadow frame:

```bash
tools/render_preview.sh /tmp/pinball-shadows orbital --shadow-compare
```

`make ui-check` checks coverage of all screen corners at floor/raised heights on four phone sizes,
explicit near/far bounds, stable repeated layout and absence of the old motion-lighting rig.
The comparison mode additionally places 20 temporary raised spheres across the empty field and
checks the actual rendered floor pixels against a no-shadow frame, verifying GPU coverage for
the rectangular map. Those fixtures never enter the shipping scene or board data.

The design study is
`Art/Concepts/cadet-inspired-redesign.png`; its ImageGen prompt is in `Art/Prompts/cadet-inspired-redesign.txt`.

## Channel finish and lights

The floor is brushed aluminum: `tools/build_brushed.py` paints short streaks along the ramp into `GameData/Materials/brushed-aluminum.png`, which tints the `channel_floor` MatCap. Its normals lean along the path, as brushed metal catches light by the direction of its grain, so the sheen follows each bend in the fixed room. Rails, brackets, columns and arrow bezels use `accent`, so they follow the skin's gold. Inner walls use `channel_liner` and outer walls `channel_shell`.
Entrance and exit triangle inlays are centered on the curve. Their position, dimensions, direction and optional equal-distance repetition are `<authoring>` settings on the ramp.

The older ImageGen `ramp-chase.png` atlas remains available for the previous textured-deck style. Current aluminum
channels use small geometric arrow inlays, leaving the metal exposed. The preview's `*-chase.gif` now shows the
actual lamp animation and larger ball fixture on this design; if a textured-deck model is loaded, it also verifies
all four authored chase groups. No authored state image is recolored or synthesized.

## Artwork sources

The built-in ImageGen tool produced the approved concept (`Art/Concepts/cadet-inspired-redesign.png`),
the two cleaned full-height masters (`Art/Masters/orbital-playfield.png` and
`Art/Masters/abyss-playfield.png`), and the complete glow atlas (`Art/Masters/ramp-chase.png`).
Exact prompts are preserved in `Art/Prompts/cadet-inspired-redesign.txt`,
`Art/Prompts/orbital-playfield-clean.txt`, `Art/Prompts/abyss-playfield-clean.txt`,
and `Art/Prompts/ramp-chase.txt`. Background exports are JPEG compression only; the atlas is
shipped unchanged. Final native animations and screenshots are in `Art/Previews/`:
`orbital-chase.gif`, `abyss-chase.gif`, `orbital-gameplay.png`, `abyss-gameplay.png` and
`channel-detail.png` (the channel geometry under studio lighting).

The Space Cadet sheet is retained as a design reference, not shipped as game artwork.
With the 20% larger ball, the table clearances and flipper gap were widened; the docking
mechanism now needs one lock, launch ball save is 12 seconds, and two late-level goals were
rebalanced. The full headless suite verifies every feature remains reachable, no persistent
traps develop, all level goals are achievable, and three stars are not automatic.
