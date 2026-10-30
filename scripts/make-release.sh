#!/bin/zsh
# Builds a Mailroom Classic DMG that opens normally on any Mac: a Release build
# signed with a Developer ID certificate, packed into a disk image, then sent to
# Apple for notarization (Apple's malware check) and "stapled" (Apple's approval
# attached to the DMG, so it opens even offline). Last, it updates appcast.xml,
# the list of versions the built-in updater (Sparkle) checks.
#
# One-time setup (needs an app-specific password from appleid.apple.com):
#   xcrun notarytool store-credentials "MailroomClassic" --apple-id YOU@example.com --team-id YOURTEAMID
# The Sparkle signing key must also be in this Mac's login Keychain (made once with
# Sparkle's generate_keys tool); appcast.xml is signed with it.
#
# Run from the repo root:   scripts/make-release.sh
# The DMG ends up in build/dmg/ (git ignores build/), and appcast.xml is updated in the repo root.
# Then: publish the GitHub release with the DMG FIRST, and only after that commit
# and push appcast.xml (otherwise the updater would offer a download that isn't there yet).

set -euo pipefail   # stop at the first command that fails

TEAM_ID="57NLMSPMRR"
SIGNING_IDENTITY="Developer ID Application"
NOTARY_PROFILE="MailroomClassic"

echo "1/5 Building the Release version…"
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
scripts/sign-sparkle.sh "$APP"   # Sparkle's helpers need the Developer ID signature too
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/dmg/MailroomClassic-$VERSION.dmg"

echo "2/5 Making $DMG…"
rm -rf build/dmg
mkdir -p build/dmg/contents
cp -R "$APP" "build/dmg/contents/Mailroom Classic.app"
ln -s /Applications build/dmg/contents/Applications   # the "drag here to install" shortcut
hdiutil create -volname "Mailroom Classic" -srcfolder build/dmg/contents -ov -format UDZO "$DMG" -quiet
codesign --sign "$SIGNING_IDENTITY: Daniel Schultz ($TEAM_ID)" --timestamp "$DMG"

echo "3/5 Sending it to Apple for notarization (usually a few minutes)…"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "4/5 Attaching Apple's approval…"
xcrun stapler staple "$DMG"
# A final check, the same one macOS runs when someone opens a downloaded app.
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

echo "5/5 Updating appcast.xml (the list of versions the updater checks)…"
# generate_appcast reads the DMG, signs it with the key in the Keychain, and adds it to
# the existing list. The download link points at this version's GitHub release.
rm -rf build/appcast
mkdir -p build/appcast
cp "$DMG" build/appcast/
if [[ -f appcast.xml ]]; then cp appcast.xml build/appcast/; fi
build/release/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --download-url-prefix "https://github.com/EvenDog/MailroomClassic/releases/download/v$VERSION/" \
  --full-release-notes-url "https://github.com/EvenDog/MailroomClassic/releases/tag/v$VERSION" \
  --link "https://github.com/EvenDog/MailroomClassic" \
  build/appcast
cp build/appcast/appcast.xml appcast.xml

echo "Done: $DMG"
