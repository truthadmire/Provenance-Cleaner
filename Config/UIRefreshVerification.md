# UI, metadata and C2PA refresh — 2026-10-10

This is a local development build, not a newly notarized release.

## Verified

- `./script/build_and_run.sh --verify`: final Debug build and launch succeeded.
- Swift unit suite: 42 tests, zero failures. Covers staged metadata edits,
  preservation after failed writes, current-copy reinspection and preventing stale
  original credential verdicts from appearing on an uninspected result.
- Python helper suite: 45 tests, zero failures, against source and again against
  the rebuilt PyInstaller executable. Includes Unicode/empty author fields in
  JPEG, PNG and PDF; Office property updates and unchanged other package entries;
  signed Office refusal; real C2PA signing-chain extraction; tampered image hash
  failure; malformed tool output and missing verification evidence.
- Pinned upstream snapshot: all 206 files verified unchanged.
- Direct native UI checks on the sandboxed Debug app: import DOCX and C2PA JPEG,
  navigate Overview/Metadata, change the DOCX author to `Interface Review`, apply
  to a copy, review, and confirm the value was read back with no unsaved changes.
  No source fixture was overwritten or exported. Dark-mode fields, summary cards,
  validation states, expanded certificate rows and long-field wrapping were
  visually checked at the app's 900-point minimum width.
- Light-mode empty state visually checked in a separately signed temporary
  preview bundle with its own identifier, leaving existing app instances intact.

## Limits

The new end-to-end XCTest UI test compiled, but the macOS runner failed before
executing with `Timed out while enabling automation mode`. It is not counted as
a passing test. Native automation was also intermittently unresponsive; the full
light-mode editor and final date-control changes do not have automated visual
acceptance evidence. Native metadata editing and certificate browsing were
verified directly as described above.

C2PA verification is offline. Remote manifests, live revocation and CAWG identity
are not checked. Office/archive containers keep structural metadata inspection;
certificates inside embedded assets are not individually validated. Descriptive
metadata changes can invalidate existing signatures. PDF metadata writes are
incremental and do not securely erase recoverable earlier revisions.

## Local evidence

Build/test logs are in `build/ui-refresh/` (ignored generated files):
`app-build.log`, `swift-tests.log`, `helper-tests.log`,
`frozen-helper-tests.log`, `helper-build.log`, `vendor-check.log`, and
`ui-tests.log`. The failed automation initialization bundle is
`/private/tmp/provenance-ui-refresh.xcresult`.
