#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/.build/release"
DIST_DIR="$ROOT/dist"
APP_DIR="$DIST_DIR/OpenClawAssistant.app"
ROOT_APP_DIR="$ROOT/OpenClaw小助手.app"
ICON_SOURCE="$ROOT/Resources/AppIcon.svg"
ICON_FILE="$ROOT/Resources/AppIcon.icns"

generate_icon() {
  local iconset_dir="$ROOT/.build/AppIcon.iconset"

  [[ -f "$ICON_SOURCE" ]] || return 0
  command -v magick >/dev/null 2>&1 || return 0

  rm -rf "$iconset_dir"
  mkdir -p "$iconset_dir"

  local sizes=(16 32 128 256 512)
  for size in "${sizes[@]}"; do
    magick -background none "$ICON_SOURCE" -resize "${size}x${size}" "$iconset_dir/icon_${size}x${size}.png"
    local retina_size=$((size * 2))
    magick -background none "$ICON_SOURCE" -resize "${retina_size}x${retina_size}" "$iconset_dir/icon_${size}x${size}@2x.png"
  done

  iconutil -c icns "$iconset_dir" -o "$ICON_FILE"
}

cd "$ROOT"
swift build -c release --disable-sandbox
generate_icon

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/OpenClawAssistant" "$APP_DIR/Contents/MacOS/OpenClawAssistant"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

if [[ -f "$ICON_FILE" ]]; then
  cp "$ICON_FILE" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

rm -rf "$ROOT_APP_DIR"
ditto "$APP_DIR" "$ROOT_APP_DIR"

echo "Built $APP_DIR"
echo "Synced $ROOT_APP_DIR"
