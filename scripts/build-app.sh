#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-release}"
APP_NAME="VibeCopy"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"

cd "$ROOT_DIR"
swift build -c "$CONFIGURATION"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp ".build/$CONFIGURATION/$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp "Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
find "Resources" -mindepth 1 -maxdepth 1 ! -name "Info.plist" -exec cp -R {} "$RESOURCES_DIR/" \;
chmod +x "$MACOS_DIR/$APP_NAME"

echo "Built $APP_DIR"
