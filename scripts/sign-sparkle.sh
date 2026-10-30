#!/bin/zsh
# Re-signs the Sparkle updater inside a built Mailroom Classic.app with the
# Developer ID certificate, then re-signs the app itself so its signature covers them.
#
# Why: Sparkle ships its helper programs (Autoupdate, Updater, Downloader, Installer)
# with a placeholder ("ad-hoc") signature. Xcode's Archive → Export would replace it,
# but this project builds with `xcodebuild build`, so Apple's notarization would reject
# the helpers. Signing goes from the inside out, as Sparkle's documentation describes:
# each helper first, then the framework around them, then the app around that.
#
# Usage (from the repo root):   scripts/sign-sparkle.sh build/release/Build/Products/Release/MailroomClassic.app

set -euo pipefail   # stop at the first command that fails

APP="$1"
IDENTITY="Developer ID Application: Daniel Schultz (57NLMSPMRR)"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"

# -o runtime = the "hardened runtime" notarization requires; --timestamp = Apple's secure timestamp.
sign() { codesign --force --sign "$IDENTITY" -o runtime --timestamp "$@"; }

sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
# The app last, keeping its permissions (e.g. Contacts).
sign --preserve-metadata=entitlements "$APP"

codesign --verify --strict --deep "$APP"
