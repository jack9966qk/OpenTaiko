#!/usr/bin/env bash
# Build, install, and launch on a physical iOS device.
# Usage: ./OpenTaiko.iOS/scripts/deploy-device.sh [options]
#   --clean       Uninstall existing app first (fresh Documents directory)
#   --no-build    Skip the build step
#   --device ID   Target a specific device for devicectl (default: auto-detect)
#   --udid UDID   Target a specific device for ideviceinstaller
#   --imobile     Use ideviceinstaller instead of devicectl (for jailbroken/older devices)
#   --timeout N   Seconds to stream console output before exiting (default: 30, 0=unlimited)
#   --release     Build in Release mode (AOT compiled, faster but slower build)
#   --bundle-id ID  Override bundle identifier (default: from .csproj)
#   --identity NAME Codesign identity (default: auto-detect "Apple Development")
set -euo pipefail
cd "$(dirname "$0")/../.."
source "OpenTaiko.iOS/scripts/_signing-helpers.sh"

CSPROJ="OpenTaiko.iOS/OpenTaiko.iOS.csproj"
BUNDLE_ID=""
IDENTITY=""
APP_PATH="OpenTaiko.iOS/bin/Debug/net8.0-ios/ios-arm64/OpenTaiko.iOS.app"
DEVICE=""
UDID=""
IMOBILE=false
CLEAN=false
BUILD=true
TIMEOUT=30
CONFIG="Debug"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)      CLEAN=true; shift ;;
    --no-build)   BUILD=false; shift ;;
    --device)     DEVICE="$2"; shift 2 ;;
    --udid)       UDID="$2"; IMOBILE=true; shift 2 ;;
    --imobile)    IMOBILE=true; shift ;;
    --timeout)    TIMEOUT="$2"; shift 2 ;;
    --release)    CONFIG="Release"; shift ;;
    --bundle-id)  BUNDLE_ID="$2"; shift 2 ;;
    --identity)   IDENTITY="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

APP_PATH="OpenTaiko.iOS/bin/${CONFIG}/net8.0-ios/ios-arm64/OpenTaiko.iOS.app"

# Resolve bundle ID from .csproj if not overridden
DEFAULT_BUNDLE_ID=$(grep '<ApplicationId' "$CSPROJ" | sed 's/.*>\(.*\)<.*/\1/')
APP_ID="${BUNDLE_ID:-$DEFAULT_BUNDLE_ID}"
BUNDLE_ID_ARG=()
if [[ -n "$BUNDLE_ID" ]]; then
  BUNDLE_ID_ARG=(-p:ApplicationId="$BUNDLE_ID")
fi

# Auto-detect device if not specified
if $IMOBILE; then
  if [[ -z "$UDID" ]]; then
    UDID=$(idevice_id -l 2>/dev/null | head -1)
    if [[ -z "$UDID" ]]; then
      echo "No device found via idevice_id."
      exit 1
    fi
    echo "==> Found device (libimobiledevice): $UDID"
  fi
else
  if [[ -z "$DEVICE" ]]; then
    DEVICE=$(xcrun devicectl list devices 2>/dev/null | { grep -E 'available.*paired' || true; } | awk '{for(i=1;i<=NF;i++) if($i ~ /^[A-F0-9]{8}-/) print $i}' | head -1)
    if [[ -z "$DEVICE" ]]; then
      echo "No device found via devicectl. Use --imobile for libimobiledevice."
      echo ""
      echo "Available devices:"
      xcrun devicectl list devices 2>&1
      exit 1
    fi
    echo "==> Found device: $DEVICE"
  fi
fi

# Auto-detect signing identity if not provided
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(find_codesign_identity "Apple Development")
  echo "==> Using identity: $IDENTITY"
fi

# Build for physical device
if $BUILD; then
  # Download BASS iOS libraries if not present
  if [[ ! -d "OpenTaiko.iOS/Libs/bass24-ios" ]]; then
    bash OpenTaiko.iOS/scripts/download-bass.sh
  fi

  # Build liblua54 xcframework if not present
  if [[ ! -d "OpenTaiko.iOS/Frameworks/liblua54.xcframework" ]]; then
    bash OpenTaiko.iOS/scripts/build-lua54.sh
  fi

  echo "==> Building for ios-arm64 ($CONFIG)..."
  dotnet build "$CSPROJ" \
    -c "$CONFIG" \
    -r ios-arm64 \
    -p:RuntimeIdentifier=ios-arm64 \
    -p:CodesignKey="$IDENTITY" \
    -p:CodesignProvision="" \
    "${BUNDLE_ID_ARG[@]}" \
    2>&1 \
    | { grep -E "(error CS|error MT|Error\(s\)|Build succeeded|NETSDK|Codesign)" || true; } \
    | tail -10

  # Check build actually succeeded
  if [[ ! -d "$APP_PATH" ]]; then
    echo "Build failed — $APP_PATH not found."
    echo "Re-running build with full output..."
    dotnet build "$CSPROJ" \
      -c "$CONFIG" \
      -r ios-arm64 \
      -p:RuntimeIdentifier=ios-arm64 \
      -p:CodesignKey="$IDENTITY" \
      -p:CodesignProvision="" \
      "${BUNDLE_ID_ARG[@]}" \
      2>&1 | tail -30
    exit 1
  fi
fi

if $IMOBILE; then
  # --- ideviceinstaller path ---

  UDID_FLAG=()
  if [[ -n "$UDID" ]]; then
    UDID_FLAG=(-u "$UDID")
  fi

  # Optionally clean install
  if $CLEAN; then
    echo "==> Uninstalling previous app..."
    ideviceinstaller "${UDID_FLAG[@]}" uninstall "$APP_ID" 2>/dev/null || true
  fi

  # ideviceinstaller requires an .ipa — package .app into a temp one
  IPA_TMP=$(mktemp -d)
  trap "rm -rf $IPA_TMP" EXIT
  mkdir -p "$IPA_TMP/Payload"
  cp -R "$APP_PATH" "$IPA_TMP/Payload/"
  (cd "$IPA_TMP" && zip -qr app.ipa Payload)

  echo "==> Installing via ideviceinstaller..."
  ideviceinstaller "${UDID_FLAG[@]}" install "$IPA_TMP/app.ipa"

  echo "==> Installed. Launch the app manually on the device."
  echo "    (ideviceinstaller does not support remote launch)"

else
  # --- devicectl path ---

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
fi
