## Test and Compatibility Evidence

This evidence separates the current development checks from the original
0.1.0 release-candidate checks. Neither section claims the complete acceptance
matrix.

### 0.5.1 PDF property edits no longer leave earlier values — 2026-10-26

- Reproduced before the change, with the bundled ExifTool 13.59: a PDF whose
  base revision had author "Original Name", edited to "New Name" the way the
  app did, still contained "Original Name" in plain text, and
  `exiftool -PDF-update:all=` restored it.
- Fix: after the ExifTool write, the bundled qpdf 12.4.1 rewrites the file,
  keeping only objects the current revision uses. The result must have exactly
  one revision, pass `qpdf --check`, and read back every new value, or nothing
  is saved. On the same sample, "Original Name" no longer appeared anywhere
  (streams decompressed), and the ExifTool revert found nothing to undo.
- The PDF note in Document properties now says earlier values are removed,
  and for a signed PDF (`/ByteRange` present) that the signature will no
  longer validate. Signed PDFs can still be edited.
- 69 helper tests passed against the source (2 new; both PDF edit tests failed
  with the rewrite disabled). 76 Swift unit tests passed.
- Not verified: very large or damaged PDFs beyond the existing qpdf
  validation, and the Changes-tab wording by eye in the running app.

### 0.5.0 download source, revision number and total editing time — 2026-10-26

- New: Office files can set **Revision number** (`cp:revision` in
  `docProps/core.xml`) and **Total editing time** in minutes (`TotalTime`, an
  `xsd:int` in `docProps/app.xml`). Both accept whole numbers from 0 to
  2,147,483,647. `TotalTime` is edited in place, because Word's `app.xml` (a
  default namespace with unqualified attributes) can't be re-serialized by
  ElementTree. Every other byte of the part is kept, and the rest of the part
  is compared after parsing.
- New: **Download source** sets Finder's "Where from" (`kMDItemWhereFroms`, a
  binary plist array of strings) on a contents-only copy as the last build
  step, verified by reading it back. Save copy and Save all keep it. Replace
  writes it over the original's; with none set, Replace still removes it.
- 67 helper tests passed against the source and 67 against the rebuilt frozen
  helper (4 new), under CPython 3.14.7 with pytest 9.1.1. 76 Swift unit tests
  passed (7 new).
- The frozen helper, driven through its JSON protocol, read a Word-shaped sample
  (revision 42, 35 minutes), wrote 3 and 95 with only `<TotalTime>` changed in
  `app.xml`, and refused `1.5` without creating an output. Spotlight read
  the binary "Where from" attribute back (`mdls`).
- Not verified: the new Changes-tab cards by eye in the running app (the
  window wasn't available to drive), opening an edited copy in Word, and the
  sandboxed Save/Replace of a download source. Those paths are unit-tested
  unsandboxed. XCUITests were not run.

### 0.4.0 release build — 2026-10-25

- 0.4.0 (6) ships the three 2026-10-18 entries below: the Clay interface, the
  helper output corrections and the save/replace fixes.
- The frozen helper was rebuilt with the pinned CPython 3.14.7 (the python.org
  package matches its locked SHA-256 and PSF Developer ID signature).
- Under CPython 3.14.7 with pytest 9.1.1, 63 helper tests passed against the
  source and 63 against the frozen helper. 69 Swift unit tests passed
  (DebugTests).
- XCUITests were not run. Signing, notarization and DMG checks are in the
  release report.

### Save and replace path (0.4.0) — 2026-10-18

- Save copy writes exactly the save-panel URL (it used to write `stem 2.ext` after
  the panel had confirmed an overwrite). Temporary files go in the system's
  item-replacement folder, not beside the user's file.
- Replace prepares the copy before writing `.bak`, removes its own `.bak` when
  the original survives a failed replace, refuses when the original changed
  after the copy was made, and removes only `kMDItemWhereFroms` from the result.
  Tags, custom attributes and permissions are kept (unit-tested).
- Save/replace records live outside the copy's status. A replaced file can't be
  re-checked, rebuilt or replaced again. Save all and Replace originals skip
  outdated, already-saved and already-replaced files and report counts.
  Create all copies rebuilds only missing, outdated, failed or changed copies.
  Creating a copy re-checks an original that changed since it was checked.
- 65 Swift unit tests passed (10 new). Native check in the unsandboxed DebugTests
  build on a scratch fixture: replace produced the `.bak`, the cleaned file lost
  its download-source attribute, the backup kept it, and the UI showed the
  locked "Original replaced" state.
- Sandboxed Debug build, file dragged in from Finder (a per-file grant like the
  Open panel's): Replace original FAILED before this change with "you don't have
  permission to access" the folder. The original was untouched and no `.bak` was
  left. Replace now catches the permission error, asks once per folder with an
  Open panel titled "Allow backups in this folder", and retries. Verified in the
  sandbox: the prompt opens on the file's folder. After the folder was granted
  (dropped onto the app), Replace succeeded: cleaned file in place, `.bak` with
  the original bytes, "Original replaced" state. Clicking Allow in the prompt
  itself wasn't automated, because the panel runs in a separate system process.
- 67 Swift unit tests passed, including prompt-and-retry and decline-once-per-batch
  tests that use a read-only folder to reproduce the denial.
- Not verified: Save copy over an existing name in the sandbox (needs the save
  panel); it now writes only the exact panel URL, using the system's
  item-replacement folder for temporary data.

### Helper corrections to engine output (0.4.0) — 2026-10-18

- Fixed: cleaning DOCX/XLSX/PPTX corrupted `docProps/thumbnail.jpeg` (the pinned
  engine re-encodes every docProps part as UTF-8 text) and left the preview's
  C2PA/EXIF in place. Reproduced with a C2PA-signed thumbnail: 132,518 bytes in,
  191,555 bytes of U+FFFD out. After the fix: a valid 2048×1365 JPEG with no
  C2PA markers. Unstrippable previews are dropped with their relationship and
  content-type entries.
- Fixed: inspect/clean reports no longer carry the engine's stylometry score,
  SynthID/pixel keys or rewrite advice; `suspicious` for text is recomputed from
  deterministic signals; known engine notes are rewritten in plain language and
  unknown notes still pass through.
- 63 helper tests passed (5 new in `test_upstream_fixes.py`; each new test was
  confirmed to fail with its fix disabled). 55 Swift unit tests passed. The
  vendored snapshot verified unchanged. The frozen helper was not rebuilt.

### Clay interface redesign (0.4.0) — 2026-10-18

- Rebuilt the interface on the Clay design system and replaced the separate
  Clean / Apply to Copy / Apply editing traces actions with one copy built from
  the original in a fixed order. The export prompt after cleaning was removed.
- 55 Swift unit tests passed (DebugTests). New coverage: step order and inputs,
  rebuild from the original, failed-step rollback, empty/invalid plans, outdated
  copies, incomplete-check reasons, informational leftovers, verdict wording.
- 58 helper tests passed with a rebuilt source venv (`build/python314-test-venv`,
  CPython 3.14.2). The helper and the upstream snapshot were not changed.
- The UI test target compiles against the new screens; XCUITests were not run.
- Manual native checks with the real helper in light and dark appearance:
  first-run notice, empty state, mixed fixture queue, Findings/Changes/Review for
  DOCX, JPEG and text, a three-step DOCX copy (cleaning, editing history,
  title), the text diff, and Settings. No fixture original was exported or
  replaced.
- Fixed while verifying: window content drawn under the toolbar (a banner's
  fixed text height inflated the window's minimum height), and a copy reported
  as having a remaining marker when only an informational typographic space
  remained (the same rule existed before the redesign).
- No helper rebuild, signing, DMG or notarization was performed.

### 0.3.1 Word and embedded-media C2PA — 2026-10-11

- 58 source helper tests and 44 Swift unit tests passed. Detailed scope and
  native UI verification: `Config/WordC2PAVerification.md`.
- Official c2patool 0.27.22 is pinned by the GitHub release asset digest. Word
  credentials use the SDK's ZIP collection-hash validation; embedded media are
  inspected separately using bounded, generated temporary paths.
- Release gates rebuild the frozen helper and repeat the complete integration
  suite, then verify Word and image certificate chains in a signed sandbox
  parent both before packaging and from the mounted DMG.
- Signing, Apple notarization, mounted-image checks and final SHA-256 are recorded
  in the generated release report. Earlier evidence below is historical.

### 0.3.0 UI, metadata and certificate validation — 2026-10-11

- UI refresh and metadata/C2PA implementation evidence is detailed in
  `Config/UIRefreshVerification.md`: 42 Swift tests and 45 helper tests passed.
  The 45-test matrix was run against source and the frozen executable; direct
  module tests within that matrix still execute their source modules.
- The release pipeline rebuilds from a clean local snapshot of the complete
  current working tree, including the previously uncommitted UI changes.
- The signed sandbox-parent probe now exercises author edits and read-back in
  DOCX and PDF, plus a real C2PA JPEG signature, content binding and two-certificate
  chain. The checks run before DMG creation and again from the mounted DMG.
- This section documents the verification scope. Actual signing, notarization,
  mounted-image results and checksums are recorded by the release run in its
  generated `RELEASE_REPORT.md`; previous release evidence below is historical.

### Detail scrolling layout verification — 2026-09-05

- Replaced the detail header's scroll-view safe-area inset with a separate
  fixed-height layout section above a clipped content viewport. Queue selection
  changes recreate the content view so scroll offsets do not carry between files.
- The Debug app rebuilt and passed launch verification. Manual native checks in
  Dark appearance covered the user's long DOCX report at the original reported
  scroll position, middle and bottom positions, an enlarged window and its
  restored size, and switching between two queue items. Report content remained
  below the header and tabs in every checked state.
- The selected original DOCX retained its SHA-256 before and after verification.
  No result was exported or used to replace the original. This layout-only change
  was verified by build and native UI checks; helper suites were not rerun.

### Word editing traces development verification — 2026-09-05

- Implemented separate DOCX editing-metadata inspection and rewriting in the
  app-owned helper module; the pinned upstream source remains unchanged.
- The helper test suite passes **35 tests** with the source helper and **35
  tests** with the packaged helper selected. Each run includes 26 protocol
  integration tests and nine direct metadata-module tests. The frozen run's
  protocol tests exercise the packaged executable; its nine direct tests still
  exercise the source module.
- Coverage checks consistent fresh RSIDs, distinct dates in chronological order,
  equal instants expressed in different time zones, removal, unchanged visible
  text and revision contents, preserved comments and unrelated package parts,
  no-op byte identity, invalid ranges/dates, DTD refusal, unsupported encodings,
  signed-document refusal, and existing-output preservation after failure.
- Swift unit suite: **38 passed, 0 failed**. Added checks cover persisted Word
  options, date-range validation and JSON transport, plus the dedicated action
  staging output and queuing export review with an editing-traces status.
- Built and launched the production-sandboxed Debug app. Manual Dark-appearance
  checks exercised inspection, date-range controls, RSID/date randomization,
  archive timestamp reset, the export-review prompt, and before/after values.
  The native result reported 13 processed metadata fields and nine ZIP dates
  reset for the synthetic fixture. No original document was replaced.
- Microsoft Word opened the rewritten corrected fixture without a repair prompt.
  Native read-back showed its bold heading, original text, insertion, tracked
  deletion, comment, and randomized dates. An earlier synthetic fixture lacked
  a binary content-type declaration and extension-compatibility declaration;
  those fixture declarations were corrected before the final compatibility check.
- The corrected checked-in fixture has SHA-256
  `d9c6afa3288bbbf6b413ade7ca1b4e122e310cf6fed62605aeedce06b6c12a93`.
- No new DMG or notarization result was produced. The existing complete upstream
  and XCUITest results below remain historical; neither full suite was rerun.

### Deep PDF cleaning development verification — 2026-09-05

- Built the pinned Ghostscript 10.07.1 source for Apple silicon with a macOS 14
  deployment target. The executable links only to system libraries, includes its
  initialization resources, and reports the locked version. Dependency receipt,
  source SHA-256, licenses, and executable architecture checks passed.
- Source helper integration suite under CPython 3.14.7: **23 passed, 0 failed**
  in 18.596 seconds. The same suite against the frozen arm64 helper: **23 passed,
  0 failed** in 19.810 seconds.
- The vendored upstream PDF image and structural rewrite suites:
  **22 passed, 0 failed**. The complete upstream suite was not rerun for this
  change; its earlier results are recorded below.
- Swift unit suite with the `DebugTests` host: **36 passed, 0 failed**. Added
  coverage checks lossless-mode persistence and transport, and incomplete PDF
  cleaning retaining a reviewable output with an incomplete status.
- PDF integration coverage exercises all four modes, embedded provenance and
  ordinary camera metadata, unchanged source bytes, and matching rendered page
  pixels. It also verifies refusal of malformed PDFs, reporting of Ghostscript
  failures, ignored inherited `GS_*` configuration, and cancellation terminating
  the running Ghostscript child together with the helper.
- The production-sandboxed Debug app built and passed launch verification.
  A strictly verified, ad-hoc-signed sandboxed release probe launched the
  inherited-sandbox frozen helper, reported Ghostscript available and offline
  mode enabled, and successfully cleaned the embedded-image PDF fixture.
- Manual native UI verification in Dark appearance covered import, the embedded
  provenance finding, the four-mode picker, Automatic and Lossless cleaning,
  review-before-export, the actual pass result, and readable original/cleaned
  PDF previews. Automatic was restored as the default. No export was performed.
- The checked-in PDF fixture remained byte-identical after native verification:
  SHA-256 `56e69aaa9c4c4f0aa79da8868aa906de7e6ad550a37fab2cece42ec916c78d18`.
- The release script now includes the matching Ghostscript source archive,
  build recipe, and licenses in the DMG, and runs the sandboxed PDF smoke check.
  No new release DMG or notarization result was produced during this change.
- The native XCUITest runner timed out enabling automation before executing
  tests during the current work. The manual native checks above and the 36
  Swift unit tests are the current evidence; the seven UI tests below are
  historical results.

### Original 0.1.0 release-candidate evidence

#### Automated verification

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

#### Native application verification

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
