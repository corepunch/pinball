#!/usr/bin/env python3
"""One-way migration: GameData/Tables/*.json to Scenes/*.xml, leaving out what the ramps generate."""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from shim import ROOT  # noqa: E402
import table_xml  # noqa: E402

for path in sorted((ROOT / 'GameData/Tables').glob('*.json')):
    table = json.loads(path.read_text())
    table['lamps'] = [l for l in table['lamps'] if 'ramp' not in l]
    table['walls'] = [w for w in table['walls'] if 'ramp' not in w]
    for ramp in table['ramps']:
        for key in ('plasticUntil', 'mouth'):
            ramp.pop(key, None)
        ramp['authoring'].pop('columns', None)
    table_xml.write(table, ROOT / 'Scenes' / f"{table['id']}.xml")
