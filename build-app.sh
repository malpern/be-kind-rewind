#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

echo "Building VideoOrganizer..."
swift build

BUILT_APP=".build/debug/VideoOrganizerApp"
if [[ ! -x "$BUILT_APP" ]]; then
  echo "error: expected built app at $BUILT_APP" >&2
  exit 1
fi

APP_DIR="Video Organizer.app"
PACKAGED_APP="$APP_DIR/Contents/MacOS/VideoOrganizerApp"
DEFAULT_SIGNING_IDENTITY="Apple Development: Micah Alpern (3YFH89N33S)"
SIGNING_IDENTITY="${CODESIGN_IDENTITY:-$DEFAULT_SIGNING_IDENTITY}"

if pgrep -f "$PACKAGED_APP" >/dev/null 2>&1; then
  echo "Stopping running app process..."
  pkill -f "$PACKAGED_APP"
  sleep 1
fi

echo "Packaging into $APP_DIR..."
install -m 755 "$BUILT_APP" "$PACKAGED_APP"

if ! cmp -s "$BUILT_APP" "$PACKAGED_APP"; then
  echo "error: packaged app does not match fresh build output" >&2
  exit 1
fi

echo "Signing app with: $SIGNING_IDENTITY"
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP_DIR"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"

echo "Built binary:    $(/usr/bin/stat -f '%Sm %N' -t '%Y-%m-%d %H:%M:%S' "$BUILT_APP")"
echo "Packaged binary: $(/usr/bin/stat -f '%Sm %N' -t '%Y-%m-%d %H:%M:%S' "$PACKAGED_APP")"

echo "Done. Launch with: open \"$APP_DIR\""
