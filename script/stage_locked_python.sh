#!/usr/bin/env bash
# Extract the exact CPython runtime that release builds freeze into the helper.
#
# The interpreter comes only from the python.org installer pinned in
# Config/Dependencies.lock.json (components.cpython.artifact), after its SHA-256
# is checked. It is extracted fresh on every run, so no hand-extracted or
# modified tree (including stray __pycache__ files) can reach a release.
#
# stdout carries only KEY=value lines for the caller:
#   ROOT, PYTHON, FRAMEWORK_PATH, LIBRARY_PATH, PKG_FILE, PKG_SHA256, VERSION
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_FILE="$ROOT_DIR/Config/Dependencies.lock.json"
DOWNLOADS_DIR="$ROOT_DIR/Vendor/Artifacts/downloads"
STAGE_ROOT=""

usage() {
  cat >&2 <<'USAGE'
usage: ./script/stage_locked_python.sh [--lock FILE] [--downloads DIR] [--root DIR]

Verifies the locked python.org CPython installer and extracts its
Python.framework into DIR (default build/locked-python/<installer-sha256>).
USAGE
}

die() {
  echo "stage_locked_python: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lock) [[ $# -ge 2 ]] || { usage; exit 2; }; LOCK_FILE="$2"; shift 2 ;;
    --downloads) [[ $# -ge 2 ]] || { usage; exit 2; }; DOWNLOADS_DIR="$2"; shift 2 ;;
    --root) [[ $# -ge 2 ]] || { usage; exit 2; }; STAGE_ROOT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

[[ -f "$LOCK_FILE" ]] || die "dependency lock not found: $LOCK_FILE"
lock_value() {
  /usr/bin/plutil -extract "components.cpython.$1" raw -o - "$LOCK_FILE" 2>/dev/null || \
    die "dependency lock has no components.cpython.$1"
}
PKG_FILE="$(lock_value artifact.fileName)"
PKG_SHA256="$(lock_value artifact.sha256)"
LOCKED_VERSION="$(lock_value version)"
[[ "$PKG_FILE" != */* && "$PKG_FILE" == *.pkg ]] || die "unexpected locked installer name: $PKG_FILE"
[[ "$PKG_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "locked installer hash is not a SHA-256 digest"
[[ "$LOCKED_VERSION" =~ ^3\.14\.[0-9]+$ ]] || die "this script stages CPython 3.14.x, the lock names $LOCKED_VERSION"

if [[ -z "$STAGE_ROOT" ]]; then
  STAGE_ROOT="$ROOT_DIR/build/locked-python/$PKG_SHA256"
fi
/bin/mkdir -p "$STAGE_ROOT"
STAGE_ROOT="$(cd "$STAGE_ROOT" && pwd -P)"
[[ "$STAGE_ROOT" != "/" ]] || die "refusing to stage into /"

# Remove any earlier staging first, so a failed check below never leaves a
# usable-looking interpreter behind.
/bin/rm -rf -- "$STAGE_ROOT/Python.framework" "$STAGE_ROOT/LOCKED_SOURCE.txt"

PKG_PATH="$DOWNLOADS_DIR/$PKG_FILE"
[[ -f "$PKG_PATH" ]] || die "$PKG_PATH is missing; run script/fetch_dependencies.sh fetch"
ACTUAL_SHA256="$(/usr/bin/shasum -a 256 "$PKG_PATH" | /usr/bin/awk '{print $1}')"
[[ "$ACTUAL_SHA256" == "$PKG_SHA256" ]] || \
  die "SHA-256 mismatch for $PKG_PATH (expected $PKG_SHA256, got $ACTUAL_SHA256); run script/fetch_dependencies.sh fetch"

SCRATCH="$(/usr/bin/mktemp -d "$(dirname "$STAGE_ROOT")/.stage-python.XXXXXX")"
cleanup() {
  /bin/rm -rf -- "$SCRATCH"
}
trap cleanup EXIT

/usr/sbin/pkgutil --expand-full "$PKG_PATH" "$SCRATCH/expanded" >/dev/null
PAYLOAD="$SCRATCH/expanded/Python_Framework.pkg/Payload"
[[ -x "$PAYLOAD/Versions/3.14/bin/python3.14" && -f "$PAYLOAD/Versions/3.14/Python" ]] || \
  die "the locked installer does not contain the expected Python.framework layout"
/bin/mv "$PAYLOAD" "$STAGE_ROOT/Python.framework"

VERSION_DIR="$STAGE_ROOT/Python.framework/Versions/3.14"
PYTHON="$VERSION_DIR/bin/python3"
[[ -x "$PYTHON" ]] || PYTHON="$VERSION_DIR/bin/python3.14"
RUNTIME="$(DYLD_FRAMEWORK_PATH="$STAGE_ROOT" DYLD_LIBRARY_PATH="$VERSION_DIR/lib" \
  "$PYTHON" -I -B -c 'import os, platform, sys; print(platform.python_version() + "|" + os.path.realpath(sys.base_prefix))')" || \
  { /bin/rm -rf -- "$STAGE_ROOT/Python.framework"; die "the extracted interpreter did not run"; }
if [[ "${RUNTIME%%|*}" != "$LOCKED_VERSION" || "${RUNTIME#*|}" != "$VERSION_DIR" ]]; then
  /bin/rm -rf -- "$STAGE_ROOT/Python.framework"
  die "the extracted interpreter reported $RUNTIME, expected $LOCKED_VERSION with base prefix $VERSION_DIR"
fi

{
  echo "file=$PKG_FILE"
  echo "sha256=$PKG_SHA256"
  echo "version=$LOCKED_VERSION"
} > "$STAGE_ROOT/LOCKED_SOURCE.txt"

echo "stage_locked_python: extracted CPython $LOCKED_VERSION from $PKG_FILE ($PKG_SHA256)" >&2
echo "ROOT=$STAGE_ROOT"
echo "PYTHON=$PYTHON"
echo "FRAMEWORK_PATH=$STAGE_ROOT"
echo "LIBRARY_PATH=$VERSION_DIR/lib"
echo "PKG_FILE=$PKG_FILE"
echo "PKG_SHA256=$PKG_SHA256"
echo "VERSION=$LOCKED_VERSION"
