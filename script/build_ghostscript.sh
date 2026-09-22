#!/usr/bin/env bash
set -euo pipefail

# Standalone recipe, also included with Ghostscript's corresponding source.
if [[ $# -ne 3 ]]; then
  echo "usage: $0 SOURCE_ARCHIVE OUTPUT_DIRECTORY VERSION" >&2
  exit 2
fi
ARCHIVE="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
DESTINATION="$2"
VERSION="$3"
[[ "$(uname -m)" == "arm64" ]] || { echo "Ghostscript requires an arm64 build host" >&2; exit 1; }
[[ ! -e "$DESTINATION" ]] || { echo "output directory must be new: $DESTINATION" >&2; exit 1; }

BUILD_TEMP="$(mktemp -d /private/tmp/provenance-ghostscript-build.XXXXXX)"
trap 'rm -rf -- "$BUILD_TEMP"' EXIT
tar -xJf "$ARCHIVE" -C "$BUILD_TEMP"
SOURCE_DIR="$BUILD_TEMP/ghostscript-$VERSION"
[[ -f "$SOURCE_DIR/configure" ]] || { echo "unexpected Ghostscript source layout" >&2; exit 1; }
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
BUILD_JOBS="$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)"
[[ "$BUILD_JOBS" -le 8 ]] || BUILD_JOBS=8

(
  cd "$SOURCE_DIR"
  # Use the codecs, fonts, profiles and initialization files in this source
  # archive. No Homebrew libraries, printer services, OCR, GUI, or host fonts.
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  PKG_CONFIG=/usr/bin/false \
  CC="$(xcrun --find clang)" \
  CFLAGS="-O2 -arch arm64 -mmacosx-version-min=14.0 -isysroot $SDK_PATH" \
  LDFLAGS="-arch arm64 -mmacosx-version-min=14.0 -isysroot $SDK_PATH" \
  ./configure \
    --prefix=/nonexistent/provenance-ghostscript \
    --without-x --disable-cups --disable-dbus --disable-gtk \
    --disable-fontconfig --disable-contrib --without-tesseract \
    --without-libpaper --without-ijs --without-pdftoraster \
    --with-libiconv=native --without-libidn \
    --with-fontpath= --with-drivers=pdfwrite,png16m,txtwrite
  /usr/bin/make -j "$BUILD_JOBS"
)

[[ "$("$SOURCE_DIR/bin/gs" --version)" == "$VERSION" ]] || { echo "unexpected Ghostscript version" >&2; exit 1; }
[[ "$(lipo -archs "$SOURCE_DIR/bin/gs")" == "arm64" ]] || { echo "Ghostscript is not arm64" >&2; exit 1; }
if otool -L "$SOURCE_DIR/bin/gs" | tail -n +2 | awk '{print $1}' | grep -Ev '^(/usr/lib/|/System/Library/)' ; then
  echo "Ghostscript must depend only on macOS system libraries" >&2
  exit 1
fi

mkdir -p "$DESTINATION"
install -m 0755 "$SOURCE_DIR/bin/gs" "$DESTINATION/gs"
install -m 0644 "$SOURCE_DIR/LICENSE" "$DESTINATION/LICENSE.txt"
install -m 0644 "$SOURCE_DIR/doc/COPYING" "$DESTINATION/AGPL-3.0.txt"
# Preserve the upstream license collection without adding its 23 MiB manual.
while IFS= read -r -d '' notice; do
  relative="${notice#"$SOURCE_DIR"/}"
  mkdir -p "$DESTINATION/notices/$(dirname "$relative")"
  install -m 0644 "$notice" "$DESTINATION/notices/$relative"
done < <(find "$SOURCE_DIR" -type f \( -iname '*license*' -o -iname '*copying*' -o -iname '*notice*' -o -iname 'copyright*' \) -print0)
for relative in jpeg/README freetype/docs/FTL.TXT freetype/docs/GPLv2.TXT; do
  mkdir -p "$DESTINATION/notices/$(dirname "$relative")"
  install -m 0644 "$SOURCE_DIR/$relative" "$DESTINATION/notices/$relative"
done
shasum -a 256 "$ARCHIVE" | awk '{print $1}' > "$DESTINATION/SOURCE.sha256"
echo "built self-contained Ghostscript $VERSION: $DESTINATION/gs"
