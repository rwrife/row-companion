# Row Companion — implementation plan

## Scope and architecture

A single-device, local-first craft workspace for knitting/crochet pattern reference and reversible per-piece progress. Standard iOS app with optional adaptive tablet layout; iPhone Duo is a future dual-screen design target, not an SDK dependency. Native bootstrap source and launch tests are present on the implementation branch; executable iOS acceptance remains gated by real pinned-toolchain CI.

### Technology / pinned platform contract

- Swift 6 language mode, SwiftUI UI, PDFKit viewer, SwiftData local persistence (CloudKit disabled), Foundation Codable/CryptoKit backup validation. Native frameworks minimize dependencies and permission surface.
- **Xcode 26.0** initial pin; **iOS 26 SDK or newer** mandatory for simulator and device/archive CI. Deployment target iOS 26.0. Commit the Xcode project and shared RowCompanion scheme; use no project generator in MVP.
- CI selects an explicitly installed Xcode 26.0 on a compatible macOS runner, records full Xcode/SDK versions, fails closed if absent, and enumerates an installed iOS 26 simulator. Pin updates require a PR and new evidence. Linux tests/static checks are never iOS build evidence.
- Proposed source boundaries: `Domain/` pure row reducer and validation; `Persistence/` transactional repository; `Documents/` bounded PDF copier/view state; `Features/Workspace/` UI; `Backup/` versioned folder format; `Tests/` unit/integration; `UITests/` simulator journeys. Domain stays independent of SwiftUI/PDFKit.

### Local data and row semantics

`Project(id,title,createdAt,updatedAt)`, `PatternDocument(id,projectID,relativePath,sha256,pageCount)`, `Piece(id,projectID,name,completedRows,repeatLength?,notes)`, `RowEvent(id,pieceID,sequence,kind,before,after,createdAt,undoneEventID?)`, `ReferenceState(pieceID,documentID,pageIndex,normalizedVisibleRect,guideY?)`.

- Counts are integers in 0...1,000,000; repeat length either absent or 1...10,000. No nested/variable repeats in MVP.
- Display **completed rows n** and **next repeat row (n mod L)+1** separately; completed repeat count is floor(n/L). With L=8: n=0 => next 1/repeats 0; n=7 => next 8/repeats 0; n=8 => next 1/repeats 1. This is next-to-work, not last-completed.
- Complete-row records exactly one event and updated count atomically. Undo restores the latest eligible event for that piece and records its reversal; repeated undo cannot reverse the same event twice. Correction is a confirmed event; no negative counts, overflow, or invisible wrap.
- Editing repeat length preserves total count and records the configuration change; derived repeat labels recompute. Switching piece/project, resizing, and PDF gestures never advance counts. A failed durable save must not display a committed counter update.
- PDF guide position is manual and independent of row arithmetic; chart symbol recognition and automatic chart-row alignment are non-goals.
- Store viewport in document coordinates/normalized visible rectangle and clamp on restore. Restore page then zoom/location after view layout, not on every redraw. Import replacement is not supported in MVP: create a new document association explicitly, retaining progress and resetting only document-specific viewport.

### Import / export / ownership boundary

Copy user-selected PDFs (at most 50 MiB and 500 pages initially; limits must be enforced before costly operations where possible) into a generated-ID directory; balance security-scoped access. Reject malformed, unsupported/password-locked, zero-page, and over-limit files with actionable UI; never execute document actions or silently follow external links. Use original generated PDF fixtures only, never copyrighted sample patterns.

Progress-only JSON contains versioned metadata and counters, not PDF bytes or source paths. Full folder backup includes manifest and optional PDFs with hashes/declared sizes; including originals is opt-in. During restore, reject absolute paths, traversal, symlinks, duplicate IDs/entries, dangling references, unknown future schemas, invalid counts/history, hash mismatch, and oversized totals (200 MiB initial cap). Stage and validate before creating a new project with remapped IDs. No overwrite/merge of existing projects; failures remove staging and preserve current data. Export uses a consistent repository snapshot; do not copy a live SQLite database file. User deletions remove app-owned files only; OS backups and user exports are separate.

### Adaptive layout seam

`WorkspaceLayout` accepts width/accessibility traits and later optional platform safe regions. Compact phone = readable reference + reachable counter controls; regular width = persistent PDF/reference beside the control/notes pane, reversible pane order. Reflow to stacked when Dynamic Type would make two panes unusable. State resides above layout branches, keyed by stable piece/document IDs. Native dual-screen migration must only adapt region arrangement, then rerun continuity tests; do not invent fold APIs or promise physical iPhone Duo compatibility.

## Milestones / dependency order

| Issue | Increment | Depends on |
|---|---|---|
| #1 | Native iOS project, shared scheme, pinned macOS CI | none |
| #2 | Tested row reducer + durable project/piece repository | #1 |
| #3 | User PDF import, piece workflow and resume | #2 |
| #4 | Accessible compact/two-pane workspace with continuity | #3 |
| #5 | Versioned backup/restore, privacy controls and delete | #3 |
| #6 | End-to-end failure/continuity regression and device evidence | #4, #5 |
| #7 | Signed TestFlight candidate and store-readiness package | #6 |

## Testing strategy and honest evidence

- Unit tests: repeat boundaries and large counts; edit length; per-piece independent histories; undo/correction; invalid inputs; deterministic event ordering. Property-style loops assert nonnegative counts and repeat range invariants.
- Persistence integration: durable relaunch; fault-injected save failure; atomic event/count commits; migrations from owned fixtures; no accidental CloudKit entitlement.
- PDF integration: valid original fixture, corrupt/locked/oversized documents, viewport clamping and restoration, denied/cancelled picker, disk-full/read failure, no source mutation.
- UI journeys: create -> import -> complete -> undo -> switch pieces -> relaunch; rotation/resize/size-class changes never alter count, note draft, page, or guide. Check compact phone and iPad, accessibility text sizes and VoiceOver focus. Image-only PDF limitation remains explicit.
- Backup: round-trip into new IDs; defaults omit original PDFs; malicious path/symlink/hash/version/size fixtures; failure rollback; consistent snapshot under counter updates; deletes do not remove outside paths.
- CI must run real xcodebuild simulator tests and unsigned generic iOS build with iOS 26+ SDK, retaining xcresult and exact commit/command/version provenance. User data/keys must never enter artifacts.
- Real iPhone/iPad checks (VoiceOver, lock/relaunch, gestures and file providers) require actual device evidence. If unavailable, leave that acceptance open and label the build simulator-only. No screenshot, accessibility audit, TestFlight processing, or dual-screen test may be inferred from docs.

## Packaging / distribution

Bundle ID `com.infinityball.rowcompanion` registered: `CREATED com.infinityball.rowcompanion` on 2026-09-14. GitHub Actions secrets `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `ASC_TEAM_ID` are configured; values are never source/config artifacts. `ASC_TEAM_ID` supplies the signing team.

#7 owns a manual-dispatch, approval-gated release workflow: verify prerequisites and app record; create/use restricted temporary keychain for distribution certificate and provisioning; archive with Xcode 26.0/iOS 26+ SDK; export IPA; upload via ASC API credentials; verify processing status for exact bundle/version/build number; retain sanitized logs and checksums. API credentials are not signing certificates; missing rights/material/agreements are blockers. Clean keychain/key/profile files even on failure; never log private keys or archive them. Supply privacy manifest as applicable, no-tracking/data-collection declaration based on implementation audit, original screenshots/icons, copyright guidance, support/privacy URLs, and known limitations. TestFlight external testing and App Store submission need manual approval. Do not mark #7 complete based only on an unsigned build or workflow file.

## Risks / non-goals

- Ambiguous row labels: enforce completed vs next-to-work examples and test boundaries.
- PDFKit memory spikes and invalid inputs: hard import limits, no arbitrary downloads, cancellation, honest failure UI.
- Accidental row taps: large separated controls, undo; no auto-advance from gestures or relayout.
- State loss in layout replacement: one durable state owner and continuity regression tests.
- Pattern copyright/private metadata: original fixtures, opt-in originals export, no marketplace or scraped patterns.
- Backup privacy and corruption: preview, validation, staged restore, no overwrite, explicit OS-backup limitations.
- Native fold SDK unknown: standard phone/tablet implementation remains fully useful; future migration is optional.
- No yarn inventory, timers, accounts, cloud sync, nested pattern interpreter, AI, OCR, stitch sensing, medical advice, or safety-critical role.
