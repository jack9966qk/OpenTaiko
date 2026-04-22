#!/usr/bin/env bash
# Build a signed IPA and optionally upload to App Store Connect for TestFlight.
#
# Usage: ./OpenTaiko.iOS/scripts/publish-testflight.sh [options]
#   --no-build        Skip dotnet build (reuse existing .app)
#   --no-upload       Build IPA only, don't upload
#   --output PATH     Output .ipa path (default: OpenTaiko.iOS/dist/OpenTaiko.ipa)
#   --team-id ID      Apple Developer Team ID (default: 8LW2EYFXQD)
#   --bundle-id ID    Override bundle identifier
#   --identity NAME   Codesign identity (default: auto-detect "Apple Distribution")
#   --api-key FILE    App Store Connect API key (.p8) for upload
#   --api-issuer ID   App Store Connect API issuer ID
#   --api-key-id ID   App Store Connect API key ID
#
# Prerequisites:
#   - An "Apple Distribution" certificate in your keychain
#   - An App Store provisioning profile installed (~/Library/MobileDevice/Provisioning Profiles/)
#   - For upload: App Store Connect API key (https://appstoreconnect.apple.com/access/api)
#
# The script reads version info from the .csproj so there's a single source of truth.

set -euo pipefail
cd "$(dirname "$0")/../.."
source "OpenTaiko.iOS/scripts/_signing-helpers.sh"

CSPROJ="OpenTaiko.iOS/OpenTaiko.iOS.csproj"
OUTPUT="OpenTaiko.iOS/dist/OpenTaiko.ipa"
TEAM_ID="8LW2EYFXQD"
BUNDLE_ID=""
IDENTITY=""
BUILD=true
UPLOAD=true
API_KEY=""
API_ISSUER=""
API_KEY_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build)     BUILD=false; shift ;;
    --no-upload)    UPLOAD=false; shift ;;
    --output)       OUTPUT="$2"; shift 2 ;;
    --team-id)      TEAM_ID="$2"; shift 2 ;;
    --bundle-id)    BUNDLE_ID="$2"; shift 2 ;;
    --identity)     IDENTITY="$2"; shift 2 ;;
    --api-key)      API_KEY="$2"; shift 2 ;;
    --api-issuer)   API_ISSUER="$2"; shift 2 ;;
    --api-key-id)   API_KEY_ID="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Read version from .csproj (single source of truth)
APP_VERSION=$(grep '<ApplicationDisplayVersion>' "$CSPROJ" | sed 's/.*<ApplicationDisplayVersion>\(.*\)<\/ApplicationDisplayVersion>.*/\1/')
BUILD_NUMBER=$(grep '<ApplicationVersion>' "$CSPROJ" | sed 's/.*<ApplicationVersion>\(.*\)<\/ApplicationVersion>.*/\1/')
DEFAULT_BUNDLE_ID=$(grep '<ApplicationId>' "$CSPROJ" | sed 's/.*<ApplicationId>\(.*\)<\/ApplicationId>.*/\1/')
BUNDLE_ID="${BUNDLE_ID:-$DEFAULT_BUNDLE_ID}"

echo "==> OpenTaiko TestFlight Publisher"
echo "    Version: $APP_VERSION ($BUILD_NUMBER)"
echo "    Bundle ID: $BUNDLE_ID"
echo "    Team: $TEAM_ID"
echo ""

APP_PATH="OpenTaiko.iOS/bin/Release/net10.0-ios/ios-arm64/OpenTaiko.iOS.app"

# Auto-detect signing identity if not provided
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(find_codesign_identity "Apple Distribution")
  echo "    Identity: $IDENTITY"
fi

# --- Build ---
if $BUILD; then
  # Ensure liblua54 xcframework exists
  if [[ ! -d "OpenTaiko.iOS/Frameworks/liblua54.xcframework" ]]; then
    echo "==> Building liblua54..."
    bash OpenTaiko.iOS/scripts/build-lua54.sh
  fi

  BUNDLE_ID_ARG=()
  if [[ -n "$BUNDLE_ID" && "$BUNDLE_ID" != "$DEFAULT_BUNDLE_ID" ]]; then
    BUNDLE_ID_ARG=(-p:ApplicationId="$BUNDLE_ID")
  fi

  echo "==> Building Release for ios-arm64 (distribution signing)..."
  dotnet build "$CSPROJ" \
    -c Release \
    -r ios-arm64 \
    -p:RuntimeIdentifier=ios-arm64 \
    -p:CodesignKey="$IDENTITY" \
    -p:CodesignProvision="" \
    "${BUNDLE_ID_ARG[@]}" \
    2>&1 \
    | grep -E "(error CS|error MT|Error\(s\)|Build succeeded|NETSDK|Codesign)" \
    | tail -10

  if [[ ! -d "$APP_PATH" ]]; then
    echo "Build failed — $APP_PATH not found."
    echo "Re-running with full output..."
    dotnet build "$CSPROJ" \
      -c Release \
      -r ios-arm64 \
      -p:RuntimeIdentifier=ios-arm64 \
      -p:CodesignKey="$IDENTITY" \
      -p:CodesignProvision="" \
      "${BUNDLE_ID_ARG[@]}" \
      2>&1 | tail -40
    exit 1
  fi
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "Error: $APP_PATH not found. Run without --no-build first."
  exit 1
fi

# --- Package IPA ---
echo "==> Packaging IPA..."
mkdir -p "$(dirname "$OUTPUT")"
TMPDIR_IPA=$(mktemp -d)
trap "rm -rf $TMPDIR_IPA" EXIT

mkdir -p "$TMPDIR_IPA/Payload"
cp -R "$APP_PATH" "$TMPDIR_IPA/Payload/"
(cd "$TMPDIR_IPA" && zip -qr ipa.zip Payload)
mv "$TMPDIR_IPA/ipa.zip" "$OUTPUT"

IPA_SIZE=$(du -h "$OUTPUT" | awk '{print $1}')
echo "==> IPA created: $OUTPUT ($IPA_SIZE)"

# --- Upload ---
if ! $UPLOAD; then
  echo "==> Skipping upload (--no-upload). IPA is ready at: $OUTPUT"
  exit 0
fi

# Validate upload credentials
if [[ -z "$API_KEY" || -z "$API_ISSUER" || -z "$API_KEY_ID" ]]; then
  echo ""
  echo "==> Upload skipped: App Store Connect API credentials not provided."
  echo "    To upload, provide all three:"
  echo "      --api-key PATH_TO_KEY.p8"
  echo "      --api-issuer ISSUER_ID"
  echo "      --api-key-id KEY_ID"
  echo ""
  echo "    Or upload manually:"
  echo "      xcrun altool --upload-app -f '$OUTPUT' -t ios --apiKey KEY_ID --apiIssuer ISSUER_ID"
  echo "      # Or use Transporter.app (drag and drop)"
  echo ""
  echo "    IPA is ready at: $OUTPUT"
  exit 0
fi

echo "==> Validating IPA..."
xcrun altool --validate-app \
  -f "$OUTPUT" \
  -t ios \
  --apiKey "$API_KEY_ID" \
  --apiIssuer "$API_ISSUER" \
  2>&1

echo "==> Uploading to App Store Connect..."
xcrun altool --upload-app \
  -f "$OUTPUT" \
  -t ios \
  --apiKey "$API_KEY_ID" \
  --apiIssuer "$API_ISSUER" \
  2>&1

echo "==> Upload complete! Check TestFlight in App Store Connect for processing status."
