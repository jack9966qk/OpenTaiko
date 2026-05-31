#!/usr/bin/env bash
# Unified build/deploy script for OpenTaiko iOS.
#
# Usage: ./OpenTaiko.iOS/scripts/deploy.sh [TARGET] [options]
#
# TARGET (positional, default: sim):
#   sim         Build, install, and launch on a booted simulator (with console/screenshot)
#   device      Build, install, and launch on a connected physical device
#   ipa         Build Release and package a distributable .ipa (+ dSYM zip)
#   testflight  Build a distribution-signed .ipa and upload it to App Store Connect
#   github      Build an unsigned .ipa (+ dSYM) and publish it as a GitHub release
#
# Common options:
#   --clean            Uninstall the app before installing (sim/device)
#   --no-build         Skip the build step (reuse an existing .app)
#   --release          Build Release instead of Debug (sim/device; ipa is always Release)
#   --bundle-id ID     Override the bundle identifier (default: from .csproj)
#   --verbose          Stream the full build log instead of a filtered summary
#
# sim options:
#   --device ID        Simulator device (default: booted)
#   --timeout N        Seconds to stream console output (default: 10, 0=unlimited)
#   --screenshot [F]   Take a screenshot after launch (default file: /tmp/opentaiko.png)
#   --wait N           Seconds to wait before the screenshot (default: 20)
#
# device options:
#   --device ID        devicectl device id (default: auto-detect)
#   --udid UDID        libimobiledevice udid (implies --imobile)
#   --imobile          Install via ideviceinstaller instead of devicectl
#   --timeout N        Seconds to stream console output (default: 30, 0=unlimited)
#   --identity NAME    Codesign identity (default: auto-detect "Apple Development")
#
# ipa options:
#   --output PATH      Output .ipa path (default: OpenTaiko.iOS/dist/OpenTaiko_unsigned.ipa)
#   --sign MODE        none (default, unsigned) | development | distribution
#   --identity NAME    Codesign identity (default depends on --sign)
#
# testflight options (always builds a distribution-signed Release IPA):
#   --output PATH      Output .ipa path (default: OpenTaiko.iOS/dist/OpenTaiko.ipa)
#   --no-upload        Build the IPA only, don't upload
#   --team-id ID       Apple Developer Team ID (default: 8LW2EYFXQD)
#   --api-key FILE     App Store Connect API key (.p8)
#   --api-issuer ID    App Store Connect API issuer ID
#   --api-key-id ID    App Store Connect API key ID
#
# github options (always builds an unsigned Release IPA):
#   --tag TAG          Git tag for the release (required)
#   --dry-run          Print the gh command instead of creating the release
set -euo pipefail
cd "$(dirname "$0")/../.."
source "OpenTaiko.iOS/scripts/_signing-helpers.sh"

CSPROJ="OpenTaiko.iOS/OpenTaiko.iOS.csproj"

# ---- target (first positional arg) -------------------------------------------------------
TARGET="sim"
if [[ $# -gt 0 && "$1" != --* ]]; then
  TARGET="$1"; shift
fi
case "$TARGET" in
  sim|device|ipa|testflight|github) ;;
  *) echo "Unknown target: $TARGET (expected sim|device|ipa|testflight|github)"; exit 1 ;;
esac

# ---- options -----------------------------------------------------------------------------
BUNDLE_ID=""
IDENTITY=""
DEVICE=""
UDID=""
IMOBILE=false
CLEAN=false
BUILD=true
VERBOSE=false
CONFIG="Debug"
TIMEOUT=""           # per-target default applied below
SCREENSHOT=""
WAIT=20
OUTPUT=""             # per-target default applied below
SIGN="none"
UPLOAD=true
TEAM_ID="8LW2EYFXQD"
API_KEY=""
API_ISSUER=""
API_KEY_ID=""
TAG=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)      CLEAN=true; shift ;;
    --no-build)   BUILD=false; shift ;;
    --release)    CONFIG="Release"; shift ;;
    --bundle-id)  BUNDLE_ID="$2"; shift 2 ;;
    --verbose)    VERBOSE=true; shift ;;
    --device)     DEVICE="$2"; shift 2 ;;
    --udid)       UDID="$2"; IMOBILE=true; shift 2 ;;
    --imobile)    IMOBILE=true; shift ;;
    --timeout)    TIMEOUT="$2"; shift 2 ;;
    --identity)   IDENTITY="$2"; shift 2 ;;
    --screenshot) SCREENSHOT="${2:-/tmp/opentaiko.png}"; shift; [[ "${1:-}" != --* && -n "${1:-}" ]] && shift || true ;;
    --wait)       WAIT="$2"; shift 2 ;;
    --output)     OUTPUT="$2"; shift 2 ;;
    --sign)       SIGN="$2"; shift 2 ;;
    --no-upload)  UPLOAD=false; shift ;;
    --team-id)    TEAM_ID="$2"; shift 2 ;;
    --api-key)    API_KEY="$2"; shift 2 ;;
    --api-issuer) API_ISSUER="$2"; shift 2 ;;
    --api-key-id) API_KEY_ID="$2"; shift 2 ;;
    --tag)        TAG="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Resolve bundle ID and the matching dotnet -p:ApplicationId override (if any).
DEFAULT_BUNDLE_ID=$(grep '<ApplicationId' "$CSPROJ" | sed 's/.*>\(.*\)<.*/\1/')
APP_ID="${BUNDLE_ID:-$DEFAULT_BUNDLE_ID}"
BUNDLE_ID_ARG=()
[[ -n "$BUNDLE_ID" && "$BUNDLE_ID" != "$DEFAULT_BUNDLE_ID" ]] && BUNDLE_ID_ARG=(-p:ApplicationId="$BUNDLE_ID")

# ==========================================================================================
#  Shared helpers
# ==========================================================================================

# Download/build native dependencies (BASS xcframeworks, liblua54) if missing.
bootstrap_ios_deps() {
  [[ -d "OpenTaiko.iOS/Libs/bass24-ios" ]] || bash OpenTaiko.iOS/scripts/download-bass.sh
  [[ -d "OpenTaiko.iOS/Frameworks/liblua54.xcframework" ]] || bash OpenTaiko.iOS/scripts/build-lua54.sh
}

# ios_build <config> <rid> [extra dotnet args...]
# Builds the app, prints a filtered summary, and verifies it succeeded.
# Sets the global APP_PATH. Returns non-zero on any build failure (a stale .app from a
# previous build is NOT treated as success — the dotnet exit code is authoritative).
ios_build() {
  local config="$1" rid="$2"; shift 2
  APP_PATH="OpenTaiko.iOS/bin/${config}/net10.0-ios/${rid}/OpenTaiko.iOS.app"
  bootstrap_ios_deps
  local log rc attempt
  log=$(mktemp)
  for attempt in 1 2; do
    echo "==> Building $rid ($config)..."
    rc=0  # `|| rc=$?` keeps `set -e`/pipefail from aborting before we capture the status
    if $VERBOSE; then
      dotnet build "$CSPROJ" -c "$config" -r "$rid" "$@" 2>&1 | tee "$log" || rc=$?
    else
      dotnet build "$CSPROJ" -c "$config" -r "$rid" "$@" > "$log" 2>&1 || rc=$?
      { grep -E "(error CS|error MT|error MSB|Error\(s\)|Build succeeded)" "$log" || true; } | tail -10
    fi
    if [[ $rc -eq 0 && -d "$APP_PATH" ]]; then
      rm -f "$log"; return 0
    fi
    # The MSBuild build server occasionally holds a lock on a dependency project's
    # deps.json ("being used by another process" / GenerateDepsFile). Shut it down and
    # retry once before treating the build as failed.
    if [[ $attempt -eq 1 ]] && grep -q "being used by another process\|GenerateDepsFile" "$log"; then
      echo "==> Transient build-server file lock detected; shutting it down and retrying once..."
      dotnet build-server shutdown >/dev/null 2>&1 || true
      sleep 1
      continue
    fi
    break
  done
  echo "Build failed (dotnet exit ${rc:-?}). Full build output:"
  echo "----------------------------------------"; cat "$log"; echo "----------------------------------------"
  rm -f "$log"; return 1
}

# make_ipa <app_src> <output.ipa> [strip_signature(true|false)]
make_ipa() {
  local app_src="$1" out="$2" strip="${3:-false}"
  mkdir -p "$(dirname "$out")"
  local tmp; tmp=$(mktemp -d)
  mkdir -p "$tmp/Payload"
  cp -R "$app_src" "$tmp/Payload/"
  if [[ "$strip" == "true" ]]; then
    # App Store / unsigned IPAs must not carry stale signing artifacts.
    rm -rf "$tmp/Payload/$(basename "$app_src")/_CodeSignature"
    rm -f "$tmp/Payload/$(basename "$app_src")/embedded.mobileprovision"
  fi
  (cd "$tmp" && zip -qr ipa.zip Payload)
  mv "$tmp/ipa.zip" "$out"
  rm -rf "$tmp"
  echo "==> IPA: $out ($(du -h "$out" | awk '{print $1}'))"
}

# make_dsym_zip <app_src> <output.ipa>  ->  writes <output_base>.dSYM.zip next to the ipa.
make_dsym_zip() {
  local app_src="$1" ipa_out="$2"
  local dsym_src="${app_src}.dSYM"
  local dsym_zip="${ipa_out%.ipa}.dSYM.zip"
  if [[ -d "$dsym_src" ]]; then
    local tmp; tmp=$(mktemp -d)
    cp -R "$dsym_src" "$tmp/"
    (cd "$tmp" && zip -qr dsym.zip "$(basename "$dsym_src")")
    mv "$tmp/dsym.zip" "$dsym_zip"
    rm -rf "$tmp"
    echo "==> dSYM zip: $dsym_zip ($(du -h "$dsym_zip" | awk '{print $1}'))"
  else
    echo "Warning: dSYM not found at $dsym_src, skipping dSYM zip."
  fi
}

# Stream a process's console for N seconds then stop (N=0 streams until Ctrl-C).
# stream_console <timeout> <launch-cmd...>
stream_console() {
  local timeout="$1"; shift
  if [[ "$timeout" -eq 0 ]]; then
    echo "==> Launching (console output below, Ctrl-C to stop)..."
    "$@"
  else
    echo "==> Launching (showing ${timeout}s of console output)..."
    "$@" &
    local pid=$!
    sleep "$timeout"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    echo "==> Console timeout reached."
  fi
}

# ==========================================================================================
#  Target: sim
# ==========================================================================================
do_sim() {
  : "${TIMEOUT:=10}"
  local dev="${DEVICE:-booted}"

  if ! xcrun simctl list devices booted | grep -q "Booted"; then
    echo "No simulator booted. Boot one with: OpenTaiko.iOS/scripts/sim-boot.sh"
    exit 1
  fi

  $BUILD && ios_build "$CONFIG" iossimulator-arm64 "${BUNDLE_ID_ARG[@]}"
  APP_PATH="OpenTaiko.iOS/bin/${CONFIG}/net10.0-ios/iossimulator-arm64/OpenTaiko.iOS.app"

  echo "==> Terminating existing app..."
  xcrun simctl terminate "$dev" "$APP_ID" 2>/dev/null || true
  if $CLEAN; then
    echo "==> Uninstalling previous app..."
    xcrun simctl uninstall "$dev" "$APP_ID" 2>/dev/null || true
  fi

  echo "==> Installing..."
  xcrun simctl install "$dev" "$APP_PATH"

  if [[ -n "$SCREENSHOT" ]]; then
    echo "==> Launching in background..."
    xcrun simctl launch "$dev" "$APP_ID"
    echo "==> Waiting ${WAIT}s before screenshot..."
    sleep "$WAIT"
    echo "==> Taking screenshot -> $SCREENSHOT"
    xcrun simctl io "$dev" screenshot "$SCREENSHOT"
    # Simulator always captures portrait; rotate to match the game's landscape orientation.
    local orientation
    orientation=$(xcrun simctl spawn "$dev" launchctl getenv SIMULATOR_DEVICE_ORIENTATION 2>/dev/null || true)
    [[ -z "$orientation" ]] && orientation="LandscapeLeft"
    case "$orientation" in
      LandscapeLeft|UIInterfaceOrientationLandscapeLeft)   sips -r 90  "$SCREENSHOT" >/dev/null 2>&1 && echo "==> Rotated screenshot to landscape." ;;
      LandscapeRight|UIInterfaceOrientationLandscapeRight) sips -r 270 "$SCREENSHOT" >/dev/null 2>&1 && echo "==> Rotated screenshot to landscape." ;;
    esac
    echo "==> Done. App is still running in the simulator."
  else
    stream_console "$TIMEOUT" xcrun simctl launch --console "$dev" "$APP_ID"
  fi
}

# ==========================================================================================
#  Target: device
# ==========================================================================================
do_device() {
  : "${TIMEOUT:=30}"

  # Resolve the target device.
  if $IMOBILE; then
    if [[ -z "$UDID" ]]; then
      UDID=$(idevice_id -l 2>/dev/null | head -1)
      [[ -z "$UDID" ]] && { echo "No device found via idevice_id."; exit 1; }
      echo "==> Found device (libimobiledevice): $UDID"
    fi
  else
    if [[ -z "$DEVICE" ]]; then
      DEVICE=$(xcrun devicectl list devices 2>/dev/null | { grep -E '(available|connected).*paired|connected' || true; } | awk '{for(i=1;i<=NF;i++) if($i ~ /^[A-F0-9]{8}-/) print $i}' | head -1)
      if [[ -z "$DEVICE" ]]; then
        echo "No device found via devicectl. Use --imobile for libimobiledevice."
        echo ""; echo "Available devices:"; xcrun devicectl list devices 2>&1
        exit 1
      fi
      echo "==> Found device: $DEVICE"
    fi
  fi

  if [[ -z "$IDENTITY" ]]; then
    IDENTITY=$(find_codesign_identity "Apple Development")
    echo "==> Using identity: $IDENTITY"
  fi

  if $BUILD; then
    ios_build "$CONFIG" ios-arm64 \
      -p:RuntimeIdentifier=ios-arm64 \
      -p:CodesignKey="$IDENTITY" \
      -p:CodesignProvision="" \
      "${BUNDLE_ID_ARG[@]}"
  fi
  APP_PATH="OpenTaiko.iOS/bin/${CONFIG}/net10.0-ios/ios-arm64/OpenTaiko.iOS.app"

  if $IMOBILE; then
    local udid_flag=(); [[ -n "$UDID" ]] && udid_flag=(-u "$UDID")
    if $CLEAN; then
      echo "==> Uninstalling previous app..."
      ideviceinstaller "${udid_flag[@]}" uninstall "$APP_ID" 2>/dev/null || true
    fi
    local ipa_tmp; ipa_tmp=$(mktemp -d); trap "rm -rf $ipa_tmp" RETURN
    make_ipa "$APP_PATH" "$ipa_tmp/app.ipa"
    echo "==> Installing via ideviceinstaller..."
    ideviceinstaller "${udid_flag[@]}" install "$ipa_tmp/app.ipa"
    echo "==> Installed. Launch the app manually on the device."
    echo "    (ideviceinstaller does not support remote launch)"
  else
    if $CLEAN; then
      echo "==> Uninstalling previous app..."
      xcrun devicectl device uninstall app --device "$DEVICE" "$APP_ID" 2>/dev/null || true
    fi
    echo "==> Installing on device..."
    xcrun devicectl device install app --device "$DEVICE" "$APP_PATH" 2>&1 | tail -3
    stream_console "$TIMEOUT" xcrun devicectl device process launch --device "$DEVICE" --console "$APP_ID"
  fi
}

# Read a single-line <Field>value</Field> from the .csproj.
read_csproj_field() { grep "<$1>" "$CSPROJ" | sed "s/.*<$1>\(.*\)<\/$1>.*/\1/"; }

# Build Release ios-arm64 with the requested signing and package it to $OUTPUT (+ dSYM zip).
# build_and_package_ipa  (uses globals SIGN, OUTPUT, IDENTITY, BUILD, BUNDLE_ID_ARG)
build_and_package_ipa() {
  CONFIG="Release"  # distribution packaging is always Release
  local sign_args=() strip="false"
  case "$SIGN" in
    none)
      sign_args=(-p:EnableCodeSigning=false); strip="true" ;;
    development|distribution)
      local pref; [[ "$SIGN" == "distribution" ]] && pref="Apple Distribution" || pref="Apple Development"
      [[ -z "$IDENTITY" ]] && IDENTITY=$(find_codesign_identity "$pref")
      echo "==> Signing identity: $IDENTITY"
      sign_args=(-p:CodesignKey="$IDENTITY" -p:CodesignProvision="") ;;
    *) echo "Unknown --sign mode: $SIGN (expected none|development|distribution)"; exit 1 ;;
  esac

  if $BUILD; then
    ios_build Release ios-arm64 -p:RuntimeIdentifier=ios-arm64 "${sign_args[@]}" "${BUNDLE_ID_ARG[@]}"
  fi
  APP_PATH="OpenTaiko.iOS/bin/Release/net10.0-ios/ios-arm64/OpenTaiko.iOS.app"
  [[ -d "$APP_PATH" ]] || { echo "Error: $APP_PATH not found (build skipped or failed)."; exit 1; }

  make_ipa "$APP_PATH" "$OUTPUT" "$strip"
  make_dsym_zip "$APP_PATH" "$OUTPUT"
}

# ==========================================================================================
#  Target: ipa  (release packaging)
# ==========================================================================================
do_ipa() {
  : "${OUTPUT:=OpenTaiko.iOS/dist/OpenTaiko_unsigned.ipa}"
  build_and_package_ipa
}

# ==========================================================================================
#  Target: testflight  (distribution-signed IPA -> App Store Connect)
# ==========================================================================================
do_testflight() {
  : "${OUTPUT:=OpenTaiko.iOS/dist/OpenTaiko.ipa}"
  SIGN="distribution"
  [[ -z "$IDENTITY" ]] && IDENTITY=$(find_codesign_identity "Apple Distribution")

  echo "==> OpenTaiko TestFlight Publisher"
  echo "    Version:   $(read_csproj_field ApplicationDisplayVersion) ($(read_csproj_field ApplicationVersion))"
  echo "    Bundle ID: $APP_ID"
  echo "    Team:      $TEAM_ID"
  echo ""

  build_and_package_ipa

  if ! $UPLOAD; then
    echo "==> Skipping upload (--no-upload). IPA is ready at: $OUTPUT"
    return
  fi
  if [[ -z "$API_KEY" || -z "$API_ISSUER" || -z "$API_KEY_ID" ]]; then
    echo ""
    echo "==> Upload skipped: App Store Connect API credentials not provided."
    echo "    Provide all three: --api-key KEY.p8  --api-issuer ISSUER_ID  --api-key-id KEY_ID"
    echo "    Or upload manually:"
    echo "      xcrun altool --upload-app -f '$OUTPUT' -t ios --apiKey KEY_ID --apiIssuer ISSUER_ID"
    echo "    IPA is ready at: $OUTPUT"
    return
  fi

  echo "==> Validating IPA..."
  xcrun altool --validate-app -f "$OUTPUT" -t ios --apiKey "$API_KEY_ID" --apiIssuer "$API_ISSUER" 2>&1
  echo "==> Uploading to App Store Connect..."
  xcrun altool --upload-app -f "$OUTPUT" -t ios --apiKey "$API_KEY_ID" --apiIssuer "$API_ISSUER" 2>&1
  echo "==> Upload complete! Check TestFlight in App Store Connect for processing status."
}

# ==========================================================================================
#  Target: github  (unsigned IPA + dSYM -> GitHub release)
# ==========================================================================================
do_github() {
  [[ -n "$TAG" ]] || { echo "Error: github target requires --tag TAG."; exit 1; }
  : "${OUTPUT:=OpenTaiko.iOS/dist/OpenTaiko_unsigned.ipa}"
  SIGN="none"

  build_and_package_ipa

  local assets=("$OUTPUT")
  local dsym_zip="${OUTPUT%.ipa}.dSYM.zip"
  if [[ -f "$dsym_zip" ]]; then
    assets+=("$dsym_zip")
    echo "==> dSYM zip will be attached: $dsym_zip"
  else
    echo "Warning: dSYM zip not found — release will not include symbols."
  fi

  echo "==> Preparing GitHub release for tag: $TAG"
  if $DRY_RUN; then
    echo "[DRY RUN] gh release create \"$TAG\" ${assets[*]} --title \"$TAG\" --generate-notes"
  else
    gh release create "$TAG" "${assets[@]}" --title "$TAG" --generate-notes
    echo "==> Release created successfully!"
  fi
}

case "$TARGET" in
  sim)        do_sim ;;
  device)     do_device ;;
  ipa)        do_ipa ;;
  testflight) do_testflight ;;
  github)     do_github ;;
esac
