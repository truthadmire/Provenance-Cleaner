#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_FILE="$ROOT_DIR/Config/Dependencies.lock.json"
ARTIFACTS_DIR="$ROOT_DIR/Vendor/Artifacts"
DOWNLOADS_DIR="$ARTIFACTS_DIR/downloads"
STAGED_DIR="$ARTIFACTS_DIR/staged"
MODE="${1:-build}"

usage() {
  cat <<'USAGE'
usage: ./script/fetch_dependencies.sh [fetch|build|verify]

  fetch   Download and SHA-256 verify the locked runtime artifacts.
  build   Fetch, stage c2patool/ExifTool, build arm64 qpdf/Ghostscript, verify all.
  verify  Verify already-staged tools and emit their versions/hashes.

CPython and PyInstaller are intentionally not installed here. They are pinned
in Config/Dependencies.lock.json for script/build_helper.sh.
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

lock_value() {
  /usr/bin/plutil -extract "components.$1.$2" raw -o - "$LOCK_FILE"
}

require_macos_arm64() {
  [[ "$(/usr/bin/uname -s)" == "Darwin" ]] || die "dependency staging is supported only on macOS"
  [[ "$(/usr/bin/uname -m)" == "arm64" ]] || die "qpdf must be built on an arm64 Mac"
}

sha256_of() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

verify_hash() {
  local path="$1"
  local expected="$2"
  local actual
  actual="$(sha256_of "$path")"
  [[ "$actual" == "$expected" ]] || die "SHA-256 mismatch for $path (expected $expected, got $actual)"
}

fetch_component() {
  local component="$1"
  local file_name url expected destination temporary
  file_name="$(lock_value "$component" "artifact.fileName")"
  url="$(lock_value "$component" "artifact.url")"
  expected="$(lock_value "$component" "artifact.sha256")"
  destination="$DOWNLOADS_DIR/$file_name"

  if [[ -f "$destination" ]]; then
    verify_hash "$destination" "$expected"
    echo "verified cached $file_name"
    return
  fi

  temporary="$destination.partial.$$"
  /usr/bin/curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
    --output "$temporary" "$url"
  verify_hash "$temporary" "$expected"
  /bin/mv "$temporary" "$destination"
  echo "fetched and verified $file_name"
}

replace_stage_dir() {
  local prepared="$1"
  local destination="$2"
  case "$destination" in
    "$STAGED_DIR"/*) ;;
    *) die "refusing to replace an unexpected path: $destination" ;;
  esac
  if [[ -e "$destination" ]]; then
    /bin/mv "$destination" "$SCRATCH_DIR/previous-$(/usr/bin/basename "$destination")"
  fi
  /bin/mv "$prepared" "$destination"
}

stage_c2patool() {
  local archive extracted prepared arches universal_binary
  archive="$DOWNLOADS_DIR/$(lock_value c2patool artifact.fileName)"
  extracted="$SCRATCH_DIR/c2patool-extracted"
  prepared="$SCRATCH_DIR/c2patool-stage"
  /bin/mkdir -p "$extracted" "$prepared"
  /usr/bin/ditto -x -k "$archive" "$extracted"
  universal_binary="$extracted/c2patool/c2patool"
  arches="$(/usr/bin/lipo -archs "$universal_binary")"
  [[ " $arches " == *" arm64 "* && " $arches " == *" x86_64 "* ]] || \
    die "downloaded c2patool is not universal2: $arches"
  /usr/bin/lipo "$universal_binary" -thin arm64 -output "$prepared/c2patool"
  /bin/chmod 0755 "$prepared/c2patool"
  /usr/bin/install -m 0644 \
    "$ROOT_DIR/App/Resources/ThirdPartyLicenses/c2pa-rs-LICENSE-MIT.txt" \
    "$prepared/LICENSE-MIT.txt"
  /usr/bin/install -m 0644 \
    "$ROOT_DIR/App/Resources/c2patool-offline.toml" \
    "$prepared/offline.toml"
  arches="$(/usr/bin/lipo -archs "$prepared/c2patool")"
  [[ "$arches" == "arm64" ]] || die "staged c2patool is not arm64: $arches"
  replace_stage_dir "$prepared" "$STAGED_DIR/c2patool"
}

stage_exiftool() {
  local archive source_root prepared
  archive="$DOWNLOADS_DIR/$(lock_value exiftool artifact.fileName)"
  /usr/bin/tar -xzf "$archive" -C "$SCRATCH_DIR"
  source_root="$SCRATCH_DIR/exiftool-$(lock_value exiftool sourceCommit)"
  [[ -f "$source_root/exiftool" && -d "$source_root/lib" ]] || \
    die "unexpected ExifTool archive layout"
  prepared="$SCRATCH_DIR/exiftool-stage"
  /bin/mkdir -p "$prepared"
  /usr/bin/install -m 0755 "$source_root/exiftool" "$prepared/exiftool"
  /usr/bin/ditto "$source_root/lib" "$prepared/lib"
  /usr/bin/install -m 0644 \
    "$ROOT_DIR/App/Resources/ThirdPartyLicenses/ExifTool-COPYRIGHT-AND-LICENSE.txt" \
    "$prepared/COPYRIGHT-AND-LICENSE.txt"
  /usr/bin/install -m 0644 \
    "$ROOT_DIR/App/Resources/ThirdPartyLicenses/ExifTool-LICENSE-Artistic-1.0-Perl.txt" \
    "$prepared/LICENSE-Artistic-1.0-Perl.txt"
  replace_stage_dir "$prepared" "$STAGED_DIR/exiftool"
}

build_qpdf() {
  local cmake_path jobs sdk_path jpeg_archive qpdf_archive jpeg_source qpdf_source
  local jpeg_build jpeg_prefix jpeg_library qpdf_build prepared qpdf_binary
  cmake_path="$(command -v cmake || true)"
  [[ -n "$cmake_path" ]] || die "cmake is required to build the pinned static qpdf (for example: brew install cmake)"
  sdk_path="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
  [[ -f "$sdk_path/usr/include/zlib.h" && -e "$sdk_path/usr/lib/libz.tbd" ]] || \
    die "the selected macOS SDK does not contain zlib headers/stub"
  jobs="$(/usr/sbin/sysctl -n hw.logicalcpu 2>/dev/null || echo 4)"

  jpeg_archive="$DOWNLOADS_DIR/$(lock_value libjpegTurbo artifact.fileName)"
  qpdf_archive="$DOWNLOADS_DIR/$(lock_value qpdf artifact.fileName)"
  /usr/bin/tar -xzf "$jpeg_archive" -C "$SCRATCH_DIR"
  /usr/bin/tar -xzf "$qpdf_archive" -C "$SCRATCH_DIR"
  jpeg_source="$SCRATCH_DIR/libjpeg-turbo-$(lock_value libjpegTurbo version)"
  qpdf_source="$SCRATCH_DIR/qpdf-$(lock_value qpdf version)"
  jpeg_build="$SCRATCH_DIR/libjpeg-build"
  jpeg_prefix="$SCRATCH_DIR/libjpeg-prefix"
  qpdf_build="$SCRATCH_DIR/qpdf-build"

  "$cmake_path" -S "$jpeg_source" -B "$jpeg_build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_INSTALL_PREFIX="$jpeg_prefix" \
    -DENABLE_SHARED=OFF \
    -DENABLE_STATIC=ON \
    -DWITH_SIMD=OFF \
    -DWITH_TURBOJPEG=OFF \
    -DWITH_TOOLS=OFF \
    -DWITH_TESTS=OFF
  "$cmake_path" --build "$jpeg_build" --parallel "$jobs"
  "$cmake_path" --install "$jpeg_build"
  jpeg_library="$(/usr/bin/find "$jpeg_prefix" -type f -name libjpeg.a -print -quit)"
  [[ -n "$jpeg_library" ]] || die "static libjpeg.a was not produced"

  /bin/mkdir -p "$SCRATCH_DIR/empty-pkgconfig"
  PKG_CONFIG_LIBDIR="$SCRATCH_DIR/empty-pkgconfig" "$cmake_path" \
    -S "$qpdf_source" -B "$qpdf_build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_SKIP_RPATH=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_STATIC_LIBS=ON \
    -DBUILD_DOC=OFF \
    -DINSTALL_MANUAL=OFF \
    -DINSTALL_PKGCONFIG=OFF \
    -DINSTALL_CMAKE_PACKAGE=OFF \
    -DINSTALL_EXAMPLES=OFF \
    -DUSE_IMPLICIT_CRYPTO=OFF \
    -DREQUIRE_CRYPTO_NATIVE=ON \
    -DZLIB_H_PATH="$sdk_path/usr/include" \
    -DZLIB_LIB_PATH="$sdk_path/usr/lib/libz.tbd" \
    -DLIBJPEG_H_PATH="$jpeg_prefix/include" \
    -DLIBJPEG_LIB_PATH="$jpeg_library"
  "$cmake_path" --build "$qpdf_build" --target qpdf --parallel "$jobs"
  qpdf_binary="$qpdf_build/qpdf/qpdf"
  [[ -x "$qpdf_binary" ]] || die "qpdf binary was not produced at $qpdf_binary"

  prepared="$SCRATCH_DIR/qpdf-stage"
  /bin/mkdir -p "$prepared"
  /usr/bin/install -m 0755 "$qpdf_binary" "$prepared/qpdf"
  /usr/bin/install -m 0644 "$qpdf_source/LICENSE.txt" "$prepared/LICENSE.txt"
  /usr/bin/install -m 0644 "$qpdf_source/NOTICE.md" "$prepared/NOTICE.md"
  /usr/bin/install -m 0644 "$jpeg_source/LICENSE.md" "$prepared/libjpeg-turbo-LICENSE.md"
  replace_stage_dir "$prepared" "$STAGED_DIR/qpdf"
}

build_ghostscript() {
  local archive prepared
  archive="$DOWNLOADS_DIR/$(lock_value ghostscript artifact.fileName)"
  prepared="$SCRATCH_DIR/ghostscript-stage"
  "$ROOT_DIR/script/build_ghostscript.sh" "$archive" "$prepared" "$(lock_value ghostscript version)"
  replace_stage_dir "$prepared" "$STAGED_DIR/ghostscript"
}

verify_staged() {
  local c2pa c2pa_settings c2pa_smoke c2pa_smoke_status exiftool qpdf gs arches linked gs_linked receipt
  c2pa="$STAGED_DIR/c2patool/c2patool"
  c2pa_settings="$STAGED_DIR/c2patool/offline.toml"
  exiftool="$STAGED_DIR/exiftool/exiftool"
  qpdf="$STAGED_DIR/qpdf/qpdf"
  gs="$STAGED_DIR/ghostscript/gs"
  [[ -x "$c2pa" ]] || die "missing staged c2patool; run $0 build"
  [[ -f "$c2pa_settings" ]] || die "missing staged c2patool offline settings; run $0 build"
  [[ -x "$exiftool" ]] || die "missing staged ExifTool; run $0 build"
  [[ -x "$qpdf" ]] || die "missing staged qpdf; run $0 build"
  [[ -x "$gs" ]] || die "missing staged Ghostscript; run $0 build"
  [[ -x /usr/bin/perl ]] || die "/usr/bin/perl is required by the pinned ExifTool distribution"
  /usr/bin/cmp -s "$ROOT_DIR/App/Resources/c2patool-offline.toml" "$c2pa_settings" || \
    die "staged c2patool settings differ from the reviewed offline policy"
  /usr/bin/cmp -s "$ROOT_DIR/App/Resources/ThirdPartyLicenses/c2pa-rs-LICENSE-MIT.txt" \
    "$STAGED_DIR/c2patool/LICENSE-MIT.txt" || die "staged c2patool license differs from the reviewed resource"
  /usr/bin/cmp -s "$ROOT_DIR/App/Resources/ThirdPartyLicenses/ExifTool-COPYRIGHT-AND-LICENSE.txt" \
    "$STAGED_DIR/exiftool/COPYRIGHT-AND-LICENSE.txt" || die "staged ExifTool copyright notice differs"
  /usr/bin/cmp -s "$ROOT_DIR/App/Resources/ThirdPartyLicenses/ExifTool-LICENSE-Artistic-1.0-Perl.txt" \
    "$STAGED_DIR/exiftool/LICENSE-Artistic-1.0-Perl.txt" || die "staged ExifTool Artistic license differs"
  if /usr/bin/find "$STAGED_DIR/exiftool" -maxdepth 1 \
    \( -iname '*gpl*' -o -name COPYING \) -print | /usr/bin/grep . >/dev/null; then
    die "ExifTool staging must contain only the selected Artistic-1.0-Perl license option"
  fi
  /usr/bin/cmp -s "$ROOT_DIR/App/Resources/ThirdPartyLicenses/qpdf-LICENSE-Apache-2.0.txt" \
    "$STAGED_DIR/qpdf/LICENSE.txt" || die "staged qpdf license differs from the reviewed resource"
  /usr/bin/cmp -s "$ROOT_DIR/App/Resources/ThirdPartyLicenses/qpdf-NOTICE.md" \
    "$STAGED_DIR/qpdf/NOTICE.md" || die "staged qpdf notice differs from the reviewed resource"
  /usr/bin/cmp -s "$ROOT_DIR/App/Resources/ThirdPartyLicenses/libjpeg-turbo-LICENSE.md" \
    "$STAGED_DIR/qpdf/libjpeg-turbo-LICENSE.md" || die "staged libjpeg-turbo license differs"

  arches="$(/usr/bin/lipo -archs "$c2pa")"
  [[ "$arches" == "arm64" ]] || die "staged c2patool is not arm64: $arches"
  arches="$(/usr/bin/lipo -archs "$qpdf")"
  [[ "$arches" == "arm64" ]] || die "staged qpdf is not arm64: $arches"
  "$c2pa" --version | /usr/bin/grep -F "0.27.22" >/dev/null
  /usr/bin/grep -F 'allowed_network_hosts = []' "$c2pa_settings" >/dev/null || \
    die "c2patool offline settings do not block all network hosts"
  /usr/bin/grep -F 'decode_identity_assertions = false' "$c2pa_settings" >/dev/null || \
    die "c2patool offline settings do not disable CAWG identity decoding"
  /usr/bin/grep -F 'remote_manifest_fetch = false' "$c2pa_settings" >/dev/null || \
    die "c2patool offline settings do not disable remote manifests"
  /usr/bin/grep -F 'ocsp_fetch = false' "$c2pa_settings" >/dev/null || \
    die "c2patool offline settings do not disable OCSP fetching"
  c2pa_smoke_status=0
  c2pa_smoke="$(C2PATOOL_SETTINGS="$c2pa_settings" "$c2pa" \
    "$ROOT_DIR/Vendor/watermarks-remover/tests/fixtures/sample_c2pa.avif" 2>&1)" || \
    c2pa_smoke_status=$?
  [[ "$c2pa_smoke_status" -eq 1 && "$c2pa_smoke" == *"No claim found"* ]] || \
    die "c2patool settings/fixture smoke test returned an unexpected result"
  [[ "$("$exiftool" -ver)" == "13.59" ]] || die "unexpected ExifTool version"
  "$qpdf" --version | /usr/bin/grep -F "12.4.1" >/dev/null

  linked="$(/usr/bin/otool -L "$qpdf")"
  if echo "$linked" | /usr/bin/grep -E 'libqpdf|libjpeg|/opt/homebrew|/usr/local' >/dev/null; then
    echo "$linked" >&2
    die "qpdf has a non-relocatable or non-static qpdf/libjpeg dependency"
  fi
  [[ "$("$gs" --version)" == "$(lock_value ghostscript version)" ]] || die "unexpected Ghostscript version"
  [[ "$(/usr/bin/lipo -archs "$gs")" == "arm64" ]] || die "staged Ghostscript is not arm64"
  gs_linked="$(/usr/bin/otool -L "$gs")"
  if printf '%s\n' "$gs_linked" | tail -n +2 | awk '{print $1}' | grep -Ev '^(/usr/lib/|/System/Library/)'; then
    die "Ghostscript has a non-system linked library"
  fi
  "$gs" -h | grep -F 'pdfwrite' >/dev/null || die "Ghostscript pdfwrite device is missing"
  "$gs" -h | grep -F 'Initialization files are compiled into the executable.' >/dev/null || \
    die "Ghostscript resources must be compiled in"
  [[ "$(cat "$STAGED_DIR/ghostscript/SOURCE.sha256")" == "$(lock_value ghostscript artifact.sha256)" ]] || \
    die "Ghostscript source receipt differs from the lock"
  verify_hash "$DOWNLOADS_DIR/$(lock_value ghostscript artifact.fileName)" "$(lock_value ghostscript artifact.sha256)"
  /usr/bin/cmp -s "$ROOT_DIR/App/Resources/ThirdPartyLicenses/Ghostscript-AGPL-3.0.txt" \
    "$STAGED_DIR/ghostscript/AGPL-3.0.txt" || die "Ghostscript AGPL text differs"
  /usr/bin/cmp -s "$ROOT_DIR/App/Resources/ThirdPartyLicenses/Ghostscript-LICENSE.txt" \
    "$STAGED_DIR/ghostscript/LICENSE.txt" || die "Ghostscript license notice differs"

  receipt="$STAGED_DIR/DEPENDENCY_BUILD_RECEIPT.txt"
  {
    echo "Generated: $(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "Host: $(/usr/bin/sw_vers -productVersion) $(/usr/bin/uname -m)"
    echo "Lock SHA-256: $(sha256_of "$LOCK_FILE")"
    echo "c2patool: $("$c2pa" --version)"
    echo "c2patool SHA-256: $(sha256_of "$c2pa")"
    echo "c2patool network policy: all hosts blocked; remote manifests, OCSP, and CAWG identity decoding disabled"
    echo "c2patool settings SHA-256: $(sha256_of "$c2pa_settings")"
    echo "c2patool offline-settings parse smoke: passed"
    echo "ExifTool: $("$exiftool" -ver)"
    echo "ExifTool launcher SHA-256: $(sha256_of "$exiftool")"
    echo "ExifTool selected license: Artistic-1.0-Perl"
    echo "qpdf: $("$qpdf" --version | /usr/bin/head -n 1)"
    echo "qpdf SHA-256: $(sha256_of "$qpdf")"
    echo "qpdf linked libraries:"
    echo "$linked"
    echo "Ghostscript: $("$gs" --version)"
    echo "Ghostscript SHA-256: $(sha256_of "$gs")"
    echo "Ghostscript source SHA-256: $(lock_value ghostscript artifact.sha256)"
    echo "Ghostscript linked libraries:"
    echo "$gs_linked"
    echo "Ghostscript: compiled-in resources; standalone AGPL-3.0-or-later CLI; corresponding source accompanies the DMG"
  } > "$receipt"
  cat "$receipt"
}

case "$MODE" in
  -h|--help|help)
    usage
    exit 0
    ;;
  fetch|build|verify) ;;
  *) usage >&2; exit 2 ;;
esac

[[ -f "$LOCK_FILE" ]] || die "missing $LOCK_FILE"
require_macos_arm64
/bin/mkdir -p "$DOWNLOADS_DIR" "$STAGED_DIR"

if [[ "$MODE" == "fetch" || "$MODE" == "build" ]]; then
  fetch_component c2patool
  fetch_component exiftool
  fetch_component qpdf
  fetch_component libjpegTurbo
  fetch_component ghostscript
fi

if [[ "$MODE" == "fetch" ]]; then
  echo "all locked runtime artifacts are present and verified"
  exit 0
fi

if [[ "$MODE" == "build" ]]; then
  SCRATCH_DIR="$(/usr/bin/mktemp -d "$ARTIFACTS_DIR/work.XXXXXX")"
  trap '/bin/rm -rf -- "$SCRATCH_DIR"' EXIT
  stage_c2patool
  stage_exiftool
  build_qpdf
  build_ghostscript
fi

verify_staged
