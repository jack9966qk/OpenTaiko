#!/usr/bin/env bash
# Build, install, and launch on an iOS simulator with console output.
# Usage: ./OpenTaiko.iOS/scripts/deploy.sh [options]
#   --clean       Uninstall existing app first (fresh Documents directory)
#   --no-build    Skip the build step
#   --device ID   Target a specific simulator device (default: "booted")
#   --screenshot [FILE]  Take a screenshot after launch (default: /tmp/opentaiko.png)
#   --wait N      Seconds to wait before screenshot (default: 20)
#   --timeout N   Seconds to stream console output before exiting (default: 10, 0=unlimited)
#   --release     Build in Release mode (AOT compiled, faster but slower build)
#   --bundle-id ID  Override bundle identifier (default: from .csproj)
#   --verbose     Pipe full build log to stdout instead of filtering
set -euo pipefail
cd "$(dirname "$0")/../.."

CSPROJ="OpenTaiko.iOS/OpenTaiko.iOS.csproj"
BUNDLE_ID=""
DEVICE="booted"
CLEAN=false
BUILD=true
SCREENSHOT=""
WAIT=20
TIMEOUT=10
CONFIG="Debug"
VERBOSE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)      CLEAN=true; shift ;;
    --no-build)   BUILD=false; shift ;;
    --device)     DEVICE="$2"; shift 2 ;;
    --screenshot) SCREENSHOT="${2:-/tmp/opentaiko.png}"; shift; [[ "${1:-}" != --* && -n "${1:-}" ]] && shift || true ;;
    --wait)       WAIT="$2"; shift 2 ;;
    --timeout)    TIMEOUT="$2"; shift 2 ;;
    --release)    CONFIG="Release"; shift ;;
    --bundle-id)  BUNDLE_ID="$2"; shift 2 ;;
    --verbose)    VERBOSE=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

APP_PATH="OpenTaiko.iOS/bin/${CONFIG}/net10.0-ios/iossimulator-arm64/OpenTaiko.iOS.app"

# Resolve bundle ID from .csproj if not overridden
DEFAULT_BUNDLE_ID=$(grep '<ApplicationId' "$CSPROJ" | sed 's/.*>\(.*\)<.*/\1/')
APP_ID="${BUNDLE_ID:-$DEFAULT_BUNDLE_ID}"
BUNDLE_ID_ARG=()
if [[ -n "$BUNDLE_ID" ]]; then
  BUNDLE_ID_ARG=(-p:ApplicationId="$BUNDLE_ID")
fi

# Ensure a simulator is booted
if ! xcrun simctl list devices booted | grep -q "Booted"; then
  echo "No simulator booted. Boot one first:"
  echo "  xcrun simctl boot <device-uuid>"
  echo ""
  echo "Available devices:"
  xcrun simctl list devices available | grep -i iphone
  exit 1
fi

# Build
if $BUILD; then
  # Download BASS iOS libraries if not present
  if [[ ! -d "OpenTaiko.iOS/Libs/bass24-ios" ]]; then
    bash OpenTaiko.iOS/scripts/download-bass.sh
  fi

  # Build liblua54 xcframework if not present
  if [[ ! -d "OpenTaiko.iOS/Frameworks/liblua54.xcframework" ]]; then
    bash OpenTaiko.iOS/scripts/build-lua54.sh
  fi

  echo "==> Building ($CONFIG)..."
  if $VERBOSE; then
    dotnet build "$CSPROJ" -c "$CONFIG" -r iossimulator-arm64 "${BUNDLE_ID_ARG[@]}"
  else
    dotnet build "$CSPROJ" -c "$CONFIG" -r iossimulator-arm64 "${BUNDLE_ID_ARG[@]}" 2>&1 \
      | grep -E "(error CS|Error\(s\)|Build succeeded)" \
      | tail -5
  fi
fi

# Terminate existing instance
echo "==> Terminating existing app..."
xcrun simctl terminate "$DEVICE" "$APP_ID" 2>/dev/null || true

# Optionally clean install
if $CLEAN; then
  echo "==> Uninstalling previous app..."
  xcrun simctl uninstall "$DEVICE" "$APP_ID" 2>/dev/null || true
fi

# Install and launch
echo "==> Installing..."
xcrun simctl install "$DEVICE" "$APP_PATH"

if [[ -n "$SCREENSHOT" ]]; then
  echo "==> Launching in background..."
  xcrun simctl launch "$DEVICE" "$APP_ID"
  echo "==> Waiting ${WAIT}s before screenshot..."
  sleep "$WAIT"
  echo "==> Taking screenshot -> $SCREENSHOT"
  xcrun simctl io "$DEVICE" screenshot "$SCREENSHOT"
  # Rotate screenshot to match device orientation (simctl always captures portrait)
  ORIENTATION=$(xcrun simctl spawn "$DEVICE" launchctl getenv SIMULATOR_DEVICE_ORIENTATION 2>/dev/null || true)
  if [[ -z "$ORIENTATION" ]]; then
    # Fall back: check Info.plist for supported orientations
    ORIENTATION=$(defaults read "$(cd "$(dirname "$0")/.." && pwd)/Info.plist" UISupportedInterfaceOrientations 2>/dev/null | grep -o 'Landscape' | head -1 || true)
    [[ -n "$ORIENTATION" ]] && ORIENTATION="LandscapeLeft"
  fi
  case "$ORIENTATION" in
    LandscapeLeft|UIInterfaceOrientationLandscapeLeft)
      sips -r 90 "$SCREENSHOT" >/dev/null 2>&1 && echo "==> Rotated screenshot to landscape." ;;
    LandscapeRight|UIInterfaceOrientationLandscapeRight)
      sips -r 270 "$SCREENSHOT" >/dev/null 2>&1 && echo "==> Rotated screenshot to landscape." ;;
  esac
  echo "==> Done. App is still running in the simulator."
else
  if [[ "$TIMEOUT" -eq 0 ]]; then
    echo "==> Launching (console output below, Ctrl-C to detach)..."
    xcrun simctl launch --console "$DEVICE" "$APP_ID"
  else
    echo "==> Launching (showing ${TIMEOUT}s of console output)..."
    xcrun simctl launch --console "$DEVICE" "$APP_ID" &
    CONSOLE_PID=$!
    sleep "$TIMEOUT"
    kill "$CONSOLE_PID" 2>/dev/null || true
    wait "$CONSOLE_PID" 2>/dev/null || true
    echo "==> Console timeout reached."
  fi
fi
