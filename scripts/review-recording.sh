#!/bin/sh
# Records the App Review walkthrough (UITests/ReviewWalkthroughUITests) on a simulator,
# from a fresh install, and compresses it to a small H.264 MP4.
# usage: scripts/review-recording.sh <simulator-udid> [out.mp4]
set -eu
SIM=$1; OUT=${2:-/tmp/eartolisten-build/review-walkthrough.mp4}
DD=/tmp/eartolisten-build/dd-uitest; RAW=/tmp/eartolisten-build/review-raw.mov
BUNDLE_ID=$(sed -n 's/^APP_BUNDLE_ID *= *//p' Config/Local.xcconfig 2>/dev/null)
XCB="xcodebuild -project EarToListen.xcodeproj -scheme ReviewWalkthrough -skipPackagePluginValidation -skipMacroValidation -destination id=$SIM -derivedDataPath $DD"

nice -n 10 $XCB -jobs 4 build-for-testing
[ -n "$BUNDLE_ID" ] && xcrun simctl uninstall "$SIM" "$BUNDLE_ID" || true
xcrun simctl status_bar "$SIM" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 || true
xcrun simctl io "$SIM" recordVideo --codec h264 --force "$RAW" & REC=$!
sleep 2
$XCB test-without-building || STATUS=$?
kill -INT $REC; wait $REC || true
xcrun simctl status_bar "$SIM" clear || true
ffmpeg -v error -y -i "$RAW" -vf "scale=-2:1280" -c:v libx264 -preset slow -crf 30 -pix_fmt yuv420p -an -movflags +faststart "$OUT"
du -h "$OUT"
exit ${STATUS:-0}
