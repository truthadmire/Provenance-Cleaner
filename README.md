# Provenance Cleaner

Provenance Cleaner is a native, offline macOS utility for inspecting and
removing deterministic invisible-Unicode carriers and provenance metadata from
files the user owns or is authorized to modify. It targets Apple silicon and
macOS 14 or later.

The cleaning engine is vendored from
[`guillaumemeyer/watermarks-remover`](https://github.com/guillaumemeyer/watermarks-remover)
at the exact commit
`3f84d3e3964368b82172112b09ef3e7c02b25749`. The app never follows the upstream
default branch at build time.

## Scope and safety

- Files are first copied into an app-controlled job directory. Originals are
  unchanged until the user explicitly exports a result.
- Saving a cleaned copy uses `name.cleaned.ext` with collision-safe numbering.
- Replacing an original requires confirmation, uses an atomic write, and keeps
  a recoverable `.bak` copy.
- Space normalization is off by default to preserve typography. Metadata
  cleaning is selective by default where the file format supports it.
- Results describe findings and residual risk. They never claim that a file is
  universally “watermark-free.”
- The app has no network entitlement, telemetry, updater, or remote/model API.

Visible-logo removal, statistical text rewriting, SynthID scoring, CtrlRegen,
MarkDiffusion, audio-waveform alteration, and image regeneration are outside
the product scope. Ghostscript is deliberately excluded, so metadata embedded
inside some PDF images can remain; PDF reports disclose that limitation.

## Architecture

The SwiftUI application uses `NavigationSplitView`, a queue capped at 50 files,
and an async `WatermarkEngine` abstraction. A long-lived, arm64 PyInstaller
`onedir` helper exchanges newline-delimited JSON with the app over standard
input/output and processes one file at a time. Active cancellation terminates
and restarts the helper.

The release helper embeds CPython 3.14.7 and PyInstaller 6.22.2. Its deterministic
toolchain also includes c2patool 0.27.16, ExifTool 13.59 with its Perl runtime
files, and qpdf 12.4.1. Exact source URLs and SHA-256 digests are recorded in
`Config/Dependencies.lock.json`. The 206-file upstream snapshot is independently
locked by path, executable mode, and SHA-256 in
`Config/UpstreamWatermarksRemover.manifest.sha256`; the release pipeline checks
both the working tree and Git index against it. License texts are bundled in the
app and summarized in `THIRD_PARTY_NOTICES.md`.

The outer application uses App Sandbox with user-selected read/write access.
The nested helper inherits that sandbox and is passed only staged per-job paths.

## Build and test

XcodeGen 2.44 or later and Xcode 26 were used for the checked-in project. For a
release-equivalent helper build, point the scripts at an exact CPython 3.14.7
runtime:

```sh
export PROVENANCE_PYTHON=/path/to/Python.framework/Versions/3.14/bin/python3
export PROVENANCE_DYLD_FRAMEWORK_PATH=/path/containing/Python.framework
export PROVENANCE_DYLD_LIBRARY_PATH=/path/to/Python.framework/Versions/3.14/lib

./script/fetch_dependencies.sh verify
./script/verify_upstream_snapshot.sh
./script/build_helper.sh
./script/build_and_run.sh --verify
xcodebuild -project ProvenanceCleaner.xcodeproj \
  -scheme ProvenanceCleaner \
  -configuration DebugTests \
  -destination 'platform=macOS,arch=arm64' test
```

The helper integration suite can run against source or the frozen executable:

```sh
python3 -m pytest -q Tests/HelperIntegration/test_provenance_helper.py
PROVENANCE_HELPER_UNDER_TEST=Helper/dist/ProvenanceEngine.app/Contents/MacOS/provenance-engine \
  python3 -m pytest -q Tests/HelperIntegration/test_provenance_helper.py
```

The full upstream suite is preserved under `Vendor/watermarks-remover/tests`.
See `Config/VerificationEvidence.md` for the exact verified totals and host
limitations of the release candidate.

## Package a release

The release script verifies dependency receipts, entitlements, embedded
versions, offline policy, arm64 architectures, linked libraries, and helper
capabilities. It then signs nested code inside-out with Hardened Runtime, creates
and signs the DMG, optionally notarizes and staples it, and emits a source
archive, checksums, notices, verification evidence, and a release report.

```sh
./script/package_release.sh \
  --identity 'Developer ID Application: Example (TEAMID)' \
  --notary-profile ProvenanceCleaner \
  --output /absolute/path/to/new-or-empty-output-directory
```

The notarization profile must already exist in the Keychain and contain valid
Apple notarization credentials. If `--notary-profile` is omitted, the script
produces a Developer ID-signed candidate but marks notarization, stapling, and
Gatekeeper distribution acceptance as pending; it does not describe that DMG as
notarized.
