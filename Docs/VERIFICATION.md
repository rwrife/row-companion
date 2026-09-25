# Verification evidence and remaining device gates

Row Companion separates automated evidence from checks that require a person
and physical hardware. Passing CI never implies the physical-device rows below.

## Automated exact-commit evidence

The `CI` workflow checks out the pull-request head SHA rather than a synthetic
merge commit and records that SHA in both privacy-sanitized xcresult exports.
On the pinned Xcode 26.0.1 (17A400) and iOS 26 SDK lane it runs:

```sh
bash Scripts/ci_native.sh simulator-test
bash Scripts/ci_native.sh device-build
```

The native suite covers unit, persistence, bounded import, hostile backup and
restore, failure injection, and UI journeys. The issue #6 continuity journey
performs complete, undo, repeat change, notes, piece switching, regular-width
layout replacement, process termination, and relaunch, then compares durable
readouts for both pieces. A second journey launches with an actual iOS
accessibility Dynamic Type preference and verifies regular width reflows to the
stacked arrangement while the 44-point counter remains reachable.

Published artifacts are only `xcresult-summary.json` and the full sanitized
`xcresult-report.json`; raw xcresult bundles, attachments, paths, pattern data,
and failure text are not uploaded. The report's `tested_commit` must equal the
PR head before the evidence is accepted.

The unsigned generic-device build proves compilation for iOS. It is not an
installable archive, signing result, TestFlight upload, or physical-device run.

## Physical-device acceptance still required

Record these against an exact commit on actual supported hardware. Keep issue
#6 open until the results exist; do not infer them from simulator behavior.

- iPhone and iPad: VoiceOver focus/order and completed-versus-next-row speech.
- iPhone and iPad: every accessibility Dynamic Type size, contrast, Reduce
  Motion, Switch Control or hardware keyboard operation, and gesture fallback.
- Files providers: local Files and an enabled third-party/cloud provider,
  including denial, cancellation, offline retry, corrupt PDF, and a PDF near
  the documented size/page limits.
- Lock, background/foreground, memory eviction, force termination, and relaunch
  while notes, page/zoom, manual guide, piece selection, and row history are
  changing.
- Storage-pressure failure on import, row save, export, and staged restore;
  verify no apparent success or partial durable mutation.
- Airplane mode launch and normal use. The current source and project contract
  has no app networking or CloudKit surface, but a physical run remains the
  user-visible offline check.

Image-only PDFs remain inaccessible unless the user supplies equivalent notes;
the app performs no OCR. Current layout evidence covers standard iPhone/iPad
size classes only. It is not native iPhone Duo or fold-SDK evidence.