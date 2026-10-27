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
- **Save copy** suggests `name.cleaned.ext` and writes exactly the file chosen
  in the save panel. **Save all** writes into a chosen folder with
  collision-safe numbering, and skips outdated and already-saved copies,
  saying how many.
- Replacing an original requires confirmation, uses an atomic write, and keeps
  a recoverable `.bak` copy. It's refused when the original changed after the
  copy was made, and it doesn't carry the original's download-source record
  (`kMDItemWhereFroms`) onto the cleaned file unless you set one for the copy.
  A replaced file is then locked: it isn't checked or rebuilt again as if it
  were the original.
- Save and replace records are kept apart from each file's check results, so
  re-checking never erases them and they never hide a warning about the copy.
- Space normalization is off by default to preserve typography. Metadata
  cleaning is selective by default where the file format supports it. Office
  files (DOCX, XLSX, PPTX) always lose author, last saved by, subject, keywords,
  description and company when provenance is removed; the app says so and
  lets you set those properties again on the copy.
- Results describe findings and residual risk. They never claim that a file is
  universally “watermark-free.”
- The app has no network entitlement, telemetry, updater, or remote/model API.

Visible-logo removal, statistical text rewriting, SynthID scoring, CtrlRegen,
MarkDiffusion, audio-waveform alteration, and image regeneration are outside
the product scope. The helper removes the pinned engine's AI-authorship
(stylometry) score, SynthID/pixel fields and command-line advice from every
report, and judges text only by deterministic signals.

Office preview images (`docProps/thumbnail.*` in DOCX, XLSX and PPTX) are kept
with their metadata removed. A preview that can't be cleaned is dropped along
with its package references. The pinned engine would otherwise corrupt these
images, so `Helper/upstream_fixes.py` rebuilds them from the original.

PDF cleaning includes ExifTool document metadata stripping, qpdf structural
rewriting, and Ghostscript 10.07.1 for metadata inside embedded images. Automatic
mode deep-cleans only when provenance markers remain; it tries pass-through
before escalating to image re-encoding. Settings also offers a lossless-pass-only
mode, a deep pass for every PDF (including ordinary image metadata), and
document-only cleaning. Pass-through preserves JPEG/JPEG2000 data where supported;
other codecs may be rewritten. Results report whether the deep pass ran, whether
the additional re-encoding step ran, and whether processing was incomplete.
PDF rewriting may affect interactive features; review the output before export.

Every PDF clean, in any mode, also removes generator traces through qpdf's JSON
form (`Helper/pdf_traces.py`):
- it removes attached C2PA manifests (`/AF` and `EmbeddedFiles` entries);
- it renames resources to neutral names (`/helv`, `/gRLs0` and `/F2+0` become
  `/F1`, `/GS1` and so on);
- it merges each page's content streams;
- it gives font subsets new tags, including in their ToUnicode maps;
- it writes a new document ID.

Image and font data stay byte-identical. Form-field fonts named in `/DA`
strings keep their names. The Ghostscript pass is skipped for a PDF with no
images or attachments, because redrawing pages can change how text copies out.
Detection expands compressed object streams before scanning, and doesn't count
link URLs as AI markers. Findings shows the PDF's producer, creator and dates,
and any PyMuPDF or ReportLab traces.
The bundled qpdf validator checks inputs before deep cleaning; an unparseable PDF
or one that requires a password is refused before the image pass.

## Checking, changing and reviewing a file

Each file has three tabs, with one verdict banner above them that says what is
known and what to do next:

- **Findings** describes the original: grouped findings, anything that couldn't
  be checked (with the reason), content credentials and Word editing history.
- **Changes** is the plan for the copy: remove provenance markers, set document
  properties, set the download source, and (for DOCX) change Word editing
  history.
- **Review** describes the copy: what each step changed, the properties that
  differ from the original, anything still in the copy, its credentials, and a
  side-by-side comparison. Saving and replacing the original start here.

**Create copy** always builds from the original, in a fixed order: provenance
cleaning, then Word editing history, then property edits, then the download
source, each step reading the previous step's output. Choices can therefore be made in any order without one
silently undoing another. If any step fails or is stopped, the previous copy is
kept. Changing a choice or a cleaning setting marks the copy as outdated until
it is updated. There is no export prompt after a copy is made; the copy waits on
the Review tab until it is saved. **Check again** re-inspects the original and,
when one exists, the copy, keeping the two reports separate so an original's
signature verdict is never presented as proof about an edited file.

Edit author, title, subject, keywords, description, last saved by, or copyright
where the format supports those fields. Supported formats are DOCX, XLSX, PPTX,
PDF, JPEG, PNG, TIFF and WebP. Office files also have **Revision number**
(`cp:revision`) and **Total editing time** in minutes (`TotalTime` in
`docProps/app.xml`); both take whole numbers from 0 to 2,147,483,647, and total
editing time is offered only when the package has that properties part. Emptying a field removes its mapped values;
untouched fields are left to the earlier steps. Each edit can be undone on its
own before the copy is made.

Office edits affect `docProps/core.xml`, and total editing time changes only
its own element in `docProps/app.xml`; other package entries retain their
uncompressed bytes. Comment/revision author names are separate and stay unchanged.
Signed Office packages are readable but editing is refused. PDF/image edits use
the bundled ExifTool with explicit field mappings and read-back verification.
ExifTool appends PDF edits as an incremental update, which would leave earlier
property values recoverable, so the bundled qpdf then rewrites the whole file.
The result must have a single revision, pass `qpdf --check` and read back the
new values, or nothing is saved. This also drops revisions other apps appended
earlier. It changes properties only: names in page text, comments, bookmarks,
form fields or attachments stay, so it isn't a redaction tool. A rewrite always
breaks a PDF's digital signature, and the Changes tab says so for signed PDFs.
Metadata changes may invalidate existing document signatures or content
credentials; the result is re-inspected.

**Download source** sets Finder's "Where from" (`kMDItemWhereFroms`, a binary
property list of strings) for any file type: browsers record the file's link,
then the page it came from. The Changes tab shows the original's entries and can
reuse them. It's a file-system attribute rather than file content, so the app
sets it on a contents-only copy as the last step, read-back verified. Saving
keeps it, and replacing the original writes it in place of the original's.
Left empty, the copy has no download source, as before.

C2PA detection uses structured c2patool JSON instead of keyword matches in error
messages. The report separates embedded-manifest presence, claim-signature
validation, content-hash binding, and local certificate trust. The active signing
chain shows subject, issuer, serial, validity dates and SHA-256 fingerprints.
Missing/unsupported verifiers, malformed results, timeouts, and certificate
extraction errors remain explicit rather than becoming a clean verdict. Structural
markers can be present even when no verifiable manifest can be read.

Version 0.3.1 uses c2patool 0.27.22 to validate DOCX/OOXML credentials, including
the package's `META-INF/content_credential.c2pa` manifest and collection hashes.
Embedded images are verified separately (including image parts declared outside
the normal media folder). Each image has its own signature, content binding,
certificate chain and trust result; its credential never authenticates the Word
document or author. Inspection is read-only.

“No credentials found” means the available document and embedded-media checks
completed without finding a manifest. “Unable to verify” covers unavailable or
unsupported verifiers, malformed packages/manifests, extraction errors, timeouts
and resource limits. “Validation failed” is a completed check that found a
signature/content validation failure. Partial results remain visible, but never
become a clean verdict. Limits: 10,000 archive parts, 128 embedded assets, 64 MiB
per asset, 256 MiB expanded archive size and a 90-second media inspection budget.
Linked images, adjacent sidecars and remote manifests are outside this inspection
scope and are not fetched.

Verification remains offline: no remote manifest fetch, live OCSP/revocation, or
CAWG identity checks. Trust is relative to the bundled verifier's local trust
configuration, not a claim of current public trust. C2PA credentials are evidence
of provenance, not a verdict about whether the content is true. The implementation
uses the [official c2patool JSON and certificate interfaces](https://github.com/contentauth/c2patool/blob/main/docs/usage.md).

## Word editing traces

Import a DOCX and turn on **Change Word editing history** on the Changes tab.
Findings shows session identifiers (RSIDs), recorded revision/comment dates,
document dates, and the recorded date range. These are editing metadata, not a
complete typing timeline.

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
- The editing-history step runs as its own metadata-only operation inside the
  copy's build, after provenance cleaning and before property edits. Review
  shows the before/after values for up to 200 fields and totals for the
  complete operation.

The trace operation preserves text, formatting, revision contents, comments,
author names, relationships, and embedded files. It validates XML and patches
only selected byte ranges, rather than rebuilding documents through a generic
Word serializer. Signed documents and non-UTF-8 XML are refused. Empty/malformed
dates may be kept or removed, but cannot be randomized. Opening and saving the
output in Word can create new editing metadata. This feature does not change
OneDrive/SharePoint history or external copies of the document.

## Architecture

The SwiftUI application uses `NavigationSplitView`, a queue capped at 50 files,
and an async `WatermarkEngine` abstraction. The interface follows the Clay design
system (warm paper grounds, one clay accent, serif headings); its colour, type,
spacing and component tokens live in `App/Views/ClayTheme.swift` and use system
fonts from Clay's fallback stacks, so no font files are bundled. A long-lived, arm64 PyInstaller
`onedir` helper exchanges newline-delimited JSON with the app over standard
input/output and processes one file at a time. Active cancellation terminates
the helper and its child metadata tools together; the next request starts a
fresh helper.

The release helper embeds CPython 3.14.7 and PyInstaller 6.22.2. Its deterministic
toolchain also includes c2patool 0.27.22, ExifTool 13.59 with its Perl runtime
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
