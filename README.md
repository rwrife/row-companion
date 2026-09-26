# Row Companion

Local-first iPhone workspace for knitters and crocheters to keep pattern PDFs beside repeat-aware row counters and resume each piece without losing their place.

## Status

**Versioned backup/restore and privacy-safe deletion (issue #5), with the simulator regression slice of issue #6.** The repository contains the native Xcode project, shared scheme, and the tested layers so far: the repeat-aware row domain, a CloudKit-disabled SwiftData repository with atomic commits, bounded PDF import (50 MiB / 500-page pre-flight limits, generated app-owned filenames, staged import with no partial records on failure, locked/corrupt/zero-page/oversized rejection), the PDFKit viewer seam with the documented top-left normalized viewport convention and clamp-on-restore rules, per-piece durable reference state (page, zoomed visible rect, manual guide, notes), the compact/two-pane `WorkspaceLayout` seam, and the portable-backup layer: schema-versioned progress export (metadata only — never PDF bytes or source filenames), opt-in full folder backup gated behind explicit copyright/originals acknowledgements, staged restore with hostile-archive validation (traversal/symlink/duplicate/dangling/oversized/hash-mismatch, quarantined staging that is always removed on failure) importing strictly as a new project with fresh IDs and per-copy generated filenames, and confirmed project deletion that removes only app-owned files while stating what it cannot reach (user exports, OS backups). Arrangement runs through the pure `WorkspaceArrangement` rules: two panes require regular width AND readable Dynamic Type (accessibility text sizes reflow to stacked), pane order in the wide layout is user-reversible and arrangement-only, the manual reading guide is a VoiceOver/keyboard-operable slider with an explicit off switch, and completed vs next repeat rows are separate labelled accessibility targets with 44-point control floors. The pinned simulator suite now crosses complete/undo/repeat editing, notes, independent pieces, layout replacement, process termination/relaunch, and accessibility Dynamic Type reflow in executable UI journeys. See `Docs/VERIFICATION.md` for the evidence boundary and remaining physical iPhone/iPad gates. A documented note (not an API dependency) marks the future iPhone Duo safe-region adapter seam; no fold SDK API is used. Real simulator integration runs on the pinned macOS CI job; Linux helper tests are structural only. Physical-device accessibility/file-provider/lock-resume evidence and signing/upload remain explicit open gates in issues #6 and #7.

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

- Required primary platform: **iOS**, built with the **iOS 26 SDK or newer**. Toolchain pin: **Xcode 26.0.1 (build 17A400)** — an explicit update from the initial Xcode 26.0 pin after hosted evidence showed exact 26.0 is no longer installed on hosted macOS runners — Swift 6 language mode; deployment target iOS 26.0. CI must check `xcodebuild -version` and `xcrun --sdk iphoneos --show-sdk-version` and fail below SDK 26. Updates to the pin must be explicit and revalidated.
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

On a Mac with **Xcode 26.0.1 (build 17A400)** installed:

```sh
export DEVELOPER_DIR=/Applications/Xcode_26.0.1.app/Contents/Developer
python3 Scripts/ci_support.py check-toolchain
xcodebuild -list -project RowCompanion.xcodeproj
bash Scripts/ci_native.sh simulator-test
bash Scripts/ci_native.sh device-build
python3 Scripts/ci_support.py export-summary \
  --result-bundle artifacts/RowCompanion.xcresult \
  --output artifacts/evidence/xcresult-summary.json
python3 Scripts/ci_support.py export-report \
  --result-bundle artifacts/RowCompanion.xcresult \
  --output artifacts/evidence/xcresult-report.json
```

The toolchain check prints Xcode/build and iphoneos SDK versions and rejects any
Xcode other than exactly 26.0.1 build 17A400, or any SDK below 26. The test wrapper
deterministically selects
an installed, available iOS 26 iPhone simulator by UDID (no hardcoded device name),
runs both the unit test and UI launch smoke, and disables signing. The generic
iOS build is also unsigned; it is not installable release/TestFlight evidence.
For a repeat local test run, set `RESULT_BUNDLE` to a new `.xcresult` path so
Xcode never overwrites previous evidence. Use that same path when exporting.

CI runs the same commands on `macos-15`, fails closed if the pinned Xcode is no
longer installed, and never substitutes a newer Xcode silently. The committed
`.xcodeproj` is source configuration, not a generated build artifact.

**Pin update history (2026-09-14 → 2026-09-16):** the initial pin required exact
`Xcode 26.0`, and hosted [run 34855094155](https://github.com/rwrife/row-companion/actions/runs/34855094155)
reported `Xcode 26.0.1`, build `17A400`, SDK `26.0` at the `Xcode_26.0.app`
path. The directory name is not proof of the installed version, so the strict
gate correctly failed and simulator tests and the unsigned build did not run.
An exact-head rerun on 2026-09-16
([attempt 3](https://github.com/rwrife/row-companion/actions/runs/34867523105/attempts/3))
enumerated every installed Xcode (16.0–16.4, 26.0.1, 26.1.1, 26.2, 26.3) and
confirmed no exact 26.0 (17A324) remains hosted anywhere on the runner image;
the image manifest only ships `Xcode_26.0.1.app` aliased as `Xcode_26.0.app`,
and there are no self-hosted runners. Rather than relax to a prefix match or
silently substitute a newer toolchain, this PR makes the explicit pin update
PLAN.md requires: exact `Xcode 26.0.1` **plus exact build `17A400`**, still
failing closed on every other version and on SDK < 26. Any future pin change
must likewise be an explicit PR with fresh native evidence. No signing
credentials are needed or accessed by these unsigned checks.

**Evidence retention:** CI publishes two sanitized exports from the real
xcresult, each with the tested checkout SHA (the exact PR head, not GitHub's
synthetic merge ref), Xcode/SDK versions, and SHA-256 checksums.
`xcresult-summary.json` is the allowlisted aggregate. `xcresult-report.json` is
the **full sanitized test tree** from `xcresulttool get test-results tests`:
every suite/case node with its result and duration. The hosted toolchain's
type labels drifted across real runs (`Test Plan`, `Unit test bundle`, plain
`Test Case` leaves), so the sanitizer is shape-driven: containers are nodes
with children, cases are leaves. Privacy rules: type labels outside the
observed set and node names that do not match a strict identifier pattern are
replaced by length-only redaction markers; failure text and any other
free-text field are always reduced to
`{"redacted": true, "length": N}`; internal object ids, attachments, and any
keys outside the reviewed allowlist are dropped (and counted) rather than
copied, so a future toolchain schema addition cannot leak strings by default.
The export fails closed if the tree and aggregate counts disagree or the
schema drifts. The raw `.xcresult` bundle itself (binary payload, attachments,
embedded console logs) remains on the ephemeral runner and is not published;
the sanitized tree is the retained evidence, not a raw-bundle archive. The
host tests verify helper behavior and structural contracts, not Xcode project
compilation, launch, physical-device accessibility, or signing. No fabricated
native result is used.

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
