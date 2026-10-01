#!/bin/sh
# Xcode build phase: copies the DEMO_* lines of .env.demo into the app as DemoSecrets.plist,
# for demo mode to connect a bucket and an AI key. Never in Release — there the file is
# removed, so an App Store build can't carry it even from a stale build folder.
set -e
OUT="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/DemoSecrets.plist"
rm -f "$OUT"
[ "$CONFIGURATION" != Release ] || exit 0
ENV_FILE="$SRCROOT/.env.demo"
[ -f "$ENV_FILE" ] || { echo "note: no .env.demo — demo mode has no bucket or AI key"; exit 0; }

plutil -create xml1 "$OUT"
grep -E '^DEMO_[A-Z_]+=' "$ENV_FILE" | while IFS='=' read -r key value; do
  value=$(printf '%s' "$value" | sed -e 's/^["'\'']//' -e 's/["'\'']$//')
  plutil -insert "$key" -string "$value" "$OUT"
done
