#!/bin/bash
# Capture real UI pixels on a dedicated iPhone 11 Pro Max (1242 × 2688).
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
: "${SCREENSHOT_SIMULATOR_UDID:?Set SCREENSHOT_SIMULATOR_UDID to a dedicated 6.5-inch simulator}"
run_dir=$(mktemp -d /tmp/row-companion-store.XXXXXX)
xcrun simctl bootstatus "$SCREENSHOT_SIMULATOR_UDID" -b
xcrun simctl status_bar "$SCREENSHOT_SIMULATOR_UDID" override --time '9:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
xcrun simctl ui "$SCREENSHOT_SIMULATOR_UDID" appearance light
TEST_RUNNER_RC_CAPTURE_SCREENSHOTS=1 xcodebuild \
  -project RowCompanion.xcodeproj -scheme RowCompanion -configuration Debug \
  -destination "platform=iOS Simulator,id=$SCREENSHOT_SIMULATOR_UDID" \
  -parallel-testing-enabled NO \
  -derivedDataPath "$run_dir/build" -resultBundlePath "$run_dir/capture.xcresult" \
  -only-testing:RowCompanionUITests/RowCompanionUITests/testCaptureAppStoreScreenshots \
  CODE_SIGNING_ALLOWED=NO test
xcrun xcresulttool export attachments --path "$run_dir/capture.xcresult" --output-path "$run_dir/attachments"
python3 Scripts/export_app_store_screenshots.py "$run_dir/attachments"
echo "Screenshots exported to AppStore/screenshots/6.5-inch"
