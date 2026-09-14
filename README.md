# Row Companion

Local-first iPhone workspace for knitters and crocheters to keep pattern PDFs beside repeat-aware row counters and resume each piece without losing their place.

## Status

**iOS bootstrap source and CI wiring.** The repository contains the native Xcode project, shared scheme, SwiftUI launch placeholder, unit test, and XCUITest launch smoke. Pattern import, persistence, and counters are not implemented yet. Native acceptance requires the exact-head macOS CI result; Linux helper tests are not iOS build evidence. See [PLAN.md](PLAN.md) and [issue #1](https://github.com/rwrife/row-companion/issues/1).

## Why / who

Hobby knitters and crocheters often switch between a PDF chart and a counter, then lose the chart location or confuse total rows with rows inside a motif repeat. Row Companion keeps the reference and per-piece progress together. Unlike a generic PDF reader, inventory, or timed recipe checklist, the central object is a **piece with reversible completed-row history and repeat arithmetic**.

## Intended workflow and use cases

1. Create a project (for example a scarf) and copy a PDF you own or have permission to use through the system Files picker. A project can also use manual text notes with no PDF.
2. Add named pieces (front, back, sleeve); set each piece's optional fixed repeat length and starting completed-row count.
3. Position the PDF page/zoom and optional horizontal reading guide. Write a text equivalent for image-only chart cues when needed.
4. Tap **Complete row** once after actually working a row. See completed rows and the **next** repeat row separately. Undo a mistaken tap; explicit count correction requires confirmation.
5. Switch pieces or close the app. Each piece retains its own count, guide, viewport, and notes; reopening resumes the same state.
6. Export a progress JSON or a full backup folder, preview it, and choose its destination. Restore a validated backup as a new project without overwriting existing work.

Examples: repeat an eight-row scarf motif without mental modulo arithmetic; resume two sleeves independently; keep a chart readable while using large counter controls.

## Platforms and two-pane design

- Required primary platform: **iOS**, built with the **iOS 26 SDK or newer**. Initial toolchain pin: **Xcode 26.0**, Swift 6 language mode; deployment target iOS 26.0. CI must check `xcodebuild -version` and `xcrun --sdk iphoneos --show-sdk-version` and fail below SDK 26. Updates to the pin must be explicit and revalidated.
- SwiftUI standard iPhone app; **optional iPad/regular-width adaptive tablet view**. Android and desktop are outside MVP.
- **iPhone Duo dual-screen design target**, not a claim of available hardware or native SDK compatibility: one display would keep the chart visible while the other holds the piece selector, repeat status, notes, and large controls. On current compact layouts, the PDF and controls share a screen with an expandable notes section; regular-width layouts show reference and controls side by side.
- One `WorkspaceLayout` boundary chooses arrangement from available width and accessibility needs. Durable project/piece state is independent of view identity. Later native dual-screen APIs may feed safe regions into that boundary; no hinge sensor, fold detection, external display, or unavailable SDK API is required now. Rotation/resize must not create a row event or reset a viewport.

## MVP / non-goals

MVP: local projects and pieces; bounded PDF import and viewer; manual notes; optional reading guide; completed-row counter with single fixed-length repeat per piece; persistent undo/correction history; accessible compact/two-pane layouts; portable backup/restore and deletion.

Not MVP: automatic stitch recognition, pattern generation, OCR, audio/voice control, arbitrary nested repeat languages, pattern marketplace, cloud sync, accounts, AI, ads, social sharing, yarn inventory, wearable/sensor integration, or paid content redistribution. Counters record user input, not detected physical stitches. No medical, safety, or ergonomic-treatment claims.

## Privacy, permissions, and ownership

- App-private local storage: SwiftData for project/piece/event metadata with CloudKit disabled; imported PDFs in Application Support under generated IDs, never trusted source filenames. File protection follows device lock policy. No telemetry or application network client.
- Files picker access is user initiated; selecting a cloud-provider document can involve that provider's network outside this app. Once copied, the app works offline. No camera, Photos, microphone, motion, location, contacts, notifications, or background-service permissions in MVP.
- Respect pattern copyright: bundle only original test patterns. Default progress-only export omits PDFs; full backup explicitly asks to include originals and warns that it may contain licensed/private material.
- Versioned JSON progress export and user-owned folder backup (manifest + optional PDF copies). Validate hashes, sizes, paths, schema, and row-event consistency before restore. No archive parser required in MVP. Import creates new IDs with a preview; failures leave existing data unchanged. No silent merge.
- Project deletion confirms loss and removes app-owned PDFs; user-exported files and OS/device backups remain outside the app's deletion control. Explain OS backups separately from app-cloud-sync behavior; do not promise secure erasure.
- Accessibility: VoiceOver labels and completed-versus-next row announcements, Dynamic Type including accessibility sizes, 44-point minimum targets, non-color status, Reduce Motion, keyboard/Switch Control operation, and no mandatory gestures. Image-only PDFs are not inherently accessible; editable text notes are the fallback, not an OCR claim.

## Development quickstart

Host-capable verification (Python 3 standard library; no app dependencies):

```sh
python3 -m unittest discover -s Tests -v
bash -n Scripts/ci_native.sh
```

On a Mac with **Xcode 26.0** installed:

```sh
export DEVELOPER_DIR=/Applications/Xcode_26.0.app/Contents/Developer
python3 Scripts/ci_support.py check-toolchain
xcodebuild -list -project RowCompanion.xcodeproj
bash Scripts/ci_native.sh simulator-test
bash Scripts/ci_native.sh device-build
python3 Scripts/ci_support.py export-summary \
  --result-bundle artifacts/RowCompanion.xcresult \
  --output artifacts/evidence/xcresult-summary.json
```

The toolchain check prints Xcode/build and iphoneos SDK versions and rejects any
Xcode other than 26.0 or SDK below 26. The test wrapper deterministically selects
an installed, available iOS 26 iPhone simulator by UDID (no hardcoded device name),
runs both the unit test and UI launch smoke, and disables signing. The generic
iOS build is also unsigned; it is not installable release/TestFlight evidence.
For a repeat local test run, set `RESULT_BUNDLE` to a new `.xcresult` path so
Xcode never overwrites previous evidence. Use that same path when exporting.

CI runs the same commands on `macos-15`, fails closed if the pinned Xcode is no
longer installed, and never substitutes a newer Xcode silently. The committed
`.xcodeproj` is source configuration, not a generated build artifact.

**Hosted toolchain blocker (2026-09-14):** [run 34855094155](https://github.com/rwrife/row-companion/actions/runs/34855094155)
reported `Xcode 26.0.1`, build `17A400`, SDK `26.0` at the `Xcode_26.0.app`
path. The directory name is not proof of the installed version. The strict
26.0 gate correctly failed; simulator tests and the unsigned build did not run.
CI now prints installed Xcode versions before checking the selected toolchain.
Supply an actual Xcode 26.0 installation to unblock this pin; accepting another
version requires an explicit contract/pin-update PR and fresh native evidence,
not a relaxed prefix check or a successful Linux test. No signing credentials
are needed or accessed by these unsigned checks.

**Evidence limitation / open issue #1 gate:** CI publishes only an allowlisted
aggregate JSON export from the real xcresult, with tested checkout SHA (the exact
PR head, not GitHub's synthetic merge ref), Xcode/SDK versions, and SHA-256 checksum. Arbitrary
test messages, paths, screenshots, attachments, and diagnostics are not uploaded.
The raw `.xcresult` remains on the ephemeral runner. A reviewed, sanitized **full
xcresult bundle** retention path is not implemented; therefore the complete
issue is not claimed closed even if these CI jobs pass. The host tests verify
helper behavior and structural contracts, not Xcode project compilation, launch,
physical-device accessibility, or signing. No fabricated native result is used.

## Signing and distribution

Bundle identifier: `com.infinityball.rowcompanion`.
App Store Connect bundle-ID registration: **CREATED com.infinityball.rowcompanion** (2026-09-14).

Repository Actions secrets configured: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `ASC_TEAM_ID` (names only). Use `ASC_TEAM_ID` for signing/provisioning team. Bundle registration does not create an App Store app record or provide signing certificates/profiles. Release issue #7 must configure those prerequisites, a gated signed archive/export/upload workflow, and TestFlight processing evidence. Keep API keys in temporary mode-600 files, never log them, and clean signing material afterward. Missing account permissions, certificates, profiles, agreements, or app record are explicit release blockers—not fabricated success. App Store submission remains a manual approval step after privacy metadata, screenshots, and real-device review.

## Milestones

1. Reproducible iOS skeleton and CI.
2. Tested local row model and persistence.
3. Pattern import and resume workflow.
4. Accessible compact and two-pane workspace.
5. Safe portable backup and deletion.
6. Regression and real-device evidence.
7. Signed TestFlight candidate and store-readiness checklist.

MIT code/docs license; user-supplied patterns retain their own licenses.
