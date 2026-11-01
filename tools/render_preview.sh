#!/bin/zsh
# Native SceneKit preview + skin-resource smoke checks. No extra packages required.
# Usage: tools/render_preview.sh [output-directory] [skin] [--tilt-animation]
set -eu
cd "${0:A:h:h}"
preview_cache="${TMPDIR:-/tmp}/pinball-preview"
mkdir -p "$preview_cache"
# A resource-only bundle points at the working assets; no app build or asset copy.
preview_bundle="$preview_cache/PreviewResources.bundle"
mkdir -p "$preview_bundle/Contents/Resources"
cat > "$preview_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.igorchernakov.pinball.artwork-resources</string>
<key>CFBundlePackageType</key><string>BNDL</string>
</dict></plist>
PLIST
ln -sfn "$PWD/GameData" "$preview_bundle/Contents/Resources/GameData"
xcrun clang -fobjc-arc -fmodules -Wno-deprecated-declarations \
  -fmodules-cache-path="$PWD/Build/ModuleCache.noindex" \
  -I App/Scene -I App/Core -I App \
  -framework AppKit -framework SceneKit -framework Metal -framework QuartzCore -framework ImageIO \
  tools/render_preview.m App/Scene/*.m App/Core/*.m \
  -o "$preview_cache/render_preview"
"$preview_cache/render_preview" "$preview_bundle" "${1:-$PWD/Art/Previews}" "${@:2}"
