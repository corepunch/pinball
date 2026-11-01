#!/bin/zsh
# iOS SceneKit cannot read COLLADA at runtime, so the game ships compiled .scn scenes.
# Run after tools/build_hardware_models.py, which writes the sources to Art/Models/premium.
set -eu
setopt null_glob
cd "${0:A:h:h}"
out=GameData/Models/premium
mkdir -p "$out"
rm -f "$out"/*.scn
for source in Art/Models/premium/*.dae; do
  xcrun scntool --convert "$source" --format scn --output "$out/${source:t:r}.scn"
done
