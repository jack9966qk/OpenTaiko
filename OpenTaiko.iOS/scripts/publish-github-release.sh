#!/usr/bin/env bash
# Package an unsigned .ipa and upload it as a new GitHub release.
# Usage: ./OpenTaiko.iOS/scripts/publish-github-release.sh --tag TAG [options]
#   --dry-run      Do a dry run, don't actually create the release
#   --no-build     Skip building the IPA
#   --tag TAG      The tag to use for the release (required)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

cd "$PROJECT_ROOT"

DRY_RUN=false
BUILD=true
TAG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --no-build) BUILD=false; shift ;;
    --tag) TAG="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$TAG" ]]; then
  echo "Error: The --tag parameter is required."
  echo "Usage: $0 --tag TAG [--dry-run] [--no-build]"
  exit 1
fi

IPA_PATH="OpenTaiko.iOS/dist/OpenTaiko_unsigned.ipa"
DSYM_ZIP_PATH="OpenTaiko.iOS/dist/OpenTaiko_unsigned.dSYM.zip"

if $BUILD; then
  echo "==> Building unsigned IPA + dSYM zip..."
  bash OpenTaiko.iOS/scripts/package-ipa.sh --output "$IPA_PATH"
fi

if [[ ! -f "$IPA_PATH" ]]; then
  echo "Error: IPA not found at $IPA_PATH"
  exit 1
fi

RELEASE_ASSETS=("$IPA_PATH")
if [[ -f "$DSYM_ZIP_PATH" ]]; then
  RELEASE_ASSETS+=("$DSYM_ZIP_PATH")
  echo "==> dSYM zip will be attached: $DSYM_ZIP_PATH"
else
  echo "Warning: dSYM zip not found at $DSYM_ZIP_PATH — release will not include symbols."
fi

echo "==> Preparing GitHub Release for tag: $TAG"

if $DRY_RUN; then
  echo "[DRY RUN] Would execute:"
  echo "gh release create \"$TAG\" ${RELEASE_ASSETS[*]} --title \"$TAG\" --generate-notes"
else
  echo "==> Uploading release to GitHub..."
  gh release create "$TAG" "${RELEASE_ASSETS[@]}" --title "$TAG" --generate-notes
  echo "==> Release created successfully!"
fi
