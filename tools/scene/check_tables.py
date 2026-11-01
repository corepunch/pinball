#!/usr/bin/env python3
"""Compare two table JSONs by ID, within rounding. Usage: check_tables.py a.json b.json"""
import json
import sys


def same(a, b, path=''):
    if isinstance(a, dict):
        if set(a) != set(b):
            return [(path, 'keys', sorted(set(a) ^ set(b)))]
        return [x for k in a for x in same(a[k], b[k], path + '/' + k)]
    if isinstance(a, list):
        if a and isinstance(a[0], dict) and 'id' in a[0]:
            A, B = {i['id']: i for i in a}, {i['id']: i for i in b}
            if set(A) != set(B):
                return [(path, 'ids', sorted(set(A) ^ set(B)))]
            return [x for k in A for x in same(A[k], B[k], path + '/' + k)]
        if len(a) != len(b):
            return [(path, 'length', len(a), len(b))]
        return [x for i, (p, q) in enumerate(zip(a, b)) for x in same(p, q, f'{path}/{i}')]
    if isinstance(a, (int, float)) and not isinstance(a, bool) and isinstance(b, (int, float)):
        return [] if abs(a - b) < 2e-6 else [(path, a, b)]
    return [] if a == b else [(path, a, b)]


found = same(json.load(open(sys.argv[1])), json.load(open(sys.argv[2])))
print(sys.argv[1].split('/')[-1], 'differences:', len(found), found[:8])
sys.exit(1 if found else 0)
