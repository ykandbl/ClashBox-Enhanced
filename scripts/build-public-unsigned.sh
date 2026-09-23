#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBLIC_PROFILE="$PROJECT_ROOT/build-profile.public.json5"
LOCAL_PROFILE="$PROJECT_ROOT/build-profile.json5"
DEVECO_ROOT="${DEVECO_ROOT:-/Applications/DevEco-Studio-26-Beta.app/Contents}"
NODE_ROOT="${NODE_HOME:-$DEVECO_ROOT/tools/node}"
HVIGOR="${HVIGOR:-$DEVECO_ROOT/tools/hvigor/bin/hvigorw}"
OHPM="${OHPM:-$DEVECO_ROOT/tools/ohpm/bin/ohpm}"
UNSIGNED_HAP="$PROJECT_ROOT/entry/build/release/outputs/default/entry-default-unsigned.hap"

if [[ ! -f "$LOCAL_PROFILE" ]]; then
  cp "$PUBLIC_PROFILE" "$LOCAL_PROFILE"
  echo "using unsigned public build profile"
else
  echo "using existing local build profile; only the unsigned artifact will be published"
fi

export NODE_HOME="$NODE_ROOT"
export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-$DEVECO_ROOT/sdk}"
export OHOS_BASE_SDK_HOME="${OHOS_BASE_SDK_HOME:-${HOME}/Library/OpenHarmony/Sdk}"

cd "$PROJECT_ROOT"
for module_dir in "$PROJECT_ROOT" "$PROJECT_ROOT/xb_components" \
  "$PROJECT_ROOT/proxy_core" "$PROJECT_ROOT/entry"; do
  (cd "$module_dir" && "$OHPM" install)
done
CORE_LIBRARY="$PROJECT_ROOT/proxy_core/libs/arm64-v8a/libflclash.so"
if [[ ! -s "$CORE_LIBRARY" ]]; then
  echo "public core binary is absent; building pinned Harmony core"
  (cd "$PROJECT_ROOT/proxy_core/src/flclash" && ./build.sh && ./verify-core-ohos.sh)
fi
"$HVIGOR" --mode module -p product=release -p buildMode=release assembleHap --no-daemon

if [[ ! -s "$UNSIGNED_HAP" ]]; then
  echo "unsigned HAP not found: $UNSIGNED_HAP" >&2
  exit 1
fi

echo "unsigned release HAP: $UNSIGNED_HAP"
shasum -a 256 "$UNSIGNED_HAP"
