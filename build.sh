#!/bin/sh
# Builds "Maben Sweep.app" into ./build.
#   ./build.sh            -> build only
#   ./build.sh install    -> build, copy to /Applications and open it
#   ./build.sh demo       -> build a debug copy and open it on made-up projects
#                            (reads and changes nothing on disk)
set -e
cd "$(dirname "$0")"

CONFIG=release
[ "$1" = "demo" ] && CONFIG=debug
swift build -c $CONFIG
BIN=$(swift build -c $CONFIG --show-bin-path)/Sweep

# App icon: render once, then build the .icns from the 1024px PNG.
if [ ! -f build/AppIcon.icns ] || [ Resources/make-icon.swift -nt build/AppIcon.icns ]; then
    mkdir -p build/AppIcon.iconset
    swift Resources/make-icon.swift build/icon-1024.png >/dev/null
    for s in 16 32 128 256 512; do
        sips -z $s $s build/icon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
        sips -z $((s*2)) $((s*2)) build/icon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
    done
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi

APP="build/Maben Sweep.app"
[ "$CONFIG" = "debug" ] && APP="build/demo/Maben Sweep.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Sweep"
cp Info.plist "$APP/Contents/Info.plist"
# Unique build number per build: macOS only refreshes its login-item record when the version changes.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M%S)" "$APP/Contents/Info.plist"
cp build/AppIcon.icns CHANGELOG.md "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"

if [ "$1" = "demo" ]; then
    [ -n "$NO_OPEN" ] && exit 0
    open -n "$APP" --args --demo
    exit 0
fi
[ "$1" = "install" ] || exit 0

osascript -e 'quit app "Maben Sweep"' >/dev/null 2>&1 || true
sleep 1
rm -rf "/Applications/Maben Sweep.app"
cp -R "$APP" /Applications/
echo "Installed /Applications/Maben Sweep.app"
open "/Applications/Maben Sweep.app"
