#!/bin/sh
# Build and install onto the paired iPhone — never a simulator.
# Usage: scripts/install-ios-device.sh [device-udid]   (defaults to the only paired device)
set -e
cd "$(dirname "$0")/.."

[ -f .env.local ] && . ./.env.local

UDID=${1:-$(xcrun devicectl list devices 2>/dev/null | grep physical \
  | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}' \
  | head -1)}
: "${UDID:?no paired iPhone found — plug one in and trust this Mac}"
: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM (Apple Developer Team ID) in the environment or .env.local}"

CONFIG=${CONFIG:-Debug}
# Storefront the build pretends to be in (Debug only; Release asks StoreKit). CHN hides
# the AI vendors the China App Store doesn't allow.
STOREFRONT=${STOREFRONT:-USA}
# CARPLAY=1 signs with the CarPlay audio entitlement. Apple has to grant it to the team
# first; until then the provisioning profile can't carry it and signing fails.
ENTITLEMENTS=Sources/App/EarToListen.entitlements
[ "${CARPLAY:-0}" = 1 ] && ENTITLEMENTS=Sources/App/EarToListen-CarPlay.entitlements

xcodegen generate
xcodebuild -project EarToListen.xcodeproj -scheme EarToListen \
  -configuration "$CONFIG" -destination "id=$UDID" \
  -skipPackagePluginValidation -skipMacroValidation -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" EAR_STOREFRONT="$STOREFRONT" \
  APP_ENTITLEMENTS="$ENTITLEMENTS" -derivedDataPath build/dd-install build

# Same bundle id, upgraded in place: the app's data on the phone is kept.
xcrun devicectl device install app --device "$UDID" \
  "build/dd-install/Build/Products/$CONFIG-iphoneos/EarToListen.app"
