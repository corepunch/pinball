# Pinball elements and campaign progression

This guide lists the parts a classic pinball table is built from: what each does, how it is played,
and whether this game supports it today. The campaign introduces them gradually, as puzzle games
such as Cut the Rope do. Each level teaches one or two new elements, makes them its goal, and keeps
every element taught before it. The reference was an annotated components diagram of a 1990s
video-pinball table. Its parts are described here generically; that table's names, theme and
layout are not reproduced.

Status: **have** = physics, rules and sprite exist; **engine** = physics/rules exist, but the part
has no sprite and has not been used in a shipped level; **need** = not built.

## Lower kit (every level)

| Element | What it does | Status |
| --- | --- | --- |
| Flippers | The player's only controls; the ball's screen half chooses a flipper | have |
| Plunger and shooter lane | Charge-and-release launch up the right side; a one-way gate closes behind the ball | have |
| Slingshots | Rounded triangles above the flippers; the long rubber face kicks the ball across | have |
| Inlanes / return lanes | Feed the ball back onto a flipper; a rollover in each lights a bonus | have |
| Outlanes | Drain risks outside the inlanes; a rollover in each scores the loss | have |
| Centre drain | The gap between the flippers | have |
| Ball save / shoot again | A short grace period after launch, shown by the shoot-again lamp | have |
| Tilt | Warnings, then the ball and bonus are lost | have (rules) |

## Playfield elements

| Element | What it does | How it plays | Status |
| --- | --- | --- | --- |
| Pop bumpers | Round kickers that fire the ball away when touched | Chaotic, high-tempo scoring in a cluster | have |
| Top rollover lanes | Two to four lanes at the top, each with a lamp; lighting all of them raises the bonus multiplier, and the flippers rotate the lit lamps | Aim skill and launch strength; a skill-shot target | have |
| Stand-up targets | Fixed targets scored when hit; a set completes a group | Precise single shots | have |
| Drop-target bank | Targets fall when hit; clearing the bank scores and resets it | Several shots at one area; progress is visible | have |
| Spinner | A flag on an axle in a lane that spins and scores per turn | Rewards a clean, fast shot through a lane | have |
| Orbit / loop | A lane up one side and over the top, often fed by a spinner | Flowing shot; the ball returns to the other flipper | have (needs side guides to be reliable) |
| Kickout scoop / saucer | Catches the ball, holds it, then ejects it toward a flipper | Precision shot with a pause and a safe return | have |
| Hole with an underground exit (teleport) | The ball drops in one hole and comes up at another | Surprise routing; connects two areas | engine |
| Outlane kickback | A plunger in an outlane, lit by a target, that kicks the ball back into play | Earned drain protection | have (Undertow) |
| Centre post / stopper | A post between the flippers that rises for a while when earned | Temporary centre-drain protection | engine |
| Magnet (gravity well) | Grabs a passing ball, holds it, then releases or flings it | Disrupts routes; can be a timed feature | engine |
| Captive ball | A ball held in a short lane; hitting it drives it into a target | Strong, readable shot with a visible result | engine |
| Rebound posts / rubbers | Small rubber posts and bands that redirect the ball | Shape lanes and angles | have (posts) |
| One-way gates and chutes | Let the ball through one way only, such as an exit chute | Route control | have (gates) |
| Lamps and light ladders | Show progress, lit shots, ranks and extra balls; real lights only | Tell the player what to shoot | have |
| Ramps | Raised lanes to a second level | Flow and height | deferred: needs solid, height-aware collision first |

## Rules and modes

| Rule | What it does | Status |
| --- | --- | --- |
| Bonus and bonus multiplier | Lanes and groups add bonus; lanes raise the multiplier; awarded at drain | have |
| Playfield multiplier | Doubles all scoring for a while after a target | engine (`playfieldX`) |
| Skill shot | A lit lane or target scores big if hit straight from the plunger | have |
| Hurry-up | A shot that counts down in value until made | engine |
| Mystery award | A random reward from a scoop or target | engine |
| Extra ball / special | Earned extra ball, or a large special score | have (rules) |
| Multiball and locks | Lock balls, then play several at once | engine (deliberately off in the campaign so far) |
| Missions and ranks | Accept a mission at a scoop, complete its shots, rank up | need |
| Wizard mode | A final mode after every mission | engine (`wizard`); missions needed |

## Progression

Each level adds only what it introduces. Its goal is the new element, so the player learns it by
using it, and the score stars reward everything learned so far. Later levels reuse and combine
earlier elements rather than adding several unfamiliar parts at once.

| Level | Introduces | Goal | Keeps |
| --- | --- | --- | --- |
| 1 First Light | Pop bumpers, top lanes, stand-up targets (a pair and a bank of three), both orbits | Bumper hits | Lower kit |
| 2 Crosswind | Drop-target bank, spinner on an orbit | Drop targets | Level 1 |
| 3 Undertow | Kickout scoop, left-outlane kickback lit by both stand-ups | Scoop captures | Levels 1–2 |
| 4 | Magnet | Magnet grabs | Earlier elements |
| 5 | Teleport holes | Hole entries | Earlier elements |
| 6 | Captive ball, centre post | Captive hits | Earlier elements |
| 7 | Locks and two-ball multiball | Jackpots | Earlier elements |
| 8 | Hurry-ups, playfield multiplier | Hurry-ups collected | Earlier elements |
| 9+ | Missions, then a wizard mode; ramps once their collision is solid | Missions | Everything |

Levels 1–3 ship now; each intro card names what it introduces (`introduces` in
`GameData/Levels.json`), and `tools/scene/test_scenes.py` enforces that no level uses an element
before it is introduced. Levels 4 and later list the order; each needs its element's sprite and a
layout built and checked as `docs/campaign.md` describes.

## What each new element needs

- A **sprite drawn from its collider** in `App/UI/PBTableSprites.m`. Magnets, captive balls,
  stoppers and teleport holes are not drawn yet.
- A **readable introduction:** the first table that uses it gives it a clear, unobstructed shot,
  its lamp shows when it is lit, and the level's goal counts it.
- **Contracts** in `GameData/Analysis/<table>.json`: a real flipper shot reaches it and the ball
  returns to a flipper, plus the shot playtest (`make shots`) and route coverage.
