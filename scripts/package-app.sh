#!/bin/sh
set -eu

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/grassIsland-module-cache}"
"$project_root/scripts/swift.sh" build

app_bundle="$project_root/.build/out/Products/Debug/grassIsland.app"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
cp .build/debug/grassIsland "$app_bundle/Contents/MacOS/grassIsland"
cp Resources/Info.plist "$app_bundle/Contents/Info.plist"
cp Resources/grassIsland.icns "$app_bundle/Contents/Resources/grassIsland.icns"
cp Resources/gmail.png "$app_bundle/Contents/Resources/gmail.png"
cp Resources/whatsapp.png "$app_bundle/Contents/Resources/whatsapp.png"
cp Resources/gmail.jpg "$app_bundle/Contents/Resources/gmail.jpg"
cp Resources/whatsapp.jpg "$app_bundle/Contents/Resources/whatsapp.jpg"
cp Resources/camera-activity.png "$app_bundle/Contents/Resources/camera-activity.png"
cp Resources/microphone-activity.png "$app_bundle/Contents/Resources/microphone-activity.png"
codesign --force --deep --sign - "$app_bundle"
printf 'Built app: %s\n' "$app_bundle"
