#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Provenance Cleaner"
PROCESS_NAME="ProvenanceCleaner"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Keep disposable build products outside Documents/iCloud Drive. File Provider
# can attach FinderInfo/resource-fork metadata to bundles built in-place, which
# makes macOS codesign reject an otherwise valid debug app.
DERIVED_DIR="${PROVENANCE_DERIVED_DATA_DIR:-/private/tmp/provenance-cleaner-derived}"
PROJECT="$ROOT_DIR/ProvenanceCleaner.xcodeproj"
APP_BUNDLE="$DERIVED_DIR/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$PROCESS_NAME"

pkill -x "$PROCESS_NAME" >/dev/null 2>&1 || true
xcodegen generate --spec "$ROOT_DIR/project.yml" --project "$ROOT_DIR"
xcodebuild \
  -project "$PROJECT" \
  -scheme ProvenanceCleaner \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DIR" \
  build

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$PROCESS_NAME\""
    ;;
  --verify|verify)
    open_app
    for _ in {1..20}; do
      if pgrep -x "$PROCESS_NAME" >/dev/null; then
        exit 0
      fi
      sleep 0.25
    done
    echo "$APP_NAME did not remain running" >&2
    exit 1
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--verify]" >&2
    exit 2
    ;;
esac
