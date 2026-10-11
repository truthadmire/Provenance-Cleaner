# Word and embedded-media C2PA verification — 0.3.1

## Implementation

- Upgrade the official c2patool from 0.27.16 to 0.27.22 (SDK 0.90.22). The
  universal release archive was verified against GitHub's SHA-256 digest before
  staging its arm64 slice; offline settings continue to deny every network host.
- Validate document manifests at META-INF/content_credential.c2pa, including
  claim signatures, collection content hashes and the signing certificate chain.
- Inspect embedded images independently, including content-type declared images
  outside conventional media folders and JPEG/PNG/etc. stored under .bin names.
- Display document and per-asset results separately. An image's valid signature
  never becomes a Word-document or author-authenticity verdict.
- Keep absence, verification unavailable/incomplete, and validation failure
  separate. Duplicate/malformed archives, invalid manifests, unsupported media,
  missing verifiers, timeouts and size/count/time limits cannot become absence.
  Successful partial results remain visible.

## Verified before release packaging

- Source Python suite: 58 tests, zero failures.
- Swift unit suite: 44 tests, zero failures (Xcode DebugTests).
- Native UI in an isolated test preview: signed Word reports verified signature
  and content binding, with the public development signer explicitly untrusted;
  unsigned Word with a signed JPEG reports no document manifest and a separate
  image chain; expanded chain fields are aligned and readable in dark mode.
- Native import and state check for an unsigned DOCX and an unsupported embedded
  asset: respectively “No credentials found” and “Unable to verify”, with the
  incomplete report warning replacing the old no-findings message.
- The pinned upstream tree remains unchanged: 206 files verified.
- The release script is required to rerun all 58 tests against the rebuilt
  frozen engine. Direct-module tests in that suite still run source modules;
  protocol integration tests execute the frozen process. Signed sandbox probes
  additionally validate actual bundled Word and image verification.

## Scope

Inspection remains offline. Remote manifests, adjacent sidecars, linked images,
CAWG identity and live revocation are not fetched or checked. Certificate trust
is relative to the bundled verifier's local configuration. Development fixture
certificates are deliberately untrusted. Word means DOCX/OOXML, not legacy DOC.

Embedded-media limits: 128 assets, 64 MiB each, 10,000 package parts, 256 MiB
expanded package size, and 90 seconds of inspection budget. Exceeding a limit is
reported as incomplete. Inspection does not modify original document bytes.

Local logs: build/word-c2pa-probe/source-tests.log, swift-tests.log,
office-final-tests.log. The generated release report records signing,
notarization and the frozen/sandboxed checks for the published artifact.
