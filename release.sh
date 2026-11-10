#!/bin/zsh
# Builds Maben Sweep for download: universal (Apple silicon + Intel), hardened runtime, signed with the
# Developer ID and notarized by Apple, so it opens with no "unidentified developer" warning.
# Output: dist/Maben-Sweep.dmg (drag to Applications) and dist/Maben-Sweep.zip.
#
# Everything goes through the Apple account signed in to Xcode (Settings → Apple Accounts): Xcode's
# cloud-managed Developer ID certificate signs it and Xcode uploads it for notarization, so no certificate
# or app password is needed on this Mac. Needs the Apple Developer Program on that team, and xcodegen.
set -e
cd "$(dirname "$0")"
TEAM="${TEAM:-NJTYRVLSA8}"
OUT=build/archive
ARCHIVE="$OUT/MabenSweep.xcarchive"

./build.sh >/dev/null            # compile check + app icon (build/AppIcon.icns)
swift test 2>&1 | grep -E "Executed .* tests" | tail -1
swift test 2>&1 | grep -q "with 0 failures" || { echo "Tests failed."; exit 1; }

rm -rf "$OUT" MabenSweep.xcodeproj
mkdir -p "$OUT"
# Unique build number per build: macOS only refreshes its login-item record when the version changes.
cp Info.plist build/Info-release.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M%S)" build/Info-release.plist
xcodegen generate --quiet

echo "Building (Apple silicon + Intel)…"
xcodebuild -project MabenSweep.xcodeproj -scheme MabenSweep -configuration Release \
  -derivedDataPath build/archive-dd -archivePath "$ARCHIVE" -quiet \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_IDENTITY="Apple Development" \
  OTHER_CODE_SIGN_FLAGS=--timestamp \
  -allowProvisioningUpdates archive 2>&1 | grep -vE "^\{ platform|IDERunDestination|Using the first of multiple" || true
[[ -d "$ARCHIVE/Products/Applications/Maben Sweep.app" ]] || { echo "Build failed."; exit 1; }

cat > "$OUT/upload.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>signingStyle</key><string>automatic</string>
<key>teamID</key><string>$TEAM</string>
<key>destination</key><string>upload</string>
</dict></plist>
PLIST

echo "Signing with Developer ID and uploading to Apple for notarization…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/upload" -exportOptionsPlist "$OUT/upload.plist" \
  -allowProvisioningUpdates 2>&1 | grep -E "EXPORT|error" || true

echo "Waiting for Apple (usually 1–5 minutes)…"
for i in {1..40}; do
  if xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$OUT/notarized" >"$OUT/notarize.log" 2>&1; then break; fi
  if ! grep -q "processing" "$OUT/notarize.log"; then cat "$OUT/notarize.log"; echo "Notarization failed."; exit 1; fi
  sleep 20
done
APP="$OUT/notarized/Maben Sweep.app"
[[ -d "$APP" ]] || { echo "Timed out waiting for Apple; run again later."; exit 1; }

xcrun stapler validate "$APP" >/dev/null
spctl --assess --type exec "$APP"

VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
mkdir -p dist
ZIP="dist/Maben-Sweep.zip"
rm -f dist/Maben-Sweep.zip dist/Maben-Sweep.dmg
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# Disk image: the app beside a link to Applications, so installing is one drag. The app inside is the
# notarized, stapled one, which is what Gatekeeper checks.
DMG="dist/Maben-Sweep.dmg"
STAGE="$OUT/dmg"
rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Maben Sweep.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Maben Sweep" -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "$DMG"

rm -rf MabenSweep.xcodeproj
echo "Built Maben Sweep $VERSION: $DMG and $ZIP (universal, signed by Developer ID, notarized and stapled)"
