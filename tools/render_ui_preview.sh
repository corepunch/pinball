#!/bin/zsh
set -eu
cd "${0:A:h:h}"
ui_preview_cache="${TMPDIR:-/tmp}/pinball-ui-preview"
mkdir -p "$ui_preview_cache"
# '-' uses live working assets, so UI verification needs no app or simulator build.
ui_preview_bundle="${1:--}"
if [[ "$ui_preview_bundle" == "-" ]]; then
  ui_preview_bundle="$ui_preview_cache/PreviewResources.bundle"
  mkdir -p "$ui_preview_bundle/Contents/Resources"
  cat > "$ui_preview_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.igorchernakov.pinball.ui-preview</string>
<key>CFBundlePackageType</key><string>BNDL</string>
</dict></plist>
PLIST
  ln -sfn "$PWD/GameData" "$ui_preview_bundle/Contents/Resources/GameData"
fi
xcrun clang -fobjc-arc -fmodules -Wno-deprecated-declarations \
  -fmodules-cache-path="$ui_preview_cache/modules" \
  -I App/Scene -I App/Core -I App -I App/UI -I App/UI/Model \
  -framework CoreText -framework AppKit -framework SpriteKit -framework QuartzCore -framework ImageIO \
  tools/render_ui_preview.m App/UI/*.m App/UI/Model/*.m App/Core/*.m \
  -o "$ui_preview_cache/render_ui_preview"
"$ui_preview_cache/render_ui_preview" "$ui_preview_bundle" "${2:-$PWD/Art/Previews}" "${@:3}"
