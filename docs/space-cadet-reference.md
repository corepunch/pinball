# Space Cadet: measured layout and scripted behavior

Inspected 2026-11-02 using `vpxtool 0.38.0`. This is **JP's Space Cadet v4.3 for
VPX 10.7**, a recreation based on the 1996 PC game, not the original Windows engine.
Use it to study proportions and interactions. These are observations and proposals,
not new requirements for our shared board.

## Evidence and reproduction

The local source is `reference/JP's Space Cadet v4.3.vpx`, SHA-256
`e7a37b9da3401ede7d5560782796e3d601b10b9f87550dca17a6d6fdcbc6b5dc`.
The reference directory is ignored by git; the measurements here survive without it.
From the repository root:

```sh
vpxtool extract \
  --only gamedata.json \
  --only 'gameitems/*.json' \
  --only script.vbs \
  --output-dir reference/space-cadet-extracted \
  "reference/JP's Space Cadet v4.3.vpx"
```

Extraction produced 617 element JSON files, `gamedata.json`, and a 5,493-line
`script.vbs`, about 2 MB altogether. Images, sounds, and meshes were not extracted.
Below, element names identify files under `reference/space-cadet-extracted/gameitems/`;
script routine names and line numbers identify this exact script version.

The checks were static JSON measurements and script tracing. No VPX simulation,
replay, or rendered trajectory was run. Curved collision boundaries, mesh collisions,
and the precise flipper/rubber collision envelope need engine verification before
using them as clearance specifications. Six primitives have collision enabled;
their meshes were not evaluated. In particular, do not infer that all 617 elements
are independent gameplay mechanisms: many are lights, visual pieces, or helpers.

## Distances: use ball diameters for clearances

The script explicitly sets `BallSize = 50` and creates balls with radius 25
(`CreateNewBall`, line 997). Write **D** for one physical ball diameter.
The VPX bounds are x = 0..952, y = 0..1974, with y increasing down-table.
Our diameter is 0.06834 and y increases up-table.

| Quantity | This VPX | Our current shared base | Interpretation |
| --- | --- | --- | --- |
| Width in ball diameters | 19.04 D | 14.63 D | Our ball is 30.1% larger relative to board width |
| Authored bounds, height/width | 2.074 | 1.900 nominal | Our fitted display boundary extends beyond the nominal top; these are authored bounds, not equivalent visible heights |
| Main flipper pivot separation | 293.672 VP = 5.873 D | 0.369 = 5.399 D | Compare reach and drain clearance separately before changing a gap |
| Main flipper length parameter | 114.7 VP = 2.294 D | 0.150 = 2.195 D | Similar ball-relative reach; parameter semantics still need collision-envelope verification |
| Left/right angular travel | 53 degrees each | 53 degrees each | The sweep already agrees |
| Main flipper-pair axis / table width | 0.51817 | 0.457 | This recreation's pair is slightly right of table centre; ours follows our different lower lane layout |
| Straight shooter lane, face to face | 57 VP = 1.140 D | 0.070 = 1.024 D at the reference viewport | Our shooter has substantially less lateral clearance |
| Four straight lower channels | See five-channel layout below | 0.08125 = 1.189 D each | Our equal-width standard is already a reasonable, more forgiving reference |

For position studies use `x = X/952`, `y = (1974-Y)/952`. This preserves VPX's
aspect ratio, not ours. For a clearance of `g` VP units, preserve ball-relative
size with `g/50 * 0.06834`. These two scales serve different purposes: scaling
everything by board width would make this reference's shooter lane too small for
our larger relative ball.

### Straight lower lanes

At VPX y = 1424, intersect the **collidable wall polygon faces**, not centre lines
or decorative rubber meshes. Horizontal clear widths, from left to right:

| Channel | Left boundary's right face | Right boundary's left face | Clear VP units | D |
| --- | --- | --- | --- | --- |
| Left outlane | `Wall5`: 43.799 | `Wall060`: 107.217 | 63.418 | 1.268 |
| Left outer inlane, refuel/bonus | `Wall060`: 113.770 | `Wall059`: 180.141 | 66.371 | 1.327 |
| Left inner inlane | `Wall059`: 186.694 | `rlband001`: 236.792 | 50.099 | 1.002 |
| Right inlane | `rlband002`: 745.018 | `Wall057`: 796.111 | 51.093 | 1.022 |
| Right outlane | `Wall057`: 802.664 | `Wall1`: 857.569 | 54.905 | 1.098 |
| Shooter | `Wall1`: 867.000 | `Wall5`: 924.000 | 57.000 | 1.140 |

Each relevant wall segment at this section is straight and unsmoothed. Face
positions use linear interpolation between its authored vertices. These are
cross-section measurements, not minimum clearances over a complete curved route.

There are **three inlanes and two outlanes**, not our two-and-two arrangement.
`Trigger001..005_Hit` (lines 3259–3330) identifies their roles. That extra left
channel is one reason the lower layout differs. Do not move our approved axis
to match a table-centre measurement from this recreation.

The VPX shooter ratio would correspond to **0.07791** in our units, about 11.3%
wider than our present 0.070. That is a useful experiment target, not an approved
change. Preserve the four lower channels, complete board framing, and the fixed
ball radius if evaluating a wider shooter later.

For our width, `shooterInner`'s physical face is `0.922 + 0.008 = 0.930` and the
fitted display wall's inner face is x = 1 at the 402 × 874 reference viewport.
`PBTablePresentation` and `testLaunchLaneClearsPhysicalBall` own that fit; different
viewport framing must be measured through the shared production projection.

## Compact top-lane group

`Trigger006/007/008` mark three top lanes, with centres approximately x = 434.8, 504.0,
571.6 and y = 257.5. Two internal separator assemblies sit around x = 467.9 and 538.7:
`rpin001/002` and `rpin004/005` span y ≈ 225.5..295.8. Their short, paired structure is a
better reference for a readable lane group than four long independent planks. Aurora now uses
two short warm-metal separators with open outer lane mouths; it does not copy these coordinates.

The VPX recreation also explicitly marks `Ramp004` and `Ramp009` collidable, with floors at
50..60 and 115..125 respectively (ball diameter 50). This alone does not prove where the original
Windows game allowed underpasses. It does establish that visual overlap is not a reason to let
balls cross solid ramp geometry. Aurora currently has no ramp; the solver's height-aware
entrance/side/underside collision behavior must be completed and tested before one returns.

## Launcher: a route with states, sensors, and a reward

### Serving and firing

1. `CreateNewBall` creates a ball at `BallRelease` (837.112, 1717.972), then kicks
   it at direction 90, speed 4 into the shooter area. The ball does not originate
   directly on the plunger tip. Invisible one-way `Gate007`, near (865, 1716),
   sits between that feed point and the shooter rest area.
2. `swPlungerRest_Hit` marks lane occupancy and prepares skill-shot feedback.
   Its sensor centre is (899.795, 1773.401).
3. Manual key-down calls `Plunger.Pullback`; key-up calls `Plunger.Fire`
   (lines 280–283 and 350–353).
4. Leaving the rest sensor starts the ball saver and fuel timers
   (`swPlungerRest_UnHit`, line 1336). Waiting before launch consumes neither.
5. Multiball uses a separate impulse launcher: power 45, full-impulse time 0.25 s,
   random setting 1.5 (`Table1_Init`, line 163). Auto-fire is scheduled 1.5 s
   after the rest sensor reports arrival.
6. `CreateMultiballTimer_Timer` waits while the shooter is occupied. Its configured
   retry interval is 2 s; the first attempt is immediate. This separates serving,
   waiting for space, and launching.

The manual plunger JSON stores stroke 180, pull speed 0.3, fire speed 100,
mechanical strength 85, and momentum transfer 0.7. These are VPX-specific model
parameters, not a 100-VP-units-per-second ball velocity or a 0.25-second manual
charge. Our implementation deliberately uses 0.9 s to full charge, travel 0.07,
and ball speed `4.4 * strength`. Compare resulting launch height, rollback,
repeatability, and gate passage rather than copying those constants.

### Distance-based skill shot

`Trigger018..023_Hit` (lines 3581–3652) update the stored award **only while the
ball travels upward** (`VelY < 0`). Each later sensor replaces the earlier award:

| Sensor | Authored centre (X, Y) | Award stored |
| --- | --- | --- |
| Trigger018 | 906.288, 1166.473 | 15,000 |
| Trigger019 | 903.992, 958.171 | 30,000 |
| Trigger020 | 904.067, 737.873 | 75,000 |
| Trigger021 | 899.072, 519.370 | 30,000 |
| Trigger022 | 865.361, 357.053 | 15,000 |
| Trigger023 | 761.311, 212.217 | 7,500 |

These centres locate authored sensor polygons; they are not exact ball-centre
activation heights. The highest **reward** is in the middle of the route, not at
maximum travel. `Trigger029_Hit`, centred (836.038, 1182.095) in the adjacent return
opening, collects the stored value through `AwardSkillshot` and clears readiness.
The three top re-entry lane handlers also clear readiness if reached first.

`Gate006` crosses the shooter area near (899.116, 1196.628), length 64; `Gate005`
crosses the adjacent opening near (833.066, 1225.013), length 76. Both are
collidable, one-way, and rotated -23 degrees. Their relationship to `Trigger029`
is a useful routing reference. Exact pass directions and return trajectories
still require running the VPX engine; position alone does not prove them.

**Useful adaptation:** a few clearly marked distance zones and a middle sweet
spot can make our existing hold/release launcher meaningful. Our rule engine
supports one timed rollover target; shipped `aurora` uses the centre bonus lane
(`laneB`) as its `skillShotTarget`. This richer distance/return behavior
would require explicit new rule state and directional sensor events.

## Board logic worth studying

| Mechanism | Verified behavior in this script | Useful design pattern |
| --- | --- | --- |
| Launch protection | 20 s saver, armed for a new player ball, started on leaving rest; saved balls are automatically redeployed (`Drain_Hit`, `EnableBallSaver`) | Start protection on actual movement; communicate its expiry. Our 12 s saver and manual saved-ball relaunch are deliberate existing behavior |
| Lane sets | Complete three top lanes to upgrade attack bumpers; complete three raised engine lanes to upgrade engine bumpers; flipper presses rotate both sets of collected lights (`RotateLaneLights`, `CheckWeaponLights`, `CheckEngineLights`) | Reuse a small set of lanes for an understandable collect-and-upgrade loop. Our group system already supports rotation |
| Mission selection | Hit one of three selection targets, then finish the launch ramp to accept; collecting all three selects the fourth mission (`CheckMissionTargets`, `Trigger030_Hit`, `AcceptMission`) | Separate choosing a goal from committing to it, with lit shots showing the next action |
| Early missions | Ramp 3 times; top lanes 3 times; attack bumpers 8 times; or 9 drop targets (`AcceptMission`, Cadet cases) | Teach one type of shot at a time using the same hardware |
| Fuel | Six units, one consumed every 15 s; warning timer at 10 s. Left outer inlane fully refuels; six ramp-side sensors progressively refill to 1..6; zero aborts missions (`StartFuelTimers`, `Trigger012..017_Hit`) | Optional mission timer with opportunities to extend it; full fuel nominally gives 90 s without refilling |
| Reflex shots | Repeat ramp or hyperspace within an 8 s lamp timer for 20,000 extra (`StartReflexRampShot`, `StartReflexHyperShot`) | A visible, short combo window; our ramp combo system already supplies a related pattern |
| Left/right kickbacks | On rest sensor hit, fire after 1.5 s, close the corresponding lane gate after 1.6 s; completing radiation/comet targets reopens that side (`LeftKickerRest_Hit`, `RightKickerRest_Hit`, `CheckRadiationLights`, `CheckCometLights`) | Show protection state, allow one rescue, then require rearming |
| Hyperspace ladder | Repeated entries award 10k, 20k, 20k plus centre post, 50k plus extra-ball availability, then 150k plus gravity magnet; 60 s decay timer (`HyperSpaceHole_Hit`, `HyperExpiredTimer`) | A reusable shot can become progressively valuable without adding more objects |
| Wormholes | Capture/transport is explicit: balls can be destroyed at entry and recreated at the selected exit; exits serialize queued balls 0.5 s apart (`Wormhole1..3_Hit`, `kickWormhole`) | Model hidden transit and release queues explicitly if a future level needs them |
| Rank | Completing early missions awards progress; 17 progress promotes a rank; ranks change mission choices (`CheckMission`, `AddProgress`, `PromoteRank`) | Longer progression can reuse the same shot vocabulary instead of making the board denser |

The table is largely self-scripted: the VBScript makes its own scores, missions,
timers, ball creation and ejection. It loads `core.vbs` and `controller.vbs` for
helpers, including impulse plungers and magnets. Those helper implementations
were not evaluated here, and the script was not executed.

Physics also changes at runtime: the flipper timer replaces the JSON strength
with 5000, drops it to 10% near the start of stroke, and briefly sets elasticity
to zero at the end for live catches. The rolling update contains component-based
speed limiting with `maxvel = 30`. Static JSON values therefore do not fully
describe play feel. They should not be transplanted into our solver.

## Suggested use in this project

1. Keep **ball-relative clearance** as a measuring convention. Our four lower
   channels already have a useful 1.189 D standard. Investigate the tighter
   shooter separately before moving any lower hardware.
2. If launch gameplay is requested, prototype distance zones, a sweet spot,
   directional detection, and collection on return. Keep weak-shot rollback and
   cancellation working. A failed attempt must not duplicate awards or consume
   a new ball.
3. For later populated levels, begin with one simple objective and clear lamps;
   then study rotating lane sets, repeat-shot combos, and rearmable protection.
   Full rank/fuel/multiball rule stacks are optional complexity.
4. If extending multiball, check shooter occupancy and successful ball creation
   before scheduling another serve/fire. Our `addBallAfter:plunge:` currently
   schedules a spawn and an optional fixed-delay auto-plunge without that guard.
5. Keep comparisons behavioral: test occupied-lane serving, weak/full launches,
   direction-sensitive scoring, single awards, saver timing, safe gate return,
   and explicit reset on a new ball. Existing full-launch, rollback, gate,
   interruption, and manual saved-ball tests are relevant starting points.

This review changes no geometry, physics, rules, assets, or current agent policy.
