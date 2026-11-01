#!/bin/zsh
# Compression only: no recolouring, synthesized states, resizing or repacking.
set -eu
cd "${0:A:h:h}"
for skin_id in orbital abyss; do
  sips -s format jpeg -s formatOptions 94 "Art/Masters/$skin_id-hardware.png" \
    --out "GameData/Skins/$skin_id.jpg"
  sips -s format jpeg -s formatOptions 94 "Art/Masters/$skin_id-playfield.png" \
    --out "GameData/Skins/$skin_id-playfield.jpg"
done
