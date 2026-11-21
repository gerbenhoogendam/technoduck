#!/bin/sh
# Builds a universal Technoduck.app signed with your Developer ID and zips it for a GitHub release.
# NOTARY_PROFILE=<notarytool keychain profile> also notarises and staples it, so it opens without a Gatekeeper warning.
set -e
cd "$(dirname "$0")"
SIGN="${SIGN:-Developer ID Application}" UNIVERSAL=1 ./build-app.sh
codesign --verify --strict --verbose=2 Technoduck.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Technoduck.app/Contents/Info.plist)
ZIP="Technoduck-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent Technoduck.app "$ZIP"
if [ -n "$NOTARY_PROFILE" ]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple Technoduck.app
  rm "$ZIP" && ditto -c -k --keepParent Technoduck.app "$ZIP"   # zip again, now with the ticket stapled
  spctl --assess --type execute --verbose Technoduck.app
fi
echo "$ZIP"
