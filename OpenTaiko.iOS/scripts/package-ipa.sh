#!/usr/bin/env bash
# Package the release .app into an unsigned .ipa for distribution.
# Usage: ./OpenTaiko.iOS/scripts/package-ipa.sh [--output PATH]
#   --output PATH   Output .ipa path (default: OpenTaiko.iOS/dist/OpenTaiko.ipa)
#   --no-build      Skip the release build step
set -euo pipefail
cd "$(dirname "$0")/../.."

OUTPUT="OpenTaiko.iOS/dist/OpenTaiko.ipa"
BUILD=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)   OUTPUT="$2"; shift 2 ;;
    --no-build) BUILD=false; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

APP_SRC="OpenTaiko.iOS/bin/Release/net8.0-ios/ios-arm64/OpenTaiko.iOS.app"

# Build release if needed
if $BUILD; then
  # Ensure liblua54 xcframework exists
  if [[ ! -d "OpenTaiko.iOS/Frameworks/liblua54.xcframework" ]]; then
    bash OpenTaiko.iOS/scripts/build-lua54.sh
  fi

  echo "==> Building Release for ios-arm64..."
  dotnet build OpenTaiko.iOS/OpenTaiko.iOS.csproj \
    -c Release \
    -r ios-arm64 \
    -p:RuntimeIdentifier=ios-arm64 \
    -p:CodesignKey="Apple Development" \
    -p:CodesignProvision="" \
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

# Copy .app to temp location and strip code signature
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

echo "==> Copying .app..."
cp -R "$APP_SRC" "$TMPDIR/OpenTaiko.iOS.app"

echo "==> Removing code signature..."
codesign --remove-signature "$TMPDIR/OpenTaiko.iOS.app"
rm -rf "$TMPDIR/OpenTaiko.iOS.app/_CodeSignature"
rm -f "$TMPDIR/OpenTaiko.iOS.app/embedded.mobileprovision"

# Package as .ipa
echo "==> Creating IPA..."
mkdir -p "$TMPDIR/Payload"
mv "$TMPDIR/OpenTaiko.iOS.app" "$TMPDIR/Payload/"
(cd "$TMPDIR" && zip -qr ipa.zip Payload)
mv "$TMPDIR/ipa.zip" "$OUTPUT"

echo "==> Done: $OUTPUT ($(du -h "$OUTPUT" | awk '{print $1}'))"
