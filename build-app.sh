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

echo "Built binary:    $(/usr/bin/stat -f '%Sm %N' -t '%Y-%m-%d %H:%M:%S' "$BUILT_APP")"
echo "Packaged binary: $(/usr/bin/stat -f '%Sm %N' -t '%Y-%m-%d %H:%M:%S' "$PACKAGED_APP")"

echo "Done. Launch with: open \"$APP_DIR\""
