#!/usr/bin/env python3
"""Package the dependency-free Blender add-on, excluding Python caches."""
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
ROOT=Path(__file__).resolve().parents[1]
package=ROOT/'tools/blender_addons/pinball_builder'
destination=ROOT/'Art/Tools/pinball-builder.zip';destination.parent.mkdir(parents=True,exist_ok=True)
with ZipFile(destination,'w',ZIP_DEFLATED) as archive:
    for path in sorted(package.glob('*.py')):archive.write(path,'pinball_builder/'+path.name)
    archive.write(ROOT/'Art/BLENDER_AUTHORING.md','pinball_builder/README.md')
print(destination)
