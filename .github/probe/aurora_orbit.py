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
SA = '<standup id="standA" a="0.51 0.81" b="0.59 0.83" arrow="amber" />'
SB = '<standup id="standB" a="0.63 0.83" b="0.71 0.81" arrow="amber" />'
def sa(ax, bx): return f'<standup id="standA" a="{ax} 0.81" b="{bx} 0.83" arrow="amber" />'
def sb(ax, bx, ay=.83, by=.81): return f'<standup id="standB" a="{ax} {ay}" b="{bx} {by}" arrow="amber" />'
variants = {
    'current': {},
    'sb68': {SB: sb(.68, .76)},
    'sb675': {SB: sb(.675, .755)},
    'sa46_sb63': {SA: sa(.46, .54)},
    'sa46_sb64': {SA: sa(.46, .54), SB: sb(.64, .72)},
    'sa45_sb65': {SA: sa(.45, .53), SB: sb(.65, .73)},
    'sa47_sb66': {SA: sa(.47, .55), SB: sb(.66, .74)},
    'sbHigh': {SB: sb(.64, .72, .95, .93)},
}
suite = {'scenarios': [{'id': 'probe', 'mode': 'fixture', 'position': [0.5, 1.0], 'velocity': [0, 0], 'seconds': 0.1, 'seeds': [1]}]}
Path('/tmp/probe-suite.json').write_text(json.dumps(suite))
for name, subs in variants.items():
    text = orig
    for a, b in subs.items(): text = text.replace(a, b)
    xml.write_text(text)
    out = Path('/tmp/var') / name
    subprocess.run([sys.executable, 'tools/scene/compile_scenes.py', '--tables-only', '--out', str(out)], check=True, stdout=subprocess.DEVNULL)
    table = out / 'GameData/Tables/aurora.json'
    r = shots(table)
    subprocess.run([sys.executable, 'tools/analyze_table.py', str(table), '--suite', '/tmp/probe-suite.json', '--out', f'/tmp/rep-{name}'], capture_output=True)
    issues = json.loads(Path(f'/tmp/rep-{name}/report.json').read_text())['layoutIssues']
    print('VARIANT', name, ' | '.join(f"{f}: orbitR {fan['reached'].get('orbit right', 0)} stand {fan['reached'].get('standups', 0)}" for f, fan in sorted(r.items())), '| issues', json.dumps(issues))
xml.write_text(orig)
