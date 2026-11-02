#!/usr/bin/env python3
"""Fast native pinball experiments and dependency-free SVG reports (macOS).

The report functions and schema tests also run on Linux. The physics is always
App/Core, never a Python approximation. --serve retains the compiled native process.
"""
import argparse
from collections import Counter, defaultdict
import hashlib
import html
import json
import math
from pathlib import Path
import platform
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
EVENT_GROUPS = {
    'bumper': 'bumpers', 'sling': 'slingshots', 'drop': 'dropTargets',
    'standup': 'standups', 'rollover': 'rollovers', 'spinner': 'spinners',
    'saucer': 'saucers', 'saucerEject': 'saucers', 'rampEnter': 'ramps',
    'rampComplete': 'ramps', 'rampRollback': 'ramps', 'kickback': 'kickbacks',
    'magnet': 'magnets', 'magnetRelease': 'magnets', 'gate': 'gates',
    'flipperContact': 'flippers', 'flipUp': 'flippers', 'flipDown': 'flippers',
}
EVENTS = set(EVENT_GROUPS) | {'wall', 'drain', 'plunge', 'stuck'}


def number(value, name, low=-100, high=100):
    if isinstance(value, bool) or not isinstance(value, (float, int)) or not math.isfinite(value) or not low <= value <= high:
        raise ValueError(f'{name}: expected finite number in [{low}, {high}]')
    return value


def vector(value, name, size=2):
    if not isinstance(value, list) or len(value) != size:
        raise ValueError(f'{name}: expected {size} numbers')
    for n in value:
        number(n, name)


def expand_suite(suite, table):
    scenarios = suite.get('scenarios')
    if not isinstance(scenarios, list) or not scenarios:
        raise ValueError('scenarios must be a nonempty list')
    ids, trials = set(), []
    for spec in scenarios:
        identifier = spec.get('id')
        if not isinstance(identifier, str) or not identifier or identifier in ids:
            raise ValueError('scenario IDs must be unique nonempty strings')
        ids.add(identifier)
        mode = spec.get('mode', 'fixture')
        if mode not in ('fixture', 'autoplay'):
            raise ValueError(f'{identifier}: unknown mode')
        seconds = number(spec.get('seconds', 8), 'seconds', 1/60, 2400)
        for key, value in spec.get('require', {}).items():
            if key not in ('successesAtLeast', 'returnsAtLeast', 'stuckAtMost') or not isinstance(value, int) or isinstance(value, bool) or value < 0:
                raise ValueError('require: nonnegative integer successesAtLeast, returnsAtLeast, stuckAtMost only')
        if mode == 'fixture':
            vector(spec.get('position'), 'position')
            vector(spec.get('velocity'), 'velocity')
        controls = spec.get('controls', [])
        previous = -1
        for control in controls:
            at = number(control.get('at'), 'control.at', 0, seconds)
            if at < previous:
                raise ValueError('controls must be sorted')
            previous = at
            for key in ('left', 'right'):
                if key in control and not isinstance(control[key], bool):
                    raise ValueError(f'{key} must be boolean')
            if 'eject' in control and control['eject'] not in {x['id'] for x in table.get('saucers', [])}:
                raise ValueError('unknown saucer to eject')
        if mode == 'autoplay' and (controls or any(spec.get(k) for k in ('magnets', 'kickbacks', 'dropsDown'))):
            raise ValueError('autoplay overrides fixture controls and device states')
        for goal in spec.get('expect', []):
            if 'region' in goal:
                vector(goal['region'], 'region', 4)
                x0, y0, x1, y1 = goal['region']
                if x0 >= x1 or y0 >= y1 or goal.get('layer', 'playfield') not in ('playfield', 'ramp'):
                    raise ValueError('invalid region bounds or layer')
                continue
            kind = goal.get('event')
            if kind not in EVENTS:
                raise ValueError(f'unknown expected event: {kind}')
            if 'element' in goal and goal['element'] not in {x['id'] for x in table.get(EVENT_GROUPS.get(kind, ''), [])}:
                raise ValueError(f'unknown {kind} element: {goal["element"]}')
        for key, group in [('magnets', 'magnets'), ('kickbacks', 'kickbacks'), ('dropsDown', 'dropTargets')]:
            if not set(spec.get(key, [])) <= {x['id'] for x in table.get(group, [])}:
                raise ValueError(f'unknown element in {key}')
        if 'returnBox' in spec:
            vector(spec['returnBox'], 'returnBox', 4)
            x0, y0, x1, y1 = spec['returnBox']
            if x0 >= x1 or y0 >= y1 or not spec.get('expect'):
                raise ValueError('returnBox requires ordered bounds and an expected sequence')
        seeds = spec.get('seeds', [1])
        if not isinstance(seeds, list) or not seeds:
            raise ValueError('seeds must be nonempty')
        for seed in seeds:
            number(seed, 'seed', 1, 2**32-1)
            if int(seed) != seed:
                raise ValueError('seed must be integer')
        sweep = spec.get('sweep')
        times = [None]
        if sweep:
            index = sweep.get('control')
            if mode != 'fixture' or not isinstance(index, int) or not 0 <= index < len(controls):
                raise ValueError('sweep.control must reference a fixture control')
            times = sweep.get('at')
            if not isinstance(times, list) or not times:
                raise ValueError('sweep.at must be nonempty')
            for at in times:
                number(at, 'sweep.at', 0, seconds)
        for seed in seeds:
            for at in times:
                trial = json.loads(json.dumps(spec))
                trial.update(mode=mode, seconds=seconds, seed=int(seed), scenario=identifier)
                trial.pop('seeds', None)
                trial.pop('sweep', None)
                if at is not None:
                    trial['controls'][sweep['control']]['at'] = at
                    trial['controls'].sort(key=lambda c: c['at'])
                    trial['timing'] = at
                trial['id'] = f'{identifier}:{len(trials)}'
                trials.append(trial)
    if len(trials) > 4096 or sum(t['seconds'] for t in trials) > 100000:
        raise ValueError('experiment budget exceeded')
    return trials


def wilson(hits, total):
    if not total:
        return None
    p, z = hits/total, 1.96
    den = 1+z*z/total
    mid = (p+z*z/(2*total))/den
    delta = z*math.sqrt(p*(1-p)/total+z*z/(4*total*total))/den
    return [max(0, mid-delta), min(1, mid+delta)]


def summarize(raw, trials):
    grouped = defaultdict(list)
    specs = {t['id']: t for t in trials}
    hits = Counter()
    for run in raw['trials']:
        grouped[specs[run['id']]['scenario']].append(run)
        hits.update((e['event'], e['element']) for e in run['events'])
    groups = {}
    for name, runs in grouped.items():
        counts = Counter(r['status'] for r in runs)
        groups[name] = {'trials': len(runs), 'outcomes': dict(counts),
                        'success95': wilson(counts['success'], len(runs)),
                        'returns': sum(r['returned'] for r in runs),
                        'returnMeasured': any(r['returnMeasured'] for r in runs),
                        'timings': [{'at': specs[r['id']].get('timing'), 'seed': r['seed'], 'status': r['status']} for r in runs]}
    inventory = [dict(item, hits=hits[item['event'], item['element']]) for item in raw['inventory']]
    steps = sum(t['steps'] for t in raw['trials'])
    failures = [f'layout: {len(raw["layoutIssues"])} issues'] if raw.get("layoutIssues") else []
    for name, runs in grouped.items():
        counts = Counter(r['status'] for r in runs)
        if counts['invalid']:
            failures.append(f'{name}: {counts["invalid"]} invalid trials')
        requirements = specs[runs[0]['id']].get('require', {})
        actual = {'successesAtLeast': counts['success'], 'returnsAtLeast': sum(r['returned'] for r in runs), 'stuckAtMost': counts['stuck']}
        for key, target in requirements.items():
            violated = actual[key] > target if key == 'stuckAtMost' else actual[key] < target
            if violated:
                failures.append(f'{name}: {key} requires {target}, observed {actual[key]}')
    return {'version': 1, 'passed': not failures, 'failures': failures, 'layoutIssues': raw.get('layoutIssues', []), 'table': raw['table'], 'scenarios': groups, 'inventory': inventory,
            'wallSeconds': raw['wallSeconds'], 'steps': steps,
            'stepsPerSecond': steps/max(raw['wallSeconds'], 1e-9), 'workers': raw['workers'],
            'sampling': raw['sampling'],
            'warning': 'Fixture success proves local mechanics, not reachable gameplay. Autoplay coverage is sampled evidence, not a guarantee. Return boxes measure descending feeds, not player control. Wilson intervals assume independent trials; correlated timing sweeps are descriptive only.'}


def svg_map(raw, layer, dwell=False):
    width, height = raw['grid'], raw['height']
    cells = defaultdict(lambda: [0, 0.0, 0.0, 0.0])
    for run in raw['trials']:
        for cell, seconds, vx, vy in run['cells']:
            if cell // (width*height) != layer:
                continue
            row = cells[cell % (width*height)]
            row[0] += 1
            row[1] += seconds
            row[2] += vx
            row[3] += vy
    peak = max((v[1] if dwell else v[0] for v in cells.values()), default=1) or 1
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}"><rect width="100%" height="100%" fill="#111c30"/>']
    for cell, row in sorted(cells.items()):
        value = row[1] if dwell else row[0]
        strength = value/peak
        color = f'rgb({int(40+215*strength)},{int(110-60*strength)},{int(180-130*strength)})'
        x, y = cell % width, height-1-cell//width
        label = f'{row[0]} trials; {row[1]:.4f}s; mean v=({row[2]/max(row[1],1e-9):.2f},{row[3]/max(row[1],1e-9):.2f})'
        out.append(f'<rect x="{x}" y="{y}" width="1" height="1" fill="{color}"><title>{label}</title></rect>')
        if row[1] and cell % 5 == 0:
            dx, dy = row[2]/row[1], -row[3]/row[1]
            norm = math.hypot(dx, dy)
            if norm > .1:
                out.append(f'<path d="M{x+.5} {y+.5} l{dx/norm*.45:.3f} {dy/norm*.45:.3f}" stroke="white" stroke-width=".08"/>')
    out.append('</svg>')
    return ''.join(out)


def svg_paths(raw):
    sx, sy = raw['size']
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {sx*1000} {sy*1000}"><rect width="100%" height="100%" fill="#111c30"/>']
    colors = {'success': '#55dda4', 'drain': '#ff7777', 'stuck': '#ffbb44', 'timeout': '#77aaff', 'invalid': '#ff00ff'}
    for run in raw['trials'][:64]:
        # Never connect separate balls, ramp layers, held states or different lives.
        segments, current, last = [], [], None
        for tick, ball, x, y, layer, state in run['trace']:
            key = (ball, layer, state)
            if last is not None and (key != last[0] or tick-last[1] > 16 or math.hypot(x-last[2], y-last[3]) > .15):
                segments.append(current)
                current = []
            current.append(f'{x*1000:.2f},{(sy-y)*1000:.2f}')
            last = (key, tick, x, y)
        segments.append(current)
        for points in segments:
            if len(points) > 1:
                out.append(f'<polyline points="{" ".join(points)}" fill="none" stroke="{colors[run["status"]]}" stroke-width="2" opacity=".5"/>')
    out.append('</svg>')
    return ''.join(out)


def write_report(raw, request, output, compare=None):
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    report = summarize(raw, request['trials'])
    if compare:
        before = json.loads(Path(compare).read_text())
        report['comparison'] = {name: {'before': before['scenarios'].get(name), 'after': value} for name, value in report['scenarios'].items()}
        report['comparisonWarning'] = 'Compare identical suites, seeds, physics and horizons; this is a descriptive A/B report.'
    (output/'report.json').write_text(json.dumps(report, indent=2)+'\n')
    (output/'replay.json').write_text(json.dumps(request, indent=2)+'\n')
    (output/'runs.json').write_text(json.dumps(raw)+'\n')
    pictures = []
    for layer, label in [(0, 'playfield'), (1, 'ramp')]:
        for dwell, name in [(False, 'visits'), (True, 'dwell')]:
            svg = svg_map(raw, layer, dwell)
            (output/f'{label}-{name}.svg').write_text(svg)
            pictures.append(f'<figure><figcaption>{label}: {name} (relative scale)</figcaption>{svg}</figure>')
    paths = svg_paths(raw)
    (output/'trajectories.svg').write_text(paths)
    rows = ''.join(f'<tr><td>{html.escape(k)}</td><td>{v["trials"]}</td><td>{html.escape(str(v["outcomes"]))}</td><td>{v["returns"] if v["returnMeasured"] else "not measured"}</td></tr>' for k, v in report['scenarios'].items())
    page = '<!doctype html><meta charset="utf-8"><title>Pinball analysis</title><style>body{background:#09121f;color:#eee;font:16px system-ui;margin:32px}section{display:flex;flex-wrap:wrap}figure{width:280px;margin:12px}svg{width:100%;max-height:600px}td,th{padding:8px;text-align:left}table{border-collapse:collapse}tr{border-bottom:1px solid #456}pre{white-space:pre-wrap}</style>'
    page += f'<h1>{html.escape(raw["table"])} — physics analysis</h1><p>{report["steps"]:,} steps in {raw["wallSeconds"]:.3f}s; {raw["workers"]} workers. {html.escape(raw["sampling"])}</p>'
    page += '<p>'+html.escape(report['warning'])+'</p><table><tr><th>Scenario</th><th>Trials</th><th>Outcomes</th><th>Descending feeds</th></tr>'+rows+'</table><section>'+''.join(pictures)+'</section><h2>Trajectories (first 64 trials)</h2>'+paths
    page += '<h2>Layout issues</h2><pre>'+html.escape(json.dumps(report['layoutIssues'], indent=2))+'</pre>'
    page += '<h2>Element coverage</h2><pre>'+html.escape(json.dumps(report['inventory'], indent=2))+'</pre>'
    (output/'index.html').write_text(page)
    return report


def build():
    if sys.platform != 'darwin':
        raise RuntimeError('Production physics requires macOS and Xcode command-line tools; no substitute physics will be used')
    sources = [ROOT/'tools/analyze_table.m', *sorted((ROOT/'App/Core').glob('*.m'))]
    digest = hashlib.sha256(b''.join(p.read_bytes() for p in [*sources, *sorted((ROOT/'App/Core').glob('*.h'))])).hexdigest()[:16]
    cache = ROOT/'Build/Analysis'
    cache.mkdir(parents=True, exist_ok=True)
    exe = cache/f'analyze-{digest}'
    if not exe.exists():
        subprocess.run(['xcrun', 'clang', '-O3', '-fobjc-arc', '-fmodules', '-Wno-deprecated-declarations', '-I', str(ROOT/'App/Core'), '-framework', 'Foundation', *map(str, sources), '-o', str(exe)], check=True)
    return exe


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('table', nargs='?')
    parser.add_argument('--suite')
    parser.add_argument('--out', default='Build/Analysis/report')
    parser.add_argument('--workers', type=int, default=1)
    parser.add_argument('--grid', type=int, default=64)
    parser.add_argument('--compare')
    parser.add_argument('--strict', action='store_true', help='exit nonzero on invalid physics or unmet scenario require thresholds')
    parser.add_argument('--serve', action='store_true', help='JSON lines: table, suite, out, workers, grid; retain native process')
    parser.add_argument('--check', action='store_true', help='validate suite and element references without executing physics')
    args = parser.parse_args()
    if not args.serve and (not args.table or not args.suite):
        parser.error('table and --suite are required')
    process = None
    try:
        commands = (json.loads(line) for line in sys.stdin) if args.serve else [vars(args)]
        for command in commands:
            started = time.monotonic()
            table_path = Path(command['table']).resolve()
            suite_path = Path(command['suite']).resolve()
            table, suite = json.loads(table_path.read_text()), json.loads(suite_path.read_text())
            trials = expand_suite(suite, table)
            grid, workers = command.get('grid', 64), command.get('workers', 1)
            if not isinstance(grid, int) or not 8 <= grid <= 256 or not isinstance(workers, int) or not 1 <= workers <= 16:
                raise ValueError('grid: 8..256; workers: 1..16')
            request = {'table': str(table_path), 'grid': grid, 'workers': workers, 'trials': trials,
                       'tableSHA256': hashlib.sha256(table_path.read_bytes()).hexdigest(),
                       'physicsSHA256': hashlib.sha256(b''.join(p.read_bytes() for p in sorted((ROOT/'App/Core').glob('*.[hm]')))).hexdigest(),
                       'suiteSHA256': hashlib.sha256(suite_path.read_bytes()).hexdigest()}
            if args.check:
                print(json.dumps({'validatedTrials': len(trials), 'simulationRun': False}))
                continue
            if process is None:
                process = subprocess.Popen([str(build())], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
            process.stdin.write(json.dumps(request)+'\n')
            process.stdin.flush()
            line = process.stdout.readline()
            if not line:
                raise RuntimeError('Native runner exited without a report')
            raw = json.loads(line)
            if 'error' in raw:
                raise RuntimeError(raw['error'])
            report = write_report(raw, request, command.get('out', args.out), command.get('compare'))
            print(json.dumps({'report': str(Path(command.get('out', args.out)).resolve()/'index.html'),
                              'wallSeconds': report['wallSeconds'], 'endToEndSeconds': time.monotonic()-started,
                              'host': platform.machine(), 'stepsPerSecond': report['stepsPerSecond'], 'passed': report['passed']}), flush=True)
            if args.strict and not report['passed']:
                raise RuntimeError('; '.join(report['failures']))
    finally:
        if process:
            process.stdin.close()
            process.wait()


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f'analysis: {error}', file=sys.stderr)
        sys.exit(1)
