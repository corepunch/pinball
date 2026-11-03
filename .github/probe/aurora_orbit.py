"""Temporary: aurora right-orbit diagnosis and layout candidates (delete before merge)."""
import json, re, subprocess, sys, shutil
from pathlib import Path
ROOT = Path.cwd()
sys.path.insert(0, 'tools/playtest'); import run_shots
run_shots.build()
xml = ROOT / 'Scenes/tables/aurora.xml'
orig = xml.read_text()
def shots(path):
    return json.loads(subprocess.run([str(run_shots.BINARY), str(path)], capture_output=True, text=True, check=True).stdout)
# Diagnosis: left-flipper shots that head right (heading < 75) on the current layout.
fan = subprocess.run([sys.executable, 'tools/playtest/run_shots.py', '--fan', 'aurora'], capture_output=True, text=True).stdout
print('DIAG left flipper, headings 30-75:')
section = fan.split('flipperR')[0]
for line in section.splitlines():
    m = re.search(r'heading +(\d+)', line)
    if m and 30 <= int(m.group(1)) <= 75: print('DIAG', line.strip())
SB = '<standup id="standB" a="0.71 0.83" b="0.79 0.81" arrow="amber" />'
BB = '<bumper id="bumperB" x="0.74" y="1.2" r="0.068" />'
SP = '<spinner id="spinnerR" a="0.75 0.67" b="0.83 0.67" arrow="cyan" />'
def sb(ax, ay, bx, by): return f'<standup id="standB" a="{ax} {ay}" b="{bx} {by}" arrow="amber" />'
def sp(ax, ay, bx, by): return f'<spinner id="spinnerR" a="{ax} {ay}" b="{bx} {by}" arrow="cyan" />'
def bb(x, y): return f'<bumper id="bumperB" x="{x}" y="{y}" r="0.068" />'
variants = {
    'base': {},
    'sbL08': {SB: sb(.63, .83, .71, .81)},
    'sbUp': {SB: sb(.69, .95, .77, .93)},
    'spUp': {SP: sp(.78, .80, .86, .80)},
    'spUp_sbL08': {SP: sp(.78, .80, .86, .80), SB: sb(.63, .83, .71, .81)},
    'bbL': {BB: bb(.70, 1.22)},
    'bbL_sbL08': {BB: bb(.70, 1.22), SB: sb(.63, .83, .71, .81)},
    'all': {BB: bb(.70, 1.22), SB: sb(.63, .83, .71, .81), SP: sp(.78, .80, .86, .80)},
    'spR': {SP: sp(.80, .70, .88, .70)},
    'spR_sbL08_bbL': {SP: sp(.80, .70, .88, .70), SB: sb(.63, .83, .71, .81), BB: bb(.70, 1.22)},
}
for name, subs in variants.items():
    text = orig
    for a, b in subs.items(): text = text.replace(a, b)
    xml.write_text(text)
    out = Path('/tmp/var') / name
    subprocess.run([sys.executable, 'tools/scene/compile_scenes.py', '--tables-only', '--out', str(out)], check=True, stdout=subprocess.DEVNULL)
    r = shots(out / 'GameData/Tables/aurora.json')
    print('VARIANT', name, ' | '.join(f"{f}: orbitR {fan['reached'].get('orbit right', 0)} orbitL {fan['reached'].get('orbit left', 0)} stand {fan['reached'].get('standups', 0)}" for f, fan in sorted(r.items())))
xml.write_text(orig)
