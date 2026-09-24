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

xcodegen generate
xcodebuild -project EarToListen.xcodeproj -scheme EarToListen \
  -configuration "$CONFIG" -destination "id=$UDID" \
  -skipPackagePluginValidation -skipMacroValidation -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" -derivedDataPath build/dd-install build

xcrun devicectl device install app --device "$UDID" \
  "build/dd-install/Build/Products/$CONFIG-iphoneos/EarToListen.app"
