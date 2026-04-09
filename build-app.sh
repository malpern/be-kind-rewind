#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

echo "Building VideoOrganizer..."
swift build

DISCOVERY_VENV=".runtime/discovery-venv"
DISCOVERY_PYTHON="$DISCOVERY_VENV/bin/python3"
DISCOVERY_REQUIREMENTS="scripts/requirements-discovery.txt"

echo "Preparing discovery Python environment..."
/usr/bin/python3 -m venv "$DISCOVERY_VENV"
"$DISCOVERY_PYTHON" -m pip install --upgrade pip >/dev/null
"$DISCOVERY_PYTHON" -m pip install -r "$DISCOVERY_REQUIREMENTS" >/dev/null

BUILT_APP=".build/debug/VideoOrganizerApp"
if [[ ! -x "$BUILT_APP" ]]; then
  echo "error: expected built app at $BUILT_APP" >&2
  exit 1
fi

APP_DIR="Be Kind, Rewind.app"
PACKAGED_APP="$APP_DIR/Contents/MacOS/VideoOrganizerApp"
DEFAULT_SIGNING_IDENTITY="Apple Development: Micah Alpern (3YFH89N33S)"
SIGNING_IDENTITY="${CODESIGN_IDENTITY:-$DEFAULT_SIGNING_IDENTITY}"
LEGACY_APP_DIR="Video Organizer.app"

if [[ -d "$LEGACY_APP_DIR" && ! -d "$APP_DIR" ]]; then
  mv "$LEGACY_APP_DIR" "$APP_DIR"
fi

if pgrep -f "$PACKAGED_APP" >/dev/null 2>&1; then
  echo "Stopping running app process..."
  pkill -f "$PACKAGED_APP"
  sleep 1
fi

echo "Packaging into $APP_DIR..."
install -m 755 "$BUILT_APP" "$PACKAGED_APP"

/usr/libexec/PlistBuddy -c "Set :CFBundleName Be Kind, Rewind" "$APP_DIR/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Be Kind, Rewind" "$APP_DIR/Contents/Info.plist" >/dev/null

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
