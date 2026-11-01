#!/bin/zsh
# iOS SceneKit cannot read COLLADA at runtime, so the game ships compiled .scn scenes.
# Run after tools/build_hardware_models.py, which writes the sources to Art/Models/premium.
set -eu
setopt null_glob
cd "${PB_PROJECT_ROOT:-${0:A:h:h}}"
out=GameData/Models/premium
mkdir -p "$out"
for source in Art/Models/premium/*.dae; do
  compiled="$out/${source:t:r}.pending.scn"
  xcrun scntool --convert "$source" --format scn --output "$compiled"
  if [[ "$(head -c 8 "$compiled")" != bplist00 ]]; then
    rm -f "$compiled"
    print -u2 "SceneKit did not compile $source; run with access to the macOS asset importer."
    exit 1
  fi
  mv "$compiled" "$out/${source:t:r}.scn"
done
