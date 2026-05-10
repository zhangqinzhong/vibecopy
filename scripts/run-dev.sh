#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="VibeCopy"
APP_DIR="$ROOT_DIR/dist/dev/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"

cd "$ROOT_DIR"

if pgrep -x "$APP_NAME" >/dev/null; then
  echo "Stopping existing $APP_NAME..."
  pkill -x "$APP_NAME"
  sleep 0.2
fi

echo "Building $APP_NAME..."
swift build --product "$APP_NAME"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp ".build/debug/$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp "Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
find "Resources" -mindepth 1 -maxdepth 1 ! -name "Info.plist" -exec cp -R {} "$RESOURCES_DIR/" \;
chmod +x "$MACOS_DIR/$APP_NAME"

echo "Starting $APP_NAME..."
open -n "$APP_DIR"

echo "$APP_NAME launched from $APP_DIR."
