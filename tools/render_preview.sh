#!/bin/zsh
# Native SceneKit preview + skin-resource smoke checks. No extra packages required.
set -eu
cd "${0:A:h:h}"
preview_cache="${TMPDIR:-/tmp}/pinball-preview"
mkdir -p "$preview_cache"
xcrun clang -fobjc-arc -fmodules -Wno-deprecated-declarations \
  -fmodules-cache-path="$preview_cache/modules" \
  -I Shared/Scene -I Shared/Core -I Shared/App \
  -framework AppKit -framework SceneKit -framework Metal -framework QuartzCore -framework ImageIO \
  tools/render_preview.m Shared/Scene/*.m Shared/Core/*.m \
  -o "$preview_cache/render_preview"
"$preview_cache/render_preview" "${1:-$PWD/Build/Products/Debug/Pinball.app}" "${2:-$PWD/Art/Previews}" "${@:3}"
