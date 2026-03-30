#!/usr/bin/env bash
# Build the iOS project for the simulator.
# Usage: ./OpenTaiko.iOS/scripts/build.sh [Release|Debug]
set -euo pipefail
cd "$(dirname "$0")/../.."

CONFIG="${1:-Debug}"
dotnet build OpenTaiko.iOS/OpenTaiko.iOS.csproj -c "$CONFIG" 2>&1 \
  | grep -vE "PublishFolderType" \
  | tail -5
