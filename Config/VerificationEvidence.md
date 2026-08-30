## Test and Compatibility Evidence

This evidence records what was directly verified for the 0.1.0 release
candidate. It is intentionally narrower than the complete acceptance matrix.

### Automated verification

- Host: Apple silicon (`arm64`), macOS 26.5.1 (25F80), Xcode 26.4 (17E192).
- Vendored upstream commit: `3f84d3e3964368b82172112b09ef3e7c02b25749`.
- Complete upstream pytest suite under exact CPython 3.14.7 with pytest 9.1.1:
  **941 passed, 16 skipped, 0 failed** in 22.19 seconds.
- Swift unit suite using the unsandboxed `DebugTests` host while production
  Debug and Release configurations remained sandboxed: **34 passed, 0 failed,
  0 skipped**.
- Native XCUITest suite: **7 passed, 0 failed, 0 skipped** in 120.330 seconds.
  The suite covers a real Finder-to-app file drag, automatic inspection,
  mixed-result queues, review and export prompts, keyboard commands, Light and
  Dark appearances, missing engine capabilities, and helper termination and
  restart after cancellation.
- Helper integration matrix against the source helper under exact CPython
  3.14.7: **18 passed, 0 failed** in 14.72 seconds.
- The same helper integration matrix against the frozen arm64 PyInstaller
  helper: **18 passed, 0 failed** in 14.23 seconds.
- Integration coverage includes invisible Unicode, PNG/JPEG selective metadata,
  synthetic C2PA, DOCX, PDF structural cleanup and its Ghostscript warning,
  WAV, MP4, malformed and unsupported input, the 256 MiB limit, forced helper
  failure, cancellation/restart, and original-byte preservation.

### Native application verification

- The production-sandboxed Debug application built outside the iCloud-backed
  workspace, passed its launch verification, and remained running.
- The first-run authorized-use notice, empty queue, Settings defaults and
  diagnostics, Add Files panel, automatic inspection, `Command-Return` cleaning,
  review-before-export prompt, residual-risk status, and native text-diff preview
  were exercised through the running macOS application.
- The checked-in text fixture had SHA-256
  `2028fdb8cf4e668fca1ab6662c2ccc9aaad3d088ee05e99de56a34cca878d009`
  before review. No export was performed during this check, and the original
  remained byte-identical.
- The application diagnostics reported the embedded engine as available while
  App Sandbox was enabled. Default metadata behavior was preserve/selective,
  Unicode cleaning was enabled, and space normalization was disabled.
- Dark appearance was exercised for the full import, clean, and preview path.
  Light appearance was checked separately for native layout and readability.
- A native XCUITest revealed a temporary fixture in Finder, tiled Finder beside
  the app, dragged the file into the app window, and verified that the queue
  reached the expected inspected status. The gesture did not alter the source
  fixture.

### Pending acceptance evidence

- No `notarytool` Keychain profile or Apple notarization credentials were
  supplied for this build. Notarization submission, ticket stapling, stapler
  validation, and successful Gatekeeper distribution assessment remain pending.
- Clean Apple-silicon installations of macOS 14 and macOS 15 were not available
  in this environment. The current macOS 26.5.1 host is the only OS version
  directly launch-tested, and it was not a clean machine without developer
  tooling.
- These pending checks are release blockers for describing a DMG as fully
  notarized or claiming the complete clean-machine compatibility matrix. They do
  not alter the recorded automated test results. Developer ID signing evidence,
  if produced, is recorded separately by the generated release report only after
  its strict verification commands succeed.
