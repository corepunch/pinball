# Three compact whitewood levels

The campaign uses the schematic SpriteKit artwork so dimensions remain quick to edit. Each level
has its own physical layout, inherited from [base.xml](../Scenes/base.xml): 1.0 × 1.6 board,
0.03417 ball radius, 0.068 bumper radius, 0.085 drop faces and 0.08125 clear straight lanes.
The lower kit and physics profile are shared. All three stay on one plane, with catch-and-release
scoops and no lock, multiball, ramps or extra flippers.

| Level / source | Main choices and rhythm | Goal / score stars |
| --- | --- | --- |
| First Light / [Aurora](../Scenes/tables/aurora.xml) | Upper-right three-pop burst, left drop bank and scoop, right spinner. Broad introduction to scoring. See [the detailed shot plan](aurora.md). | 36,000 points; 90,000 / 150,000 |
| Crosswind / [Meridian](../Scenes/tables/meridian.xml) | Two upper-left pops leave a different aiming fan toward three staggered right drops. The low-left spinner leads toward the scoop and upper lanes. Collect the bank twice. | 6 drop hits; 92,000 / 130,000 |
| Undertow / [Tide](../Scenes/tables/tide.xml) | Central staggered pops, a spaced left bank, left-flank/right spinners and a right scoop. Choose between side passes, collection and a deliberate pause. | 13 spinner events; 88,000 / 150,000 |

Spinner progress counts production spinner events, not unique completed passes. Drop progress
counts individual hits; the bank resets after completion. Stars and unlocks use stable `l01/l02/l03`
IDs. All three currently use the Orbital palette and simple shape artwork. Only Aurora currently
has a configured remote Game Center leaderboard; all three retain local score/star progress.

## Shot and return contracts

| Layout | Feeds and success | Return and next choice | Miss / risk |
| --- | --- | --- | --- |
| Meridian right bank | Measured lower-flipper shots hit each angled drop separately; all three complete the bonus/reset group. | Upper two measured routes descend into the right-flipper feed; the lower target route reaches the left feed. | Raised targets deflect; dropped targets open travel. Unplayed lower feeds must drain cleanly. |
| Meridian left zone | Flipper routes reach both pops, spinner, stand-ups and scoop. Three top lanes exit their compact dividers. | Scoop pauses for 1.1 seconds and ejects down/right; pop/stand-up routes have measured descending feeds on both sides. | Off-centre scoop shots continue; shots above capture speed are not held. No closed pop pocket. |
| Tide collection and side passes | Real-flipper routes reach each left drop, both spinners, both stand-ups and all three pops. | Different routes reach left/right descending feed boxes; the open lower centre permits the next cross-field shot. | Narrow timing/approach choices remain live rebounds; a feed box is not proof that a player can catch the ball. |
| Tide right scoop and top lanes | A flipper shot enters `scoopR`; separate lane probes cross each bar then leave the dividers. | Scoop ejects down/left; its automatic release is checked through normal game updates. | The scoop is a precision alternative, not a mandatory choke point. A failed lower feed has an explicit drain contract. |

[Meridian contracts](../GameData/Analysis/meridian.json) and
[Tide contracts](../GameData/Analysis/tide.json) check ordered real-flipper contact → device events,
descending feed boxes, all three local lane exits, and unplayed feeds draining without a stuck ball.
Device routes use two seeds; geometry is deterministic for many of those fixtures, so the seeds
are not independent evidence of broad timing windows. Some fixtures explicitly eject the scoop at
2 seconds to let subsequent returns finish; the dedicated scoop route uses capture + 1.1 seconds.
XCTest separately checks automatic scoop timing, one capture/eject without immediate recapture,
and bank scoring/reset over two rounds on every campaign table.

## Repeatable authoring loop

1. Write the shot's purpose, feed, successful event sequence, return, next shot and miss before
   placing a part. Reserve the full ball diameter through the aiming fan. Keep unused space quiet.
2. Edit table XML above the shared lower kit. Move parts or angles to solve blocked shots; keep
   ball size, gravity and flipper power fixed. Recompile with `make scenes`.
3. Run `make spacing` and `make shots TABLES='aurora meridian tide'`. Visual spacing is distinct
   from physical clearance; the native validator catches additional lamp/solid and boundary issues.
4. Probe production physics with `make analysis TABLE=<id>` and `tools/playtest/run_shots.py --fan
   <id>`. Save useful initial positions, velocities and controls as ordered scenarios in
   `GameData/Analysis/<id>.json`. Include weak/unplayed feeds, reset states and returns; require
   `stuckAtMost: 0` for accepted fixtures. Run the suite with `--strict` before accepting it.
   After a deliberate lower-kit geometry change, `python3 tools/rerecord_contracts.py <id> --write`
   re-finds flipper starts for scenarios that no longer meet their own thresholds. It searches the
   shot playtest's start grid and keeps the events, return box, seeds and thresholds; a scenario
   it cannot satisfy stays failing, which means the layout must change.
5. Run `make playtest PLAYTEST='--games 60'` for every layout. Inspect per-device coverage, traps,
   game duration and goal completion. Use `--tune` only when intentionally changing goals/stars.
   A bot's coverage is useful evidence, not a substitute for aiming and playing by hand.
6. Run `make test`, then `make iphone` sequentially. Export the new shape atlases with `make
   sprites TABLE=<id>`, inspect real software board captures at phone size and normal-speed motion,
   then play on an iPhone before treating feel and final difficulty as accepted.

The implementation sample used 60 completed autopilot games per table: goals met in 95% / 83% /
52% of games, no reported stuck balls, no uncovered devices and no native layout issues. Median
scores were approximately 83,100 / 84,700 / 80,400. These measurements calibrate initial goals;
they do not establish human difficulty or enjoyment. Preserve manual-play observations when tuning.

The broader [level-design methodology](level-design-workflow.ru.md) explains shot passports,
timing sweeps and experimental comparisons; historical ramp/deck examples there are not current
campaign requirements. [Sprite export](../Art/SPRITES.md) describes the compact PNG workflow.
