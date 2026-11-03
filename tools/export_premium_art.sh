#!/bin/zsh
# Compression only: no recolouring, synthesized states, resizing or repacking.
set -eu
cd "${0:A:h:h}"
for skin_id in orbital abyss; do
  sips -s format jpeg -s formatOptions 94 "Art/Masters/$skin_id-hardware.png" \
    --out "GameData/Skins/$skin_id.jpg"
  playfield_master="Art/Masters/$skin_id-playfield.png"
  if [[ "$skin_id" == orbital ]]; then
    playfield_master="Art/Masters/orbital-night-field.png"
  fi
  sips -s format jpeg -s formatOptions 94 "$playfield_master" \
    --out "GameData/Skins/$skin_id-playfield.jpg"
done
