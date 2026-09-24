# App Store assets

- `screenshots/6.5-inch/`: three actual iOS Simulator captures, in upload order, at **1242 × 2688** pixels (portrait PNG, opaque RGB).
- `description.txt`: ready-to-paste English description of implemented features.
- `metadata.json`: suggested name, subtitle, promotional text, and keywords.
- App icon: `../RowCompanion/Assets.xcassets/AppIcon.appiconset/AppIcon.png`, 1024 × 1024, opaque. Uses the supplied artwork with proportional resizing only; system applies corner masking.

Screenshot order: pattern and progress, reading guide and notes, independent piece counters. The sample chart is original fixture content; no third-party pattern is included. Screenshots show the actual interface without added marketing overlays.

## Recreate screenshots

Use an available iPhone 11 Pro Max simulator runtime supporting iOS 26 or newer. Boot a dedicated simulator, then run:

```sh
SCREENSHOT_SIMULATOR_UDID=<device-uuid> bash Scripts/capture_app_store.sh
```

The capture uses `-rc-app-store`, compiled only for Debug simulator builds, and a separate `RowCompanionScreenshots` store. It never seeds the normal project store. The test is skipped in ordinary CI runs unless `TEST_RUNNER_RC_CAPTURE_SCREENSHOTS=1` is supplied. The script validates screenshot dimensions and PNG color type before exporting.

## Validation

Captured on iPhone 11 Pro Max / iOS 26.5 with Xcode 27.0 (27A266a). Simulator build and screenshot UI journey passed. The repository's pinned CI toolchain remains unchanged. Host contract suite: 39 passed. App Store metadata fields are within character limits. Release signing and App Store upload were not performed.

Apple's accepted 6.5-inch screenshot dimensions: https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications

The description intentionally excludes planned backup/restore, cloud sync, and automatic stitch detection. Recheck the listing against the final release build before submission.
