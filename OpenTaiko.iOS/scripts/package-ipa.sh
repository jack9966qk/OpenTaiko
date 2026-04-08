#!/usr/bin/env bash
# Package the release .app into an unsigned .ipa for distribution.
# Usage: ./OpenTaiko.iOS/scripts/package-ipa.sh [options]
#   --output PATH     Output .ipa path (default: OpenTaiko.iOS/dist/OpenTaiko.ipa)
#   --no-build        Skip the release build step
#   --bundle-id ID    Override bundle identifier (default: from .csproj)
set -euo pipefail
cd "$(dirname "$0")/../.."

CSPROJ="OpenTaiko.iOS/OpenTaiko.iOS.csproj"
OUTPUT="OpenTaiko.iOS/dist/OpenTaiko_unsigned.ipa"
BUNDLE_ID="com.opentaiko.mobile"
BUILD=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)     OUTPUT="$2"; shift 2 ;;
    --no-build)   BUILD=false; shift ;;
    --bundle-id)  BUNDLE_ID="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

BUNDLE_ID_ARG=()
if [[ -n "$BUNDLE_ID" ]]; then
  BUNDLE_ID_ARG=(-p:ApplicationId="$BUNDLE_ID")
fi

APP_SRC="OpenTaiko.iOS/bin/Release/net8.0-ios/ios-arm64/OpenTaiko.iOS.app"

# Build release if needed
if $BUILD; then
  # Ensure liblua54 xcframework exists
  if [[ ! -d "OpenTaiko.iOS/Frameworks/liblua54.xcframework" ]]; then
    bash OpenTaiko.iOS/scripts/build-lua54.sh
  fi

  echo "==> Building Release for ios-arm64 (unsigned)..."
  dotnet build "$CSPROJ" \
    -c Release \
    -r ios-arm64 \
    -p:RuntimeIdentifier=ios-arm64 \
    -p:EnableCodeSigning=false \
    "${BUNDLE_ID_ARG[@]}" \
    2>&1 \
    | grep -E "(error CS|error MT|Error\(s\)|Build succeeded)" \
    | tail -5
fi

if [[ ! -d "$APP_SRC" ]]; then
  echo "Error: $APP_SRC not found. Build failed or not run."
  exit 1
fi

# Create output directory
mkdir -p "$(dirname "$OUTPUT")"

# Copy .app to temp location and ensure it's unsigned
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

echo "==> Copying .app..."
cp -R "$APP_SRC" "$TMPDIR/OpenTaiko.iOS.app"

# Clean up any signing artifacts in case the build was reused from a signed run
rm -rf "$TMPDIR/OpenTaiko.iOS.app/_CodeSignature"
rm -f "$TMPDIR/OpenTaiko.iOS.app/embedded.mobileprovision"

# Package as .ipa with embedded dSYM symbols.
# The Symbols/ directory inside the IPA is picked up by altool --upload-app
# and uploaded to App Store Connect for crash symbolication.
echo "==> Creating IPA..."
mkdir -p "$TMPDIR/Payload"
mv "$TMPDIR/OpenTaiko.iOS.app" "$TMPDIR/Payload/"

DSYM_SRC="$APP_SRC.dSYM"
if [[ -d "$DSYM_SRC" ]]; then
  mkdir -p "$TMPDIR/Symbols"
  cp -R "$DSYM_SRC" "$TMPDIR/Symbols/"
  echo "==> dSYM embedded in IPA."
else
  echo "Warning: dSYM not found at $DSYM_SRC, IPA will not contain debug symbols."
fi

(cd "$TMPDIR" && zip -qr ipa.zip Payload $([ -d Symbols ] && echo Symbols))
mv "$TMPDIR/ipa.zip" "$OUTPUT"

echo "==> Done: $OUTPUT ($(du -h "$OUTPUT" | awk '{print $1}'))"
