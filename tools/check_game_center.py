#!/usr/bin/env python3
"""Check checked-in configuration; optionally inspect a signed .app on macOS.
This does not contact Apple and never certifies server-side readiness.
"""
import argparse
import json
import pathlib
import plistlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
BUNDLE = 'com.igorchernakov.pinball'
LEADERBOARD = BUNDLE + '.aurora.highscore'


def require(condition, message):
    if not condition:
        raise SystemExit('FAIL: ' + message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=pathlib.Path, help='signed iPhone .app to inspect')
    args = parser.parse_args()
    config = json.loads((ROOT / 'GameData/GameCenter.json').read_text())
    require(config['leaderboards']['aurora'] == LEADERBOARD, 'Aurora leaderboard ID')
    require(all(isinstance(v, str) and 0 < len(v) <= 100 for v in config['leaderboards'].values()), 'leaderboard IDs')
    ent = plistlib.loads((ROOT / 'Config/Pinball.entitlements').read_bytes())
    require(ent.get('com.apple.developer.game-center') is True, 'Game Center entitlement')
    project = ROOT / 'Pinball.xcodeproj/project.pbxproj'
    before = project.read_bytes()
    subprocess.run(['python3', str(ROOT / 'tools/make_xcodeproj.py')], check=True, stdout=subprocess.DEVNULL)
    require(project.read_bytes() == before, 'generated Xcode project was stale (regenerated; review diff)')
    text = before.decode()
    require(text.count('PRODUCT_BUNDLE_IDENTIFIER = ' + BUNDLE + ';') == 2, 'Debug/Release Bundle ID')
    require(text.count('CODE_SIGN_ENTITLEMENTS = Config/Pinball.entitlements;') == 2, 'Debug/Release entitlements path')
    require('com.apple.GameCenter = {enabled = 1;' in text, 'target capability')
    require(text.count('GameKit, "-framework", SpriteKit, "-framework", Network') == 2, 'framework links')
    require('path = GameData;' in text, 'GameData resource folder')
    print('PASS: repository configuration and reproducible Xcode project')
    if not args.app:
        print('NOT CHECKED: signature, provisioning, Apple configuration, authentication or live scores')
        return
    app = args.app.resolve()
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    require(info.get('CFBundleIdentifier') == BUNDLE, 'built Bundle ID')
    require(info.get('CFBundleSupportedPlatforms') == ['iPhoneOS'], 'physical-device build required')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    result = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(app)], capture_output=True, check=True)
    signed = plistlib.loads(result.stdout)
    profile = plistlib.loads(subprocess.check_output(['security', 'cms', '-D', '-i', str(app / 'embedded.mobileprovision')]))
    allowed = profile['Entitlements']
    for source in (signed, allowed):
        require(source.get('com.apple.developer.game-center') is True, 'signed/profile Game Center entitlement')
        require(source.get('application-identifier', '').endswith('.' + BUNDLE), 'explicit signed/profile App ID')
    require(signed['application-identifier'] == allowed['application-identifier'], 'signature/profile App ID match')
    require(signed.get('com.apple.developer.team-identifier') in profile['TeamIdentifier'], 'profile Team ID match')
    import datetime
    require(profile['ExpirationDate'] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), 'unexpired provisioning profile')
    bundled = json.loads((app / 'GameData/GameCenter.json').read_text())
    require(bundled == config, 'bundled Game Center mapping')
    print('PASS: device app signature, App ID, entitlement, provisioning and bundled IDs')
    print('NOT CHECKED: App Store Connect, authentication or live server submission')


if __name__ == '__main__':
    main()
