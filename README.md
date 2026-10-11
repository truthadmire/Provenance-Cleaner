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
the product scope.

PDF cleaning includes ExifTool document metadata stripping, qpdf structural
rewriting, and Ghostscript 10.07.1 for metadata inside embedded images. Automatic
mode deep-cleans only when provenance markers remain; it tries pass-through
before escalating to image re-encoding. Settings also offers a lossless-pass-only
mode, a deep pass for every PDF (including ordinary image metadata), and
document-only cleaning. Pass-through preserves JPEG/JPEG2000 data where supported;
other codecs may be rewritten. Results report whether the deep pass ran, whether
the additional re-encoding step ran, and whether processing was incomplete.
PDF rewriting may affect interactive features; review the output before export.
The bundled qpdf validator checks inputs before deep cleaning; an unparseable PDF
or one that requires a password is refused before the image pass.

## Inspection and editable metadata

The detail workspace separates **Overview**, **Metadata**, and **Preview**, with
one shared content width and aligned property fields. Overview shows actionable
findings and the currently staged result's validation. **Inspect** rechecks the
current copy when a result exists, so an original signature verdict is never
presented as proof about an edited file.

In **Metadata**, edit author, title, subject, keywords, description, last saved by,
or copyright where the format supports those fields. Supported formats are DOCX,
XLSX, PPTX, PDF, JPEG, PNG, TIFF and WebP. Emptying a field removes its mapped values;
unchanged fields are preserved. **Apply to Copy** edits the current staged result
(or the original on the first operation), reads the values back, and makes the
result available for review/export. Ordinary Clean and Word trace operations still
start from the original. Failed metadata writes preserve the previous result.

Office edits affect `docProps/core.xml`; other package entries retain their
uncompressed bytes. Comment/revision author names are separate and stay unchanged.
Signed Office packages are readable but editing is refused. PDF/image edits use
the bundled ExifTool with explicit field mappings and read-back verification.
PDF updates are incremental: earlier property values may remain recoverable, so
this editor is not a secure redaction facility. Metadata changes may invalidate
existing document signatures or content credentials; the result is re-inspected.

C2PA detection uses structured c2patool JSON instead of keyword matches in error
messages. The report separates embedded-manifest presence, claim-signature
validation, content-hash binding, and local certificate trust. The active signing
chain shows subject, issuer, serial, validity dates and SHA-256 fingerprints.
Missing/unsupported verifiers, malformed results, timeouts, and certificate
extraction errors remain explicit rather than becoming a clean verdict. Structural
markers can be present even when no verifiable manifest can be read.

Verification remains offline: no remote manifest fetch, live OCSP/revocation, or
CAWG identity checks. Trust is relative to the bundled verifier's local trust
configuration, not a claim of current public trust. C2PA credentials are evidence
of provenance, not a verdict about whether the content is true. The implementation
uses the [official c2patool JSON and certificate interfaces](https://github.com/contentauth/c2patool/blob/main/docs/usage.md).

## Word editing traces

Import a DOCX and open **Word editing traces** in Metadata. Inspection shows
session identifiers (RSIDs), recorded revision/comment dates, document dates,
and the recorded date range. These are editing metadata, not a complete typing
timeline.

- Session identifiers offer Keep, Randomize (the default), and Remove.
  Randomization uses fresh identifiers consistently throughout the package, so
  shared sessions remain shared; it does not conceal the grouping of edits.
- Recorded dates offer Keep (until a range is chosen), Randomize, and Remove.
  Randomization assigns existing distinct timestamps to distinct seconds within
  the chosen range, preserving chronological order and equal instants across
  different time-zone representations. Legacy dates without an offset are
  interpreted as UTC and counted in the inspection details.
- Optional **Reset ZIP entry dates** sets archive timestamps to 1 January 1980
  and removes supported extended ZIP timestamp fields. It does not change
  Finder's filesystem dates or cloud version history.
- **Apply editing traces** runs a dedicated metadata-only operation on the
  selected original, then stages a copy for inspection, preview, and export.
  The ordinary Clean action remains the provenance-cleaning operation; the two
  operations each start from the original. Review shows the before/after values
  for up to 200 fields and totals for the complete operation.

The trace operation preserves text, formatting, revision contents, comments,
author names, relationships, and embedded files. It validates XML and patches
only selected byte ranges, rather than rebuilding documents through a generic
Word serializer. Signed documents and non-UTF-8 XML are refused. Empty/malformed
dates may be kept or removed, but cannot be randomized. Opening and saving the
output in Word can create new editing metadata. This feature does not change
OneDrive/SharePoint history or external copies of the document.

## Architecture

The SwiftUI application uses `NavigationSplitView`, a queue capped at 50 files,
and an async `WatermarkEngine` abstraction. A long-lived, arm64 PyInstaller
`onedir` helper exchanges newline-delimited JSON with the app over standard
input/output and processes one file at a time. Active cancellation terminates
the helper and its child metadata tools together; the next request starts a
fresh helper.

The release helper embeds CPython 3.14.7 and PyInstaller 6.22.2. Its deterministic
toolchain also includes c2patool 0.27.16, ExifTool 13.59 with its Perl runtime
files, qpdf 12.4.1, and Ghostscript 10.07.1. Ghostscript is built as a standalone
arm64 executable with compiled-in fonts/profiles and only system dynamic libraries.
Exact source URLs and SHA-256 digests are recorded in
`Config/Dependencies.lock.json`. The 206-file upstream snapshot is independently
locked by path, executable mode, and SHA-256 in
`Config/UpstreamWatermarksRemover.manifest.sha256`; the release pipeline checks
both the working tree and Git index against it. License texts are bundled in the
app and summarized in `THIRD_PARTY_NOTICES.md`.

The outer application uses App Sandbox with user-selected read/write access.
The nested helper inherits that sandbox and is passed only staged per-job paths.

## Build and test

For a fresh tool bundle, run `./script/fetch_dependencies.sh build` first.
This downloads checksum-pinned sources and builds qpdf and Ghostscript locally.

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

The DMG also contains Ghostscript's complete corresponding source and standalone
build recipe under `Third-Party Source/Ghostscript`. Packaging verifies that the
source matches the pinned archive and remains intact after mounting the DMG.
The source directory belongs with redistributions of the release.

The release script verifies dependency receipts, entitlements, embedded
versions, offline policy, arm64 architectures, linked libraries, and helper
capabilities. It then signs nested code inside-out with Hardened Runtime, creates
and signs the DMG, optionally notarizes and staples it, and emits a source
archive, checksums, notices, verification evidence, and a release report.
The frozen integration matrix runs before the helper receives its inherit-only
sandbox signature; after signing and again from the mounted DMG, a disposable
signed sandbox parent exercises that exact helper and validates its capability
envelope. The probe is release tooling and is not shipped in the application.

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
