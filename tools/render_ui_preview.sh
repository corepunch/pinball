#!/bin/zsh
set -eu
cd "${0:A:h:h}"
ui_preview_cache="${TMPDIR:-/tmp}/pinball-ui-preview"
mkdir -p "$ui_preview_cache"
xcrun clang -fobjc-arc -fmodules -Wno-deprecated-declarations \
  -fmodules-cache-path="$ui_preview_cache/modules" \
  -I App/Scene -I App/Core -I App -I App/UI -I App/UI/Model \
  -framework AppKit -framework SpriteKit -framework SceneKit -framework Metal -framework QuartzCore -framework ImageIO \
  tools/render_ui_preview.m App/UI/PBGameUI.m App/UI/Model/PBMenuFlow.m App/Scene/*.m App/Core/*.m \
  -o "$ui_preview_cache/render_ui_preview"
"$ui_preview_cache/render_ui_preview" "$1" "${2:-$PWD/Art/Previews}"
