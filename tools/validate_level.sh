#!/bin/zsh
# Compile the engine-only authoring gate; no app build or new dependencies.
set -eu
cd "${0:A:h:h}"
validator_cache="${TMPDIR:-/tmp}/pinball-level-validator"
mkdir -p "$validator_cache"
xcrun clang -fobjc-arc -fmodules -Wno-deprecated-declarations \
  -fmodules-cache-path="$PWD/Build/ModuleCache.noindex" -I App/Core \
  -framework Foundation tools/validate_level.m App/Core/*.m -o "$validator_cache/validate_level"
"$validator_cache/validate_level" "$@"
