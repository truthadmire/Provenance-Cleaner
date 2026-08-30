#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 APP_CONTENTS_PATH" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_CONTENTS="$1"
HELPERS_DIR="$APP_CONTENTS/Helpers"
PACKAGED_HELPER="$ROOT_DIR/Helper/dist/ProvenanceEngine.app"
DEV_LAUNCHER="$ROOT_DIR/Helper/provenance-engine-dev"
EMBEDDED_HELPER="$HELPERS_DIR/ProvenanceEngine.app"
LEGACY_EMBEDDED_HELPER="$HELPERS_DIR/ProvenanceEngine"

mkdir -p "$HELPERS_DIR"
# Remove both the current nested app and the pre-0.1 directory layout from the
# disposable build product. Leaving the legacy tree behind makes codesign walk
# an unsigned base_library.zip and reject the enclosing application.
rm -rf "$EMBEDDED_HELPER" "$LEGACY_EMBEDDED_HELPER"

if [[ -d "$PACKAGED_HELPER" ]]; then
  cp -R "$PACKAGED_HELPER" "$EMBEDDED_HELPER"
elif [[ -x "$DEV_LAUNCHER" ]]; then
  mkdir -p "$EMBEDDED_HELPER/Contents/MacOS" "$EMBEDDED_HELPER/Contents/Resources/upstream"
  cp "$DEV_LAUNCHER" "$EMBEDDED_HELPER/Contents/MacOS/provenance-engine"
  cp "$ROOT_DIR/Helper/provenance_helper.py" "$EMBEDDED_HELPER/Contents/Resources/provenance_helper.py"
  cp -R "$ROOT_DIR/Vendor/watermarks-remover/service/scripts/." "$EMBEDDED_HELPER/Contents/Resources/upstream/"
  /usr/bin/plutil -create xml1 "$EMBEDDED_HELPER/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleIdentifier -string com.provenancecleaner.mac.engine "$EMBEDDED_HELPER/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleExecutable -string provenance-engine "$EMBEDDED_HELPER/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundlePackageType -string APPL "$EMBEDDED_HELPER/Contents/Info.plist"
  /usr/bin/plutil -insert LSBackgroundOnly -bool YES "$EMBEDDED_HELPER/Contents/Info.plist"
else
  echo "warning: no bundled helper is available; run ./script/build_helper.sh" >&2
fi

# Files copied from Documents/iCloud-backed workspaces can carry FinderInfo or
# resource-fork xattrs that make codesign reject the otherwise valid bundle.
# Clear metadata only from the disposable build product, never from sources.
/usr/bin/xattr -cr "$(dirname "$APP_CONTENTS")"
