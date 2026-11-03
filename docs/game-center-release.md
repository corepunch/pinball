# Game Center release verification

Status, 2026-11-01: repository configuration inspected. Live readiness is **not verified**.
The review environment is Linux, without Xcode, signing identities, provisioning profiles or an iPhone.
App Store Connect shows the Apple Account sign-in form; no app or leaderboard record was accessible.
No account-side configuration has been created or changed. Do not infer a missing leaderboard from this.

## Account configuration

Use the same paid Apple Developer team in Xcode, Certificates/Identifiers/Profiles and App Store Connect.
Confirm the explicit App ID `com.igorchernakov.pinball` has Game Center enabled. Automatic signing must
produce a profile permitting `com.apple.developer.game-center = true`; for manual signing regenerate
the profile after enabling the capability. A checked-in entitlement does not establish portal readiness.

Find the app with this exact Bundle ID. Inspect existing leaderboards before creating one:

| Field | Required value |
|---|---|
| Reference name | Aurora High Scores |
| Leaderboard ID | com.igorchernakov.pinball.aurora.highscore |
| Type | Classic |
| Score format | Integer |
| Sort | High to Low |
| Submission | Best Score |
| Localization | At least English; display name Aurora High Scores; suffix point / points |
| Default leaderboard | Aurora High Scores |
| App version | Associate with intended Pinball iOS version and enable Game Center |

Do not set an arbitrary score range that can silently discard valid scores. The leaderboard ID is
permanent. The custom JSON is a runtime mapping, not an Apple GameKit configuration file or a deployment.
Meridian currently has no leaderboard mapping and intentionally does not submit scores.
Confirm the leaderboard is included in the intended review submission before public distribution;
local/development or prerelease success does not establish production availability.

## Automated checks

`make game-center-check` checks mapping, entitlement, both build configurations, capability,
frameworks, resources and reproducibility of the project generator. On macOS, `make test` also runs
score-persistence regressions: failures survive restart, older completions preserve newer scores,
account isolation, A -> B -> A, logout -> login, same-player notifications, invalid/duplicate endings.

`python3 tools/check_game_center.py --app <signed-device.app>` verifies the device platform, signature,
explicit App ID, team, signed and provisioned entitlement, profile expiration and bundled mapping.
It does not contact Apple. XCTest and all signed-app checks remain unexecuted in this environment.
The GameKit UI/network coordinator requires the device scenarios below; outbox tests do not cover it.

## Required signed iPhone / TestFlight scenarios

Record build/version, team, iOS version, date, test account aliases, expected/observed score and evidence.
Use consenting test accounts; do not reset production players or delete scores for testing.

1. Fresh authentication: present Apple's controller, sign in, return to paused game. Complete Aurora
   manually; verify the exact final score via Game Center, relaunch, and confirm the persisted server entry.
2. Cancel authentication: game remains playable, no upload occurs; SCORES explains sign-in in Settings.
   Sign in using Settings, return, verify new games qualify and signed-out games are not attributed.
3. Offline after starting an authenticated game: complete it, confirm queue persists across termination.
   Restore connectivity while the app stays active; confirm automatic upload without finishing another
   game. A fully signed-out offline game is local only. Repeat with a transient Apple service failure;
   retry occurs on the 60-second active-app cadence. Backgrounded uploads wait for foregrounding.
4. With a queued result for A, switch to B. Verify no A score appears on B. Switch back to A and verify
   delivery. Change A -> B -> A and A -> signed out -> A during a live run; that run must not submit.
5. While a lower upload is in flight, finish a higher game. Verify the higher result survives the lower
   acknowledgment and reaches Apple. Submit a lower result afterward; Best Score retains the maximum.
6. Open/close SCORES, cancel sign-in, background/foreground, and return from Settings repeatedly:
   no duplicate modal, no stuck pause, no simulation advancement during absence. Verify score submission
   errors do not prevent gameplay. Check Console for deferred-upload/auth errors when diagnosing failures.
7. Repeat authentication/submission with the intended TestFlight distribution build and verify the
   expected prerelease behavior. After release, verify the production leaderboard with the released build.

## Apple references

- https://developer.apple.com/documentation/gamekit/authenticating-a-player
- https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.game-center
- https://developer.apple.com/help/app-store-connect/reference/game-center/leaderboards/
- https://developer.apple.com/help/app-store-connect/configure-game-center/manage-leaderboards/
- https://developer.apple.com/help/app-store-connect/configure-game-center/manage-an-app-version-for-game-center/
