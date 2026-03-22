#!/usr/bin/env bash
# Build the iOS project for the simulator.
# Usage: ./OpenTaiko.iOS/scripts/build.sh [Release|Debug] [--verbose]
set -euo pipefail
cd "$(dirname "$0")/../.."

CONFIG="Debug"
VERBOSE=false
for arg in "$@"; do
  case "$arg" in
    --verbose) VERBOSE=true ;;
    Release|Debug) CONFIG="$arg" ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

if $VERBOSE; then
  dotnet build OpenTaiko.iOS/OpenTaiko.iOS.csproj -c "$CONFIG"
else
  dotnet build OpenTaiko.iOS/OpenTaiko.iOS.csproj -c "$CONFIG" 2>&1 \
    | grep -vE "PublishFolderType" \
    | tail -5
fi
