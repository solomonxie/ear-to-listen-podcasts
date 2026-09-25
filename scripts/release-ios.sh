#!/bin/sh
# Archive a Release build and hand it to App Store Connect in one go.
#
# The user-visible version is MARKETING_VERSION in project.yml; the build number is a
# timestamp, so every upload sorts above the last one without editing anything.
#
# By default the export *is* the upload (`destination: upload` in ExportOptions.plist),
# signed and delivered through the Apple ID in Xcode > Settings > Accounts. That account
# is already there to sign the build, so a release needs no second credential and nothing
# secret on disk.
#
# Secrets come from the environment (or .env.local, which is gitignored) — never git:
#   DEVELOPMENT_TEAM          required, Apple Developer Team ID
#   ASC_KEY_ID + ASC_ISSUER_ID            upload with an App Store Connect API key
#   APPLE_ID   + APP_SPECIFIC_PASSWORD    upload with an Apple ID instead
# Either pair takes over from the Xcode account — that is the headless path, for a machine
# nobody is signed in on. NO_UPLOAD=1 stops at the .ipa, for an upload going through
# Transporter by hand.
#
# Usage: scripts/release-ios.sh [build-number]
set -e
cd "$(dirname "$0")/.."

[ -f .env.local ] && . ./.env.local

: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM (Apple Developer Team ID) in the environment or .env.local}"

SCHEME=EarToListen
BUILD=${1:-$(date +%Y%m%d%H%M)}
OUT=/tmp/eartolisten-release/$BUILD
ARCHIVE=$OUT/$SCHEME.xcarchive
EXPORT_PLIST=$OUT/ExportOptions.plist

mkdir -p "$OUT"
sed "s/REPLACE_WITH_YOUR_TEAM_ID/$DEVELOPMENT_TEAM/" ExportOptions.plist > "$EXPORT_PLIST"

if [ -n "$NO_UPLOAD" ] ||
   { [ -n "$ASC_KEY_ID" ] && [ -n "$ASC_ISSUER_ID" ]; } ||
   { [ -n "$APPLE_ID" ] && [ -n "$APP_SPECIFIC_PASSWORD" ]; }; then
  UPLOAD_ON_EXPORT=
  /usr/libexec/PlistBuddy -c "Set :destination export" "$EXPORT_PLIST"
else
  UPLOAD_ON_EXPORT=1
fi

xcodegen generate

xcodebuild -project "$SCHEME.xcodeproj" -scheme "$SCHEME" \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" -skipPackagePluginValidation -skipMacroValidation \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CURRENT_PROJECT_VERSION="$BUILD" archive

xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$EXPORT_PLIST" -exportPath "$OUT/export" \
  -allowProvisioningUpdates

if [ -n "$UPLOAD_ON_EXPORT" ]; then
  echo "Uploaded build $BUILD. App Store Connect takes 15-60 min to finish processing it."
  exit 0
fi

IPA=$OUT/export/$SCHEME.ipa
du -h "$IPA"

if [ -n "$NO_UPLOAD" ]; then
  echo
  echo "NO_UPLOAD set — stopping at the .ipa:"
  echo "  $IPA"
  exit 0
elif [ -n "$ASC_KEY_ID" ] && [ -n "$ASC_ISSUER_ID" ]; then
  xcrun altool --upload-app -f "$IPA" -t ios \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
elif [ -n "$APPLE_ID" ] && [ -n "$APP_SPECIFIC_PASSWORD" ]; then
  xcrun altool --upload-app -f "$IPA" -t ios \
    -u "$APPLE_ID" -p "$APP_SPECIFIC_PASSWORD"
else
  echo
  echo "No upload credentials set. Drag this into Transporter.app and hit Deliver:"
  echo "  $IPA"
  exit 0
fi

echo "Uploaded build $BUILD. App Store Connect takes 15-60 min to finish processing it."
