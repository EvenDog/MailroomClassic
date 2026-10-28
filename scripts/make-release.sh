#!/bin/zsh
# Builds a Mailroom Classic DMG that opens normally on any Mac: a Release build
# signed with a Developer ID certificate, packed into a disk image, then sent to
# Apple for notarization (Apple's malware check) and "stapled" (Apple's approval
# attached to the DMG, so it opens even offline).
#
# One-time setup (needs an app-specific password from appleid.apple.com):
#   xcrun notarytool store-credentials "MailroomClassic" --apple-id YOU@example.com --team-id YOURTEAMID
#
# Run from the repo root:   scripts/make-release.sh
# The DMG ends up in build/dmg/ (git ignores build/).

set -euo pipefail   # stop at the first command that fails

TEAM_ID="57NLMSPMRR"
SIGNING_IDENTITY="Developer ID Application"
NOTARY_PROFILE="MailroomClassic"

echo "1/4 Building the Release version…"
rm -rf build/release
# CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO stops Xcode from adding its "debugger may
# attach" permission (get-task-allow), which Apple refuses to notarize.
# --timestamp adds Apple's secure timestamp, which notarization also requires.
xcodebuild -project MailroomClassic.xcodeproj -scheme MailroomClassic -configuration Release \
  -derivedDataPath build/release \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS="--timestamp" \
  build -quiet
APP="build/release/Build/Products/Release/MailroomClassic.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/dmg/MailroomClassic-$VERSION.dmg"

echo "2/4 Making $DMG…"
rm -rf build/dmg
mkdir -p build/dmg/contents
cp -R "$APP" "build/dmg/contents/Mailroom Classic.app"
ln -s /Applications build/dmg/contents/Applications   # the "drag here to install" shortcut
hdiutil create -volname "Mailroom Classic" -srcfolder build/dmg/contents -ov -format UDZO "$DMG" -quiet
codesign --sign "$SIGNING_IDENTITY: Daniel Schultz ($TEAM_ID)" --timestamp "$DMG"

echo "3/4 Sending it to Apple for notarization (usually a few minutes)…"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "4/4 Attaching Apple's approval…"
xcrun stapler staple "$DMG"
# A final check, the same one macOS runs when someone opens a downloaded app.
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

echo "Done: $DMG"
