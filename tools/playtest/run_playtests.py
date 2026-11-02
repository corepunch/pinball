#!/usr/bin/env python3
"""Plays every level headlessly and reports its problems: `make playtest`.

    python3 tools/playtest/run_playtests.py [--games N] [--tune] [--only id...]

Fails on a trapped ball, a part the ball never reaches, or a layout the validator rejects. A part may
still be hard: the autopilot is a decent player, not a great one. --tune rewrites each level's goal
and star scores in GameData/Levels.json from what it scored, harder further into the campaign.
"""
import argparse
import concurrent.futures
import json
import statistics
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BINARY = ROOT / 'Build/playtest'
LEVELS = ROOT / 'GameData/Levels.json'
MAX_STUCK_PER_DRAIN = .1
MAX_MINUTES_PER_GAME = 6
EASIEST, HARDEST = .95, .45  # How often the autopilot meets the goal, on the first level and the last.
TOP_STAR_LEAST_GAP = 1.15


def build():
    sources = sorted(str(p) for p in (ROOT / 'App/Core').glob('*.m'))
    subprocess.run(['clang', '-O2', '-fobjc-arc', '-framework', 'Foundation', f'-I{ROOT}/App/Core', '-o', str(BINARY), str(ROOT / 'tools/playtest/playtest.m'), *sources], check=True, stderr=subprocess.DEVNULL)


def play(args):
    table, games = args
    out = subprocess.run([str(BINARY), str(ROOT / f'GameData/Tables/{table}.json'), str(games)], capture_output=True, text=True)
    if out.returncode:
        return {'table': table, 'games': [], 'minutes': 0, 'stuck': 0, 'drains': 0, 'issues': [out.stderr.strip()], 'never': []}
    return json.loads(out.stdout)


def percentile(values, share):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(share * len(ordered)))]


def nice(value):
    """Rounded to two figures, as a score worth aiming for."""
    if value < 100:
        return max(1, int(value))
    step = 10 ** (len(str(int(value))) - 2)
    return int(round(value / step) * step)


def tune(level, report, position):
    games = report['games']
    scores = [g['score'] for g in games]
    chance = EASIEST + (HARDEST - EASIEST) * position
    goal = level['goal']
    values = scores if goal == 'score' else [g.get(goal, 0) for g in games]
    level['count'] = nice(percentile(values, 1 - chance))
    floor = level['count'] if goal == 'score' else 0
    two = nice(max(percentile(scores, .6), floor * TOP_STAR_LEAST_GAP))
    three = nice(max(percentile(scores, .92), two * TOP_STAR_LEAST_GAP))
    level['stars'] = [two, three]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--games', type=int, default=30)
    parser.add_argument('--tune', action='store_true')
    parser.add_argument('--only', nargs='*')
    args = parser.parse_args()
    build()
    catalog = json.loads(LEVELS.read_text())
    levels = catalog['levels']
    wanted = [l for l in levels if not args.only or l['id'] in args.only or l['table'] in args.only]
    with concurrent.futures.ThreadPoolExecutor() as pool:
        reports = {r['table']: r for r in pool.map(play, [(t, args.games) for t in {l['table'] for l in wanted}])}
    failed = 0
    print(f"{'level':<6}{'table':<12}{'games':>6}{'min/g':>7}{'median':>10}{'p90':>10} {'goal':<18}{'met':>5} {'stuck':>6}  problems")
    for level in wanted:
        report = reports[level['table']]
        if args.tune and report['games']:
            tune(level, report, levels.index(level) / max(1, len(levels) - 1))
        games = report['games']
        scores = [g['score'] for g in games] or [0]
        goal = level['goal']
        values = scores if goal == 'score' else [g.get(goal, 0) for g in games] or [0]
        met = sum(v >= level['count'] for v in values) / max(1, len(values))
        problems = []
        if report['stuck'] > max(2, report['drains'] * MAX_STUCK_PER_DRAIN):
            spots = sorted(report['stuckAt'].items(), key=lambda s: -s[1])[:3]
            problems.append(f"ball trapped {report['stuck']}x at " + ' '.join(f'{p} x{n}' for p, n in spots))
        if report['never']:
            problems.append('never reached: ' + ' '.join(report['never']))
        if report['issues']:
            problems.append(f"layout: {'; '.join(report['issues'][:3])}")
        if games and report['minutes'] / len(games) > MAX_MINUTES_PER_GAME:
            problems.append('endless play: a ball is caught in a scoring loop')
        if not games:
            problems.append('no game finished')
        elif met == 0:
            problems.append('goal never met')
        failed += bool(problems)
        print(f"{level['id']:<6}{level['table']:<12}{len(games):>6}{report['minutes'] / max(1, len(games)):>7.1f}{statistics.median(scores):>10,.0f}{percentile(scores, .9):>10,} {goal + ' ' + str(level['count']):<18}{met:>5.0%} {report['stuck']:>6}  {' | '.join(problems)}")
    if args.tune:
        LEVELS.write_text(json.dumps(catalog, indent=1) + '\n')
    print(f'{failed} of {len(wanted)} levels with problems')
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
