#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 Scripts/ci_support.py check-toolchain
case "${1:-}" in
  simulator-test)
    UDID=$(python3 Scripts/ci_support.py select-simulator)
    printf 'Selected simulator UDID: %s\n' "$UDID"
    mkdir -p artifacts
    xcodebuild -project RowCompanion.xcodeproj -scheme RowCompanion \
      -destination "platform=iOS Simulator,id=$UDID" \
      -derivedDataPath build/simulator \
      -resultBundlePath "${RESULT_BUNDLE:-artifacts/RowCompanion.xcresult}" \
      -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
    ;;
  device-build)
    xcodebuild -project RowCompanion.xcodeproj -scheme RowCompanion \
      -configuration Release -destination 'generic/platform=iOS' \
      -derivedDataPath build/device CODE_SIGNING_ALLOWED=NO build
    ;;
  *)
    printf 'Usage: bash Scripts/ci_native.sh {simulator-test|device-build}\n' >&2
    exit 2
    ;;
esac
