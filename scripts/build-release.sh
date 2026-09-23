#!/usr/bin/env bash
set -euo pipefail

# Reproducible local release build for the HarmonyOS NEXT project.
# The HarmonyOS SDK root is the directory that contains `default/`; passing
# `default/` itself makes the HOS component mapper resolve platform paths
# incorrectly.  Use DevEco's bundled Node because newer system Node versions
# removed fs.rmdirSync's recursive option still used by this Hvigor release.

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVECO_ROOT="${DEVECO_ROOT:-/Applications/DevEco-Studio-26-Beta.app/Contents}"
SDK_ROOT="${DEVECO_SDK_HOME:-$DEVECO_ROOT/sdk}"
OHOS_ROOT="${OHOS_BASE_SDK_HOME:-${HOME}/Library/OpenHarmony/Sdk}"
NODE_ROOT="${NODE_HOME:-$DEVECO_ROOT/tools/node}"
HVIGOR="${HVIGOR:-$DEVECO_ROOT/tools/hvigor/bin/hvigorw}"

for required in "$PROJECT_ROOT/build-profile.json5" "$HVIGOR" "$NODE_ROOT/bin/node" "$SDK_ROOT"; do
  if [[ ! -e "$required" ]]; then
    echo "Missing build dependency: $required" >&2
    exit 2
  fi
done

export NODE_HOME="$NODE_ROOT"
export DEVECO_SDK_HOME="$SDK_ROOT"
export OHOS_BASE_SDK_HOME="$OHOS_ROOT"

cd "$PROJECT_ROOT"
# `product=release` selects the ARM64 product, but this Hvigor project still
# defaults the build mode to debug unless it is stated explicitly. Keep the
# artifact name and its embedded module metadata aligned with the command.
exec "$HVIGOR" --mode module -p product=release -p buildMode=release assembleHap --no-daemon "$@"
