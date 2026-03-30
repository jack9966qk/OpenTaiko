#!/usr/bin/env bash
# Build, install, and launch on a physical iOS device.
# Usage: ./OpenTaiko.iOS/scripts/deploy-device.sh [options]
#   --clean       Uninstall existing app first (fresh Documents directory)
#   --no-build    Skip the build step
#   --device ID   Target a specific device (default: auto-detect)
#   --timeout N   Seconds to stream console output before exiting (default: 30, 0=unlimited)
#   --release     Build in Release mode (AOT compiled, faster but slower build)
set -euo pipefail
cd "$(dirname "$0")/../.."

APP_ID="com.opentaiko.OpenTaiko"
APP_PATH="OpenTaiko.iOS/bin/Debug/net8.0-ios/ios-arm64/OpenTaiko.iOS.app"
DEVICE=""
CLEAN=false
BUILD=true
TIMEOUT=30
CONFIG="Debug"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)      CLEAN=true; shift ;;
    --no-build)   BUILD=false; shift ;;
    --device)     DEVICE="$2"; shift 2 ;;
    --timeout)    TIMEOUT="$2"; shift 2 ;;
    --release)    CONFIG="Release"; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

APP_PATH="OpenTaiko.iOS/bin/${CONFIG}/net8.0-ios/ios-arm64/OpenTaiko.iOS.app"

# Auto-detect device if not specified
if [[ -z "$DEVICE" ]]; then
  DEVICE=$(xcrun devicectl list devices 2>/dev/null | grep -E '[A-F0-9]{8}-[A-F0-9]{4}-' | grep -vi simulator | awk '{for(i=1;i<=NF;i++) if($i ~ /^[A-F0-9]{8}-/) print $i}' | head -1)
  if [[ -z "$DEVICE" ]]; then
    echo "No iOS device found. Connect a device and trust this Mac."
    echo ""
    echo "Available devices:"
    xcrun devicectl list devices 2>&1
    exit 1
  fi
  echo "==> Found device: $DEVICE"
fi

# Build for physical device
if $BUILD; then
  # Build liblua54 xcframework if not present
  if [[ ! -d "OpenTaiko.iOS/Frameworks/liblua54.xcframework" ]]; then
    bash OpenTaiko.iOS/scripts/build-lua54.sh
  fi

  echo "==> Building for ios-arm64 ($CONFIG)..."
  dotnet build OpenTaiko.iOS/OpenTaiko.iOS.csproj \
    -c "$CONFIG" \
    -r ios-arm64 \
    -p:RuntimeIdentifier=ios-arm64 \
    -p:CodesignKey="Apple Development" \
    -p:CodesignProvision="" \
    2>&1 \
    | grep -E "(error CS|error MT|Error\(s\)|Build succeeded|NETSDK|Codesign)" \
    | tail -10

  # Check build actually succeeded
  if [[ ! -d "$APP_PATH" ]]; then
    echo "Build failed — $APP_PATH not found."
    echo "Re-running build with full output..."
    dotnet build OpenTaiko.iOS/OpenTaiko.iOS.csproj \
      -c "$CONFIG" \
      -r ios-arm64 \
      -p:RuntimeIdentifier=ios-arm64 \
      -p:CodesignKey="Apple Development" \
      -p:CodesignProvision="" \
      2>&1 | tail -30
    exit 1
  fi
fi

# Optionally clean install
if $CLEAN; then
  echo "==> Uninstalling previous app..."
  xcrun devicectl device uninstall app --device "$DEVICE" "$APP_ID" 2>/dev/null || true
fi

# Install
echo "==> Installing on device..."
xcrun devicectl device install app --device "$DEVICE" "$APP_PATH" 2>&1 | tail -3

# Launch
if [[ "$TIMEOUT" -eq 0 ]]; then
  echo "==> Launching (console output below, Ctrl-C to stop)..."
  xcrun devicectl device process launch --device "$DEVICE" --console "$APP_ID" 2>&1
else
  echo "==> Launching (showing ${TIMEOUT}s of console output)..."
  xcrun devicectl device process launch --device "$DEVICE" --console "$APP_ID" 2>&1 &
  CONSOLE_PID=$!
  sleep "$TIMEOUT"
  kill "$CONSOLE_PID" 2>/dev/null || true
  wait "$CONSOLE_PID" 2>/dev/null || true
  echo "==> Console timeout reached."
fi
