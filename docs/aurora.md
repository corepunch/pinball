# First Light — Aurora

A flat SpriteKit mini-pinball layout on a compact 1.0 × 1.6 board, with upper-right bumpers, rotating bonus lanes, a left drop bank and
a catch-and-release scoop. The playable field stays on one plane; ramps are deferred. The centre stays open for aiming. Author in [aurora.xml](../Scenes/tables/aurora.xml);
[base.xml](../Scenes/base.xml) still owns the entire lower kit and the physics profile.

The sizing reference is roughly ten match-3 pieces across the screen. Current target length is
8.5% of width, bumper diameter 13.6%, and the coral ball diameter 6.834% (about 1/15). Upper devices
move closer to the lower kit, with drop faces enlarged from 0.055 to 0.085 and bumpers from 0.055
to 0.068 radius. The lower collision assembly and ball radius remain shared with production physics.

## Shot plan

| Shot | Feed and success | Return / next shot | Weak shot or miss |
| --- | --- | --- | --- |
| Upper-right pops | Strong upper-field shot or descending top lane feeds `bumperA/B/C` | Open lower/side exits change the angle and rhythm before returning to the lower field | No captive pocket or mandatory bumper cycle; misses continue through the open upper field |
| Top lanes `laneA/B/C` | Ball crosses one of three upper rollover bars, then exits the separators | Side lanes feed the top bumpers; centre lane feeds the lower bumper | A divider hit deflects the ball; an overshot launch can circulate above the lanes |
| Right spinner `spinnerR` | Shot crosses the axle, continuing up the right side | Free upper-field travel, then lanes/pops or a lower return | No capture, gate or artificial feed guarantee |
| Stand-ups `standA/B` | Separate angled faces in the middle-right | Angled rebounds into the open lower field | Live rebounds remain risky; human timing and brick-shot difficulty need device play |
| Left bank `dropA/B/C` | Three large angled targets above the scoop give individual collection shots | Measured shots to each target have descending right-flipper feeds | Targets drop out of the way until the complete bank resets; misses continue into the upper field |
| Left scoop `scoopL` | Aimed flipper shot or a bank rebound enters the cyan-marked cup | Holds for 1.1 seconds, then ejects down/right toward the right flipper | Off-centre shots pass; shots faster than 5.5 are not captured |

The former ramp used a long strip of the left field for one route, including its entrance and
return. Its replacement uses four compact devices for a collection shot and a separate pause/
return shot, without putting a long barrier across the aiming fan. The scoop uses the existing
capture/eject mechanism, with no lock or multiball. The lower kit and physics profile are unchanged.

The top has two short internal separators, each 0.09 long, 0.014 wide and 0.018 high,
with simple readable sprite faces. Their radius is 0.007 and centre spacing 0.09525:
**0.08125 clear width** in the middle lane, with its lamp and owned rollover centred between
physical faces. The outer two lane mouths flare into open field. This compact grouping follows
the Space Cadet reference instead of using four long dark partitions.

## Rules and goal

- Three top lanes raise the bonus multiplier and reset; flipper input rotates their lit state.
  The centre lane is the launch skill-shot target.
- Both stand-ups award a 5,000 completion bonus, add bonus and reset their group.
- The three drops score 750 each; clearing the bank awards 7,500 plus bonus and raises the
  targets after 0.9 seconds. Green arrows track the bank's collected targets.
- The scoop scores 2,500 and automatically returns the ball; it does not start multiball.
- The shared inlane bonus, three balls and 12-second ball save remain in force.
- The score goal is 36,000; two/three stars require 90,000 / 150,000. These are initial
  thresholds calibrated with 60 autopilot games, pending manual play. The scoop ejection aim was
  adjusted from `0.65 -1` to `0.73 -1` to keep seeds 17/41/73 inside the right-flipper feed. No lock, magnet, upper deck
  or additional flipper is needed for this introductory layout.

## Regression and acceptance

`make test` includes [aurora.json](../GameData/Analysis/aurora.json): seeded real-flipper
shots require a flipper bumper hit or stand-up hit, followed by a descending
right-flipper feed. Three short top-lane probes require their rollover and a checkpoint below
the separators. These local lane probes end before the subsequent bumper interaction; they
do not assert a complete orbit. Real-flipper contracts hit each drop separately; a separate
scoop shot checks capture, explicit fixture ejection and its
right-flipper feed. Fixture ejection is explicit; XCTest uses regular `PBGame` updates to verify
automatic scoop timing, single capture/eject, and bank completion/reset over two rounds.
Scene regressions keep this table ramp-free and verify lane clearance and the pair of compact
dividers. The exploratory playtest independently checks device coverage and trapped balls.

The removed ramp exposed a limitation of the current layered solver: a ball on the main field
ignores ramp rails, including low sections where it cannot physically fit underneath. Before any
future ramp is authored, provide and test solid height-aware entrance/side/underside collisions.
A deliberate underpass needs at least one ball diameter of clear height and readable routing.
The existing ramp mechanism tests remain useful, but do not prove those additional collision cases.

```sh
make scenes
make spacing
make shots
make playtest
CLANG_MODULE_CACHE_PATH="$PWD/Build/ModuleCache.noindex" python3 tools/analyze_table.py \
  GameData/Tables/aurora.json --suite GameData/Analysis/aurora.json \
  --strict --out Build/Analysis/aurora-routes
make test
make iphone
zsh tools/render_ui_preview.sh - /tmp/aurora-ui
```

The suite proves specified mechanical routes, not enjoyment, catchability or broad timing windows.
Software captures of the shipping sprite graph and a normal-speed GIF are produced by the UI
preview. Final feel, GPU presentation and performance still require manual iPhone play.
