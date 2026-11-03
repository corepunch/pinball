# First Light — Aurora

The first level. It introduces pop bumpers, rotating bonus lanes and stand-up targets on a
compact 1.0 × 1.6 board: upper-right bumpers, a left bank of three stand-ups, a centre pair and
both orbits. Drop banks, spinners and the scoop arrive on later levels ([progression](elements.md)). The playable field stays on one plane; ramps are deferred. The centre stays open for aiming. Author in [aurora.xml](../Scenes/tables/aurora.xml);
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
| Right orbit | A left-flipper shot passes over the right slingshot and runs up the right side, between `bumperB` and the shooter wall, over the top | Free upper-field travel into the lanes or pops | `standB` sits left of the lane and `bumperB` is set in to keep the channel clear; `make shots` requires at least one real left-flipper shot to complete it |
| Stand-ups `standA/B` | Separate angled faces either side of centre | Angled rebounds into the open lower field | Live rebounds remain risky; human timing and brick-shot difficulty need device play |
| Left bank `standC/D/E` | Three large angled stand-ups give individual collection shots; the right flipper's cross-field shot is the natural one | Measured shots to each target have descending right-flipper feeds | Fixed targets rebound the ball; misses continue into the upper field or the left orbit |

The left bank keeps the angled collection shots of the later drop banks, but as fixed stand-ups,
so the first level teaches aiming at targets before targets that fall. Nothing captures the
ball; the lower kit and physics profile are unchanged.

The top has two short internal separators, each 0.09 long, 0.014 wide and 0.018 high,
with simple readable sprite faces. Their radius is 0.007 and centre spacing 0.09525:
**0.08125 clear width** in the middle lane, with its lamp and owned rollover centred between
physical faces. The outer two lane mouths flare into open field. This compact grouping follows
the Space Cadet reference instead of using four long dark partitions.

## Rules and goal

- Three top lanes raise the bonus multiplier and reset; flipper input rotates their lit state.
  The centre lane is the launch skill-shot target.
- Both stand-ups award a 5,000 completion bonus, add bonus and reset their group.
- The left bank's stand-ups score 500 each; collecting all three awards 7,500 plus bonus and
  resets the bank. Green arrows track its collected targets.
- The shared inlane bonus, three balls and 12-second ball save remain in force.
- The goal is a count of pop-bumper hits, the element this level introduces; score stars reward
  the rest. Thresholds in `GameData/Levels.json` are calibrated with autopilot games
  (`make playtest PLAYTEST=--tune`), pending manual play.

## Regression and acceptance

`make test` includes [aurora.json](../GameData/Analysis/aurora.json): seeded real-flipper
shots require a flipper bumper hit or stand-up hit, followed by a descending
right-flipper feed. Three short top-lane probes require their rollover and a checkpoint below
the separators. These local lane probes end before the subsequent bumper interaction; they
do not assert a complete orbit; `make shots` separately requires a real left-flipper shot to
complete the right orbit. Real-flipper contracts hit each bank stand-up separately.
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
