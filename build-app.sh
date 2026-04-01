#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "Building VideoOrganizer..."
swift build 2>&1 | tail -3

APP_DIR="Video Organizer.app"
echo "Packaging into $APP_DIR..."
cp .build/debug/VideoOrganizerApp "$APP_DIR/Contents/MacOS/VideoOrganizerApp"
chmod +x "$APP_DIR/Contents/MacOS/VideoOrganizerApp"

echo "Done. Launch with: open \"$APP_DIR\""
