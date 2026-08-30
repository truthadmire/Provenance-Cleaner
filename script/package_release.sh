#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/ProvenanceCleaner.xcodeproj"
SCHEME="ProvenanceCleaner"
PRODUCT_NAME="Provenance Cleaner"
EXECUTABLE_NAME="ProvenanceCleaner"
DERIVED_DIR=""
BUILT_APP=""
APP_ENTITLEMENTS="$ROOT_DIR/Config/ProvenanceCleaner.entitlements"
HELPER_ENTITLEMENTS="$ROOT_DIR/Config/Helper.entitlements"
DEPENDENCY_LOCK="$ROOT_DIR/Config/Dependencies.lock.json"
DEPENDENCY_RECEIPT="$ROOT_DIR/Vendor/Artifacts/staged/DEPENDENCY_BUILD_RECEIPT.txt"
PYINSTALLER_LOCK="$ROOT_DIR/Helper/requirements-build.txt"
VERIFICATION_EVIDENCE="$ROOT_DIR/Config/VerificationEvidence.md"
UPSTREAM_MANIFEST="$ROOT_DIR/Config/UpstreamWatermarksRemover.manifest.sha256"
SIGNING_IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
NOTARY_PROFILE="${NOTARYTOOL_PROFILE:-}"
SOURCE_REF="${SOURCE_REF:-HEAD}"
OUTPUT_DIR=""

usage() {
  cat <<'USAGE'
usage: ./script/package_release.sh [options]

Options:
  --identity NAME         Developer ID Application identity (or set
                          DEVELOPER_ID_APPLICATION). If omitted, exactly one
                          available Developer ID identity is auto-selected.
  --notary-profile NAME   notarytool keychain profile (or set
                          NOTARYTOOL_PROFILE). If omitted, notarization is
                          skipped and the report marks the DMG incomplete.
  --output DIRECTORY      New or empty output directory.
  --source-ref REF        Git ref for the source archive (default: HEAD).
  -h, --help              Show this help.

The script always builds the helper and app from the clean current HEAD,
requires all three staged tools, runs the frozen-helper integration matrix,
signs Mach-O files from the inside out with the hardened runtime, creates/signs
a DMG, optionally notarizes and staples it, and emits source/checksum/report
artifacts. A helper build requires an exact CPython 3.14.7 interpreter; set
PROVENANCE_PYTHON when it is not the default python3.
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

sha256_of() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

verify_entitlements_policy() {
  local app_key_count helper_key_count
  /usr/bin/plutil -lint "$APP_ENTITLEMENTS" "$HELPER_ENTITLEMENTS" >/dev/null
  app_key_count="$(/usr/bin/plutil -p "$APP_ENTITLEMENTS" | /usr/bin/awk '/ => / {count++} END {print count + 0}')"
  helper_key_count="$(/usr/bin/plutil -p "$HELPER_ENTITLEMENTS" | /usr/bin/awk '/ => / {count++} END {print count + 0}')"
  [[ "$app_key_count" -eq 2 ]] || \
    die "outer app entitlements must contain exactly App Sandbox and user-selected read/write"
  [[ "$(/usr/bin/plutil -extract 'com\.apple\.security\.app-sandbox' raw -o - "$APP_ENTITLEMENTS")" == "true" ]] || \
    die "outer app must enable App Sandbox"
  [[ "$(/usr/bin/plutil -extract 'com\.apple\.security\.files\.user-selected\.read-write' raw -o - "$APP_ENTITLEMENTS")" == "true" ]] || \
    die "outer app must enable user-selected read/write access"
  [[ "$helper_key_count" -eq 2 ]] || \
    die "helper entitlements must contain exactly App Sandbox and inherit"
  [[ "$(/usr/bin/plutil -extract 'com\.apple\.security\.app-sandbox' raw -o - "$HELPER_ENTITLEMENTS")" == "true" ]] || \
    die "helper must enable App Sandbox"
  [[ "$(/usr/bin/plutil -extract 'com\.apple\.security\.inherit' raw -o - "$HELPER_ENTITLEMENTS")" == "true" ]] || \
    die "helper must inherit the parent sandbox"
}

is_macho() {
  /usr/bin/file -b "$1" | /usr/bin/grep -q 'Mach-O'
}

sign_macho() {
  local path="$1"
  /usr/bin/codesign --force --timestamp --options runtime \
    --sign "$SIGNING_IDENTITY" "$path"
}

audit_linked_libraries() {
  local app="$1"
  local path linked bad=0
  while IFS= read -r -d '' path; do
    if ! is_macho "$path"; then
      continue
    fi
    linked="$(/usr/bin/otool -L "$path" | /usr/bin/tail -n +2 | /usr/bin/awk '{print $1}')"
    if echo "$linked" | /usr/bin/grep -Ev '^(@|/System/Library/|/usr/lib/)' >/dev/null; then
      echo "non-relocatable libraries in $path:" >&2
      echo "$linked" | /usr/bin/grep -Ev '^(@|/System/Library/|/usr/lib/)' >&2 || true
      bad=1
    fi
  done < <(/usr/bin/find "$app/Contents" -type f -print0)
  [[ "$bad" -eq 0 ]] || die "bundle contains non-relocatable linked libraries"
}

audit_architectures() {
  local app="$1"
  local path arches bad=0
  while IFS= read -r -d '' path; do
    if ! is_macho "$path"; then
      continue
    fi
    arches="$(/usr/bin/lipo -archs "$path")"
    if [[ "$arches" != "arm64" ]]; then
      echo "unexpected architecture in $path: $arches" >&2
      bad=1
    fi
  done < <(/usr/bin/find "$app/Contents" -type f -print0)
  [[ "$bad" -eq 0 ]] || die "bundle contains non-arm64 Mach-O code"
}

audit_hardened_runtime() {
  local app="$1"
  local path bad=0
  while IFS= read -r -d '' path; do
    if ! is_macho "$path"; then
      continue
    fi
    if ! /usr/bin/codesign -dv --verbose=4 "$path" 2>&1 | \
      /usr/bin/grep -E 'flags=.*\(.*runtime.*\)' >/dev/null; then
      echo "Hardened Runtime is missing from $path" >&2
      bad=1
    fi
  done < <(/usr/bin/find "$app/Contents" -type f -print0)
  [[ "$bad" -eq 0 ]] || die "bundle contains Mach-O code without Hardened Runtime"
}

verify_signed_entitlements() {
  local app="$1"
  local helper_app="$app/Contents/Helpers/ProvenanceEngine.app"
  local actual_app actual_helper app_key_count helper_key_count
  actual_app="$(/usr/bin/mktemp /private/tmp/provenance-signed-app-entitlements.XXXXXX)"
  actual_helper="$(/usr/bin/mktemp /private/tmp/provenance-signed-helper-entitlements.XXXXXX)"
  /usr/bin/codesign -d --entitlements :- "$app" >"$actual_app" 2>/dev/null || \
    die "could not extract signed outer-app entitlements"
  /usr/bin/codesign -d --entitlements :- "$helper_app" >"$actual_helper" 2>/dev/null || \
    die "could not extract signed helper entitlements"
  /usr/bin/plutil -lint "$actual_app" "$actual_helper" >/dev/null
  app_key_count="$(/usr/bin/plutil -p "$actual_app" | /usr/bin/awk '/ => / {count++} END {print count + 0}')"
  helper_key_count="$(/usr/bin/plutil -p "$actual_helper" | /usr/bin/awk '/ => / {count++} END {print count + 0}')"
  [[ "$app_key_count" -eq 2 ]] || die "signed outer app contains unexpected entitlements"
  [[ "$helper_key_count" -eq 2 ]] || die "signed helper contains unexpected entitlements"
  [[ "$(/usr/bin/plutil -extract 'com\.apple\.security\.app-sandbox' raw -o - "$actual_app")" == "true" ]] || \
    die "signed outer app is missing App Sandbox"
  [[ "$(/usr/bin/plutil -extract 'com\.apple\.security\.files\.user-selected\.read-write' raw -o - "$actual_app")" == "true" ]] || \
    die "signed outer app is missing user-selected read/write"
  [[ "$(/usr/bin/plutil -extract 'com\.apple\.security\.app-sandbox' raw -o - "$actual_helper")" == "true" ]] || \
    die "signed helper is missing App Sandbox"
  [[ "$(/usr/bin/plutil -extract 'com\.apple\.security\.inherit' raw -o - "$actual_helper")" == "true" ]] || \
    die "signed helper is missing sandbox inheritance"
  /bin/rm -f -- "$actual_app" "$actual_helper"
}

sign_inside_out() {
  local app="$1"
  local path helper_app
  helper_app="$app/Contents/Helpers/ProvenanceEngine.app"

  /usr/bin/xattr -cr "$app"
  if [[ -n "$(/usr/bin/xattr -lr "$app" 2>/dev/null)" ]]; then
    /usr/bin/xattr -lr "$app" >&2 || true
    die "extended attributes remained after clearing the disposable signing tree"
  fi
  while IFS= read -r -d '' path; do
    if is_macho "$path"; then
      sign_macho "$path"
    fi
  done < <(/usr/bin/find "$app/Contents" -type f -print0)

  while IFS= read -r -d '' path; do
    /usr/bin/codesign --force --timestamp --options runtime \
      --sign "$SIGNING_IDENTITY" "$path"
  done < <(/usr/bin/find "$app/Contents" -depth -type d \
    \( -name '*.framework' -o -name '*.xpc' -o -name '*.appex' -o \
       -name '*.plugin' -o -name '*.bundle' \) -print0)

  /usr/bin/codesign --force --timestamp --options runtime \
    --entitlements "$HELPER_ENTITLEMENTS" \
    --sign "$SIGNING_IDENTITY" "$helper_app"
  /usr/bin/codesign --force --timestamp --options runtime \
    --entitlements "$APP_ENTITLEMENTS" \
    --sign "$SIGNING_IDENTITY" "$app"
}

verify_expected_payload() {
  local app="$1"
  local helper_root helper_frameworks helper_resources license_resource capabilities
  helper_root="$app/Contents/Helpers/ProvenanceEngine.app/Contents"
  helper_frameworks="$helper_root/Frameworks/tools"
  helper_resources="$helper_root/Resources/tools"
  [[ -x "$app/Contents/MacOS/$EXECUTABLE_NAME" ]] || die "missing main executable"
  [[ -x "$helper_root/MacOS/provenance-engine" ]] || die "missing bundled helper"
  [[ -x "$helper_frameworks/c2patool/c2patool" ]] || die "missing bundled c2patool"
  [[ -f "$helper_resources/c2patool/offline.toml" ]] || die "missing bundled c2patool offline settings"
  [[ -x "$helper_resources/exiftool/exiftool" ]] || die "missing bundled ExifTool"
  [[ -d "$helper_resources/exiftool/lib" ]] || die "missing bundled ExifTool lib directory"
  [[ -x "$helper_frameworks/qpdf/qpdf" ]] || die "missing bundled qpdf"
  [[ -f "$app/Contents/Resources/THIRD_PARTY_NOTICES.md" ]] || die "missing third-party notices resource"
  [[ -f "$app/Contents/Resources/Dependencies.lock.json" ]] || die "missing dependency lock resource"
  [[ -f "$app/Contents/Resources/UpstreamWatermarksRemover.manifest.sha256" ]] || \
    die "missing pinned upstream tree manifest resource"
  for license_resource in \
    watermarks-remover-LICENSE-MIT.txt \
    c2pa-rs-LICENSE-MIT.txt \
    ExifTool-COPYRIGHT-AND-LICENSE.txt \
    ExifTool-LICENSE-Artistic-1.0-Perl.txt \
    qpdf-LICENSE-Apache-2.0.txt \
    qpdf-NOTICE.md \
    libjpeg-turbo-LICENSE.md \
    CPython-LICENSE-PSF-2.0.txt \
    OpenSSL-NOTICE.txt \
    zstd-LICENSE-BSD-3-Clause.txt \
    PyInstaller-COPYING.txt; do
    /usr/bin/find "$app/Contents/Resources" -type f -name "$license_resource" -print -quit | \
      /usr/bin/grep . >/dev/null || die "missing third-party license resource: $license_resource"
  done
  /usr/bin/cmp -s "$DEPENDENCY_LOCK" "$app/Contents/Resources/Dependencies.lock.json" || \
    die "bundled dependency lock does not match the canonical release lock"
  /usr/bin/cmp -s "$UPSTREAM_MANIFEST" \
    "$app/Contents/Resources/UpstreamWatermarksRemover.manifest.sha256" || \
    die "bundled upstream manifest does not match the canonical release manifest"
  /usr/bin/cmp -s "$ROOT_DIR/App/Resources/c2patool-offline.toml" \
    "$helper_resources/c2patool/offline.toml" || \
    die "bundled c2patool settings do not match the reviewed offline policy"
  "$helper_frameworks/c2patool/c2patool" --version | /usr/bin/grep -F '0.27.16' >/dev/null || \
    die "unexpected bundled c2patool version"
  [[ "$("$helper_resources/exiftool/exiftool" -ver)" == "13.59" ]] || \
    die "unexpected bundled ExifTool version"
  "$helper_frameworks/qpdf/qpdf" --version | /usr/bin/grep -F '12.4.1' >/dev/null || \
    die "unexpected bundled qpdf version"
  capabilities="$(printf '%s\n' '{"requestID":"release-audit","operation":"capabilities"}' | \
    "$helper_root/MacOS/provenance-engine")"
  [[ "$(printf '%s' "$capabilities" | /usr/bin/plutil -extract report.runtime.pythonVersion raw -o - -)" == "3.14.7" ]] || \
    die "unexpected bundled CPython version"
  printf '%s' "$capabilities" | /usr/bin/plutil -extract report.runtime.opensslVersion raw -o - - | \
    /usr/bin/grep -F 'OpenSSL 3.5.7' >/dev/null || die "unexpected bundled OpenSSL version"
  [[ "$(printf '%s' "$capabilities" | /usr/bin/plutil -extract report.execution.offline raw -o - -)" == "true" ]] || \
    die "bundled helper does not report offline execution"
  [[ "$(printf '%s' "$capabilities" | /usr/bin/plutil -extract report.execution.c2patoolNetworkPolicy raw -o - -)" == "deny-all" ]] || \
    die "bundled helper does not report the deny-all c2patool policy"
  [[ "$(printf '%s' "$capabilities" | /usr/bin/plutil -extract report.upstream.tools.ghostscript raw -o - -)" == "false" ]] || \
    die "bundled helper unexpectedly reports Ghostscript availability"
  if /usr/bin/find "$app" \( -iname 'gs' -o -iname 'ghostscript' \) -print | /usr/bin/grep . >/dev/null; then
    die "Ghostscript is excluded from this release but was found in the app bundle"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity)
      [[ $# -ge 2 ]] || die "--identity requires a value"
      SIGNING_IDENTITY="$2"; shift 2
      ;;
    --notary-profile)
      [[ $# -ge 2 ]] || die "--notary-profile requires a value"
      NOTARY_PROFILE="$2"; shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || die "--output requires a value"
      OUTPUT_DIR="$2"; shift 2
      ;;
    --source-ref)
      [[ $# -ge 2 ]] || die "--source-ref requires a value"
      SOURCE_REF="$2"; shift 2
      ;;
    -h|--help)
      usage; exit 0
      ;;
    *)
      usage >&2; die "unknown option: $1"
      ;;
  esac
done

for command_name in xcodebuild xcrun xcodegen codesign security hdiutil ditto git plutil otool; do
  require_command "$command_name"
done
[[ "$(/usr/bin/uname -s)" == "Darwin" ]] || die "release packaging requires macOS"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  AVAILABLE_DEVELOPER_IDS="$(/usr/bin/security find-identity -p codesigning -v | \
    /usr/bin/sed -n 's/^[[:space:]]*[0-9][0-9]*) [0-9A-F]* "\(Developer ID Application:.*\)"$/\1/p')"
  IDENTITY_COUNT="$(printf '%s\n' "$AVAILABLE_DEVELOPER_IDS" | \
    /usr/bin/awk 'NF {count++} END {print count + 0}')"
  [[ "$IDENTITY_COUNT" -gt 0 ]] || \
    die "no Developer ID Application identity is available; pass --identity after installing one"
  [[ "$IDENTITY_COUNT" -eq 1 ]] || \
    die "multiple Developer ID Application identities are available; select one with --identity"
  SIGNING_IDENTITY="$AVAILABLE_DEVELOPER_IDS"
  echo "auto-selected signing identity: $SIGNING_IDENTITY"
fi
[[ "$SIGNING_IDENTITY" == *"Developer ID Application"* ]] || \
  die "the release identity must be a Developer ID Application identity"
/usr/bin/security find-identity -p codesigning -v | /usr/bin/grep -F "$SIGNING_IDENTITY" >/dev/null || \
  die "signing identity is not available in the current keychain: $SIGNING_IDENTITY"
verify_entitlements_policy
/usr/bin/plutil -extract schemaVersion raw -o - "$DEPENDENCY_LOCK" >/dev/null
"$ROOT_DIR/script/fetch_dependencies.sh" verify
"$ROOT_DIR/script/verify_upstream_snapshot.sh"
[[ -f "$DEPENDENCY_RECEIPT" ]] || die "missing dependency build receipt"
[[ -f "$PYINSTALLER_LOCK" ]] || die "missing hash-locked PyInstaller requirements"
[[ -f "$VERIFICATION_EVIDENCE" ]] || die "missing release verification evidence"
[[ -f "$UPSTREAM_MANIFEST" ]] || die "missing pinned upstream tree manifest"

DERIVED_DIR="$(/usr/bin/mktemp -d /private/tmp/provenance-release-derived.XXXXXX)"
BUILT_APP="$DERIVED_DIR/Build/Products/Release/$PRODUCT_NAME.app"
PACKAGE_TEMP=""
MOUNT_POINT=""
DMG_MOUNTED=0
cleanup_release_temps() {
  local temporary_path
  if [[ "$DMG_MOUNTED" -eq 1 && -n "$MOUNT_POINT" ]]; then
    /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
  fi
  for temporary_path in "$DERIVED_DIR" "$PACKAGE_TEMP"; do
    if [[ -n "$temporary_path" && "$temporary_path" == /private/tmp/provenance-* ]]; then
      /bin/rm -rf -- "$temporary_path"
    fi
  done
}
trap cleanup_release_temps EXIT

HELPER_PYTHON="${PROVENANCE_PYTHON:-$(command -v python3 || true)}"
[[ -n "$HELPER_PYTHON" && -x "$HELPER_PYTHON" ]] || \
  die "release helper build requires an executable CPython 3.14.7 interpreter"
if [[ -n "${PROVENANCE_DYLD_FRAMEWORK_PATH:-}" ]]; then
  HELPER_PYTHON_VERSION="$(DYLD_FRAMEWORK_PATH="$PROVENANCE_DYLD_FRAMEWORK_PATH" \
    "$HELPER_PYTHON" -c 'import platform; print(platform.python_version())')" || \
    die "could not run the selected PROVENANCE_PYTHON"
else
  HELPER_PYTHON_VERSION="$("$HELPER_PYTHON" -c 'import platform; print(platform.python_version())')" || \
    die "could not run the selected helper Python"
fi
[[ "$HELPER_PYTHON_VERSION" == "3.14.7" ]] || \
  die "release helper requires CPython 3.14.7, got $HELPER_PYTHON_VERSION; set PROVENANCE_PYTHON"
[[ -x "$ROOT_DIR/script/build_helper.sh" ]] || die "missing script/build_helper.sh"
"$ROOT_DIR/script/build_helper.sh"
xcodegen generate --spec "$ROOT_DIR/project.yml" --project "$ROOT_DIR"
/usr/bin/xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

[[ -d "$BUILT_APP" ]] || die "app bundle not found: $BUILT_APP"
/usr/bin/ditto "$DEPENDENCY_LOCK" "$BUILT_APP/Contents/Resources/Dependencies.lock.json"
verify_expected_payload "$BUILT_APP"
audit_linked_libraries "$BUILT_APP"
audit_architectures "$BUILT_APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT_APP/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$BUILT_APP/Contents/Info.plist")"
[[ -n "$VERSION" && -n "$BUILD_NUMBER" ]] || die "missing version metadata"
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$ROOT_DIR/dist/release-$VERSION-$BUILD_NUMBER"
elif [[ "$OUTPUT_DIR" != /* ]]; then
  OUTPUT_DIR="$PWD/$OUTPUT_DIR"
fi
if [[ -e "$OUTPUT_DIR" && ! -d "$OUTPUT_DIR" ]]; then
  die "output path exists and is not a directory: $OUTPUT_DIR"
fi
if [[ -d "$OUTPUT_DIR" && -n "$(/usr/bin/find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  die "output directory is not empty: $OUTPUT_DIR"
fi

[[ -z "$(/usr/bin/git -C "$ROOT_DIR" status --porcelain)" ]] || \
  die "source tree is dirty; release artifacts must be built from a clean commit"
SOURCE_COMMIT="$(/usr/bin/git -C "$ROOT_DIR" rev-parse --verify "$SOURCE_REF^{commit}")" || \
  die "source ref does not resolve to a commit: $SOURCE_REF"
CURRENT_HEAD="$(/usr/bin/git -C "$ROOT_DIR" rev-parse --verify HEAD^{commit})" || \
  die "current HEAD does not resolve to a commit"
[[ "$SOURCE_COMMIT" == "$CURRENT_HEAD" ]] || \
  die "source ref must resolve to the clean current HEAD used for this build"

verify_entitlements_policy
sign_inside_out "$BUILT_APP"
/usr/bin/codesign --verify --deep --strict --verbose=4 "$BUILT_APP"
audit_linked_libraries "$BUILT_APP"
audit_architectures "$BUILT_APP"
audit_hardened_runtime "$BUILT_APP"
verify_signed_entitlements "$BUILT_APP"
verify_expected_payload "$BUILT_APP"

HELPER_INTEGRATION_LOG="$DERIVED_DIR/FrozenHelperIntegrationTests.txt"
HELPER_UNDER_TEST="$BUILT_APP/Contents/Helpers/ProvenanceEngine.app/Contents/MacOS/provenance-engine"
if [[ -n "${PROVENANCE_DYLD_FRAMEWORK_PATH:-}" ]]; then
  if ! PROVENANCE_HELPER_UNDER_TEST="$HELPER_UNDER_TEST" \
    DYLD_FRAMEWORK_PATH="$PROVENANCE_DYLD_FRAMEWORK_PATH" \
    DYLD_LIBRARY_PATH="${PROVENANCE_DYLD_LIBRARY_PATH:-}" \
    "$HELPER_PYTHON" "$ROOT_DIR/Tests/HelperIntegration/test_provenance_helper.py" \
    >"$HELPER_INTEGRATION_LOG" 2>&1; then
    /bin/cat "$HELPER_INTEGRATION_LOG" >&2
    die "signed frozen helper integration matrix failed"
  fi
else
  if ! PROVENANCE_HELPER_UNDER_TEST="$HELPER_UNDER_TEST" \
    "$HELPER_PYTHON" "$ROOT_DIR/Tests/HelperIntegration/test_provenance_helper.py" \
    >"$HELPER_INTEGRATION_LOG" 2>&1; then
    /bin/cat "$HELPER_INTEGRATION_LOG" >&2
    die "signed frozen helper integration matrix failed"
  fi
fi
/bin/cat "$HELPER_INTEGRATION_LOG"

/bin/mkdir -p "$OUTPUT_DIR"
SOURCE_ARCHIVE="$OUTPUT_DIR/ProvenanceCleaner-$VERSION-source.zip"
/usr/bin/git -C "$ROOT_DIR" archive --format=zip \
  --prefix="ProvenanceCleaner-$VERSION/" \
  --output="$SOURCE_ARCHIVE" "$SOURCE_REF"
/usr/bin/ditto "$DEPENDENCY_LOCK" "$OUTPUT_DIR/Dependencies.lock.json"
/usr/bin/ditto "$DEPENDENCY_RECEIPT" "$OUTPUT_DIR/DEPENDENCY_BUILD_RECEIPT.txt"
/usr/bin/ditto "$PYINSTALLER_LOCK" "$OUTPUT_DIR/PYINSTALLER_REQUIREMENTS_LOCK.txt"
/usr/bin/ditto "$VERIFICATION_EVIDENCE" "$OUTPUT_DIR/VERIFICATION_EVIDENCE.md"
/usr/bin/ditto "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$OUTPUT_DIR/THIRD_PARTY_NOTICES.md"
/usr/bin/ditto "$HELPER_INTEGRATION_LOG" "$OUTPUT_DIR/FROZEN_HELPER_INTEGRATION_TESTS.txt"
/usr/bin/ditto "$UPSTREAM_MANIFEST" "$OUTPUT_DIR/UPSTREAM_WATERMARKS_REMOVER_MANIFEST.sha256"

PACKAGE_TEMP="$(/usr/bin/mktemp -d /private/tmp/provenance-release-package.XXXXXX)"
DMG_STAGE="$PACKAGE_TEMP/dmg-root"
/bin/mkdir -p "$DMG_STAGE"
/usr/bin/ditto "$BUILT_APP" "$DMG_STAGE/$PRODUCT_NAME.app"
/bin/ln -s /Applications "$DMG_STAGE/Applications"
DMG_PATH="$OUTPUT_DIR/ProvenanceCleaner-$VERSION.dmg"
/usr/bin/hdiutil create \
  -volname "$PRODUCT_NAME $VERSION" \
  -srcfolder "$DMG_STAGE" \
  -format UDZO \
  "$DMG_PATH"
/usr/bin/codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG_PATH"
/usr/bin/codesign --verify --verbose=4 "$DMG_PATH"

NOTARIZATION_STATUS="skipped (NOTARYTOOL_PROFILE was not provided)"
if [[ -n "$NOTARY_PROFILE" ]]; then
  NOTARY_JSON="$OUTPUT_DIR/notarization.json"
  /usr/bin/xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait --output-format json > "$NOTARY_JSON"
  NOTARIZATION_STATUS="$(/usr/bin/plutil -extract status raw -o - "$NOTARY_JSON")"
  [[ "$NOTARIZATION_STATUS" == "Accepted" ]] || die "notarization was not accepted; see $NOTARY_JSON"
  /usr/bin/xcrun stapler staple "$DMG_PATH"
  /usr/bin/xcrun stapler validate "$DMG_PATH"
  /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
fi

/usr/bin/hdiutil verify "$DMG_PATH"
MOUNT_POINT="$PACKAGE_TEMP/mounted-dmg"
/bin/mkdir -p "$MOUNT_POINT"
/usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_POINT" "$DMG_PATH" >/dev/null
DMG_MOUNTED=1
MOUNTED_APP="$MOUNT_POINT/$PRODUCT_NAME.app"
[[ -d "$MOUNTED_APP" ]] || die "signed DMG does not contain the expected application"
/usr/bin/codesign --verify --deep --strict --verbose=4 "$MOUNTED_APP"
audit_linked_libraries "$MOUNTED_APP"
audit_architectures "$MOUNTED_APP"
audit_hardened_runtime "$MOUNTED_APP"
verify_signed_entitlements "$MOUNTED_APP"
verify_expected_payload "$MOUNTED_APP"
if [[ -n "$NOTARY_PROFILE" ]]; then
  /usr/sbin/spctl --assess --type execute --verbose=4 "$MOUNTED_APP"
fi
/usr/bin/hdiutil detach "$MOUNT_POINT" -quiet
DMG_MOUNTED=0

CHECKSUMS="$OUTPUT_DIR/SHA256SUMS.txt"
(
  cd "$OUTPUT_DIR"
  checksum_files=(
    "$(basename "$DMG_PATH")"
    "$(basename "$SOURCE_ARCHIVE")"
    Dependencies.lock.json
    DEPENDENCY_BUILD_RECEIPT.txt
    PYINSTALLER_REQUIREMENTS_LOCK.txt
    VERIFICATION_EVIDENCE.md
    THIRD_PARTY_NOTICES.md
    FROZEN_HELPER_INTEGRATION_TESTS.txt
    UPSTREAM_WATERMARKS_REMOVER_MANIFEST.sha256
  )
  if [[ -f notarization.json ]]; then
    checksum_files+=(notarization.json)
  fi
  /usr/bin/shasum -a 256 "${checksum_files[@]}" > "$(basename "$CHECKSUMS")"
)

REPORT="$OUTPUT_DIR/RELEASE_REPORT.md"
{
  echo "# Provenance Cleaner $VERSION ($BUILD_NUMBER) Release Report"
  echo
  echo "- Generated: $(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "- Source commit: $SOURCE_COMMIT"
  echo "- Signing identity: $SIGNING_IDENTITY"
  echo "- Hardened runtime: enabled on nested Mach-O code and the outer app"
  echo "- Sandbox: outer app uses App Sandbox + user-selected read/write; nested helper uses App Sandbox + inherit and receives only app-container staged paths"
  echo "- Notarization: $NOTARIZATION_STATUS"
  echo "- Stapling: $([[ -n "$NOTARY_PROFILE" ]] && echo validated || echo not performed)"
  echo "- Architectures: application, frozen CPython/OpenSSL/zstd, c2patool, and qpdf arm64; qpdf uses static libqpdf+libjpeg"
  echo "- c2patool network policy: all SDK hosts blocked; remote manifests, OCSP, and CAWG identity decoding disabled"
  echo "- ExifTool license option: Artistic-1.0-Perl"
  echo "- Ghostscript: excluded"
  echo "- Dependency lock SHA-256: $(sha256_of "$DEPENDENCY_LOCK")"
  echo "- Pinned upstream tree manifest SHA-256: $(sha256_of "$UPSTREAM_MANIFEST")"
  echo "- PyInstaller requirements lock SHA-256: $(sha256_of "$PYINSTALLER_LOCK")"
  echo
  echo "## Artifacts"
  echo
  while IFS= read -r checksum_line; do echo "- $checksum_line"; done < "$CHECKSUMS"
  echo
  echo "## Verification"
  echo
  echo "- codesign deep/strict verification: passed"
  echo "- signed entitlement policy: outer app and inherited helper sandbox entitlements passed exact-key validation"
  echo "- Hardened Runtime audit: every embedded Mach-O passed"
  echo "- linked-library relocation audit: passed"
  echo "- arm64-only Mach-O audit: passed"
  echo "- required helper/tool payload audit: passed"
  echo "- helper capability audit before and after signing: CPython/OpenSSL versions, offline mode, c2patool deny-all, and Ghostscript exclusion passed"
  echo "- frozen helper integration matrix: passed against the exact helper embedded in the signed app (see FROZEN_HELPER_INTEGRATION_TESTS.txt)"
  echo "- DMG filesystem verification, mounted-app strict signature, architecture, linked-library, and helper capability checks: passed"
  if [[ -z "$NOTARY_PROFILE" ]]; then
    echo "- Gatekeeper distribution verification: pending notarization"
  else
    echo "- notarytool acceptance, staple validation, and Gatekeeper assessment: passed"
  fi
  echo
  /bin/cat "$VERIFICATION_EVIDENCE"
} > "$REPORT"

echo "release artifacts: $OUTPUT_DIR"
cat "$REPORT"
