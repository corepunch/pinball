#!/usr/bin/env python3
"""Compare two folders of COLLADA models: triangles, size and direction per surface role.
Usage: compare_models.py old-dir new-dir"""
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

NS = {'c': 'http://www.collada.org/2005/11/COLLADASchema'}


def load(path):
    roles = {}
    for geometry in ET.parse(path).getroot().findall('.//c:geometry', NS):
        sources = geometry.findall('.//c:source', NS)
        v = list(map(float, sources[0].find('c:float_array', NS).text.split()))
        n = list(map(float, sources[1].find('c:float_array', NS).text.split()))
        count = int(geometry.find('.//c:triangles', NS).get('count'))
        role = roles.setdefault(geometry.get('name'), dict(tris=0, low=[9e9] * 3, high=[-9e9] * 3, up=0.0, count=0))
        role['tris'] += count
        for axis in range(3):
            role['low'][axis] = min(role['low'][axis], min(v[axis::3]))
            role['high'][axis] = max(role['high'][axis], max(v[axis::3]))
        role['up'] += sum(n[1::3])
        role['count'] += len(n) // 3
    return roles


old, new = Path(sys.argv[1]), Path(sys.argv[2])
problems = 0
names = sorted({p.stem for p in old.glob('*.dae')} | {p.stem for p in new.glob('*.dae')})
for name in names:
    if not (old / f'{name}.dae').exists() or not (new / f'{name}.dae').exists():
        print(name, 'ONLY IN ONE')
        problems += 1
        continue
    a, b = load(old / f'{name}.dae'), load(new / f'{name}.dae')
    notes = []
    if set(a) != set(b):
        notes.append(f'roles {sorted(set(a) ^ set(b))}')
    for role in sorted(set(a) & set(b)):
        ra, rb = a[role], b[role]
        size = max(ra['high'][i] - ra['low'][i] for i in range(3)) or 1
        shift = max(max(abs(ra['low'][i] - rb['low'][i]), abs(ra['high'][i] - rb['high'][i])) for i in range(3))
        if shift > size * .02 + 1e-4:
            notes.append(f'{role} bounds off by {shift:.4f}')
        if abs(ra['tris'] - rb['tris']) > max(ra['tris'] * .1, 12):
            notes.append(f"{role} triangles {ra['tris']} -> {rb['tris']}")
        ua, ub = ra['up'] / max(ra['count'], 1), rb['up'] / max(rb['count'], 1)
        if abs(ua - ub) > .15:
            notes.append(f'{role} faces up {ua:.2f} -> {ub:.2f}')
    if notes:
        problems += 1
        print(name, '; '.join(notes))
print(f'{len(names)} models, {problems} differ')
