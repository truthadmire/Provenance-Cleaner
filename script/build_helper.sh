#!/usr/bin/env bash
set -euo pipefail

TARGET_ARCH="${PROVENANCE_HELPER_ARCH:-arm64}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER_DIR="$ROOT_DIR/Helper"
SOURCE="$HELPER_DIR/provenance_helper.py"
SPEC="$HELPER_DIR/ProvenanceEngine.spec"
UPSTREAM_DIR="$ROOT_DIR/Vendor/watermarks-remover/service/scripts"
STAGED_TOOLS_DIR="$ROOT_DIR/Vendor/Artifacts/staged"
OUTPUT_APP="$HELPER_DIR/dist/ProvenanceEngine.app"
OUTPUT_BINARY="$OUTPUT_APP/Contents/MacOS/provenance-engine"
LEGACY_OUTPUT_DIR="$HELPER_DIR/dist/ProvenanceEngine"
VENV_DIR="$HELPER_DIR/.venv"
IF_NEEDED=0

case "$TARGET_ARCH" in
  arm64|x86_64|universal2)
    ;;
  *)
    echo "build_helper: unsupported PROVENANCE_HELPER_ARCH: $TARGET_ARCH" >&2
    exit 2
    ;;
esac

usage() {
  echo "usage: $0 [--if-needed]" >&2
}

verify_build_environment() {
  local environment_python="$1"
  "$environment_python" -c '
from importlib.metadata import PackageNotFoundError, version
from pathlib import Path
import sys

expected = {}
for raw_line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    line = raw_line.strip()
    if not line or line.startswith(("#", "--")) or "==" not in line:
        continue
    package, wanted = line.rstrip("\\").strip().split("==", 1)
    expected[package.strip()] = wanted.strip()
if not expected:
    print("build_helper: requirements lock contains no pinned packages", file=sys.stderr)
    raise SystemExit(1)
problems = []
for package, wanted in expected.items():
    try:
        actual = version(package)
    except PackageNotFoundError:
        problems.append(f"{package}: missing (expected {wanted})")
    else:
        if actual != wanted:
            problems.append(f"{package}: {actual} (expected {wanted})")
if problems:
    print("build_helper: locked build environment mismatch: " + "; ".join(problems), file=sys.stderr)
    raise SystemExit(1)
print("build_helper: locked PyInstaller environment verified")
' "$HELPER_DIR/requirements-build.txt" || return 1
  "$environment_python" -m pip check || return 1
}

case "${1:-}" in
  "")
    ;;
  --if-needed)
    IF_NEEDED=1
    ;;
  *)
    usage
    exit 2
    ;;
esac
if [[ $# -gt 1 ]]; then
  usage
  exit 2
fi

if [[ ! -f "$SOURCE" || ! -f "$SPEC" || ! -d "$UPSTREAM_DIR" ]]; then
  echo "build_helper: helper source or vendored upstream is missing" >&2
  exit 1
fi

if [[ "$IF_NEEDED" -eq 1 && -x "$OUTPUT_BINARY" ]]; then
  WATCH_PATHS=(
    "$SOURCE"
    "$SPEC"
    "$UPSTREAM_DIR"
    "$HELPER_DIR/requirements-build.txt"
    "$ROOT_DIR/script/build_helper.sh"
  )
  if [[ -d "$STAGED_TOOLS_DIR" ]]; then
    WATCH_PATHS+=("$STAGED_TOOLS_DIR")
  fi
  NEWER_SOURCE="$(find "${WATCH_PATHS[@]}" -type f -newer "$OUTPUT_BINARY" -print -quit)"
  if [[ -z "$NEWER_SOURCE" ]]; then
    if [[ -x "$VENV_DIR/bin/python" ]] && \
      verify_build_environment "$VENV_DIR/bin/python" >/dev/null 2>&1; then
      echo "provenance helper and locked build environment are up to date: $OUTPUT_BINARY"
      exit 0
    fi
    echo "build_helper: cached build environment does not match its hash lock" >&2
  fi
fi

if [[ -n "${PROVENANCE_PYTHON:-}" ]]; then
  PYTHON_BIN="$PROVENANCE_PYTHON"
else
  PYTHON_BIN="$(command -v python3 || true)"
fi
if [[ -n "$PYTHON_BIN" && "$PYTHON_BIN" != */* ]]; then
  PYTHON_BIN="$(command -v "$PYTHON_BIN" || true)"
fi
if [[ -z "$PYTHON_BIN" || ! -x "$PYTHON_BIN" ]]; then
  echo "build_helper: set PROVENANCE_PYTHON to an executable Python 3 interpreter" >&2
  exit 1
fi

# DYLD_* variables are stripped when macOS launches this script through its
# protected /bin/bash.  Re-establish the framework search path inside the
# script, deriving it from an extracted Python.framework when possible.  Keep
# the selected version root independently of whether the caller supplied an
# explicit loader path: it is also the authoritative source for replacing any
# host Python library that PyInstaller discovers through a baked /Library
# install name. The explicit PROVENANCE_ spelling survives that
# protected-process boundary.
PYTHON_FRAMEWORK_ROOT=""
PYTHON_VERSION_ROOT=""
if [[ "$PYTHON_BIN" == */Python.framework/Versions/*/bin/* ]]; then
  PYTHON_FRAMEWORK_ROOT="${PYTHON_BIN%%/Python.framework/Versions/*}"
  PYTHON_VERSION_ROOT="${PYTHON_BIN%/bin/*}"
fi
if [[ -n "${PROVENANCE_DYLD_FRAMEWORK_PATH:-}" ]]; then
  export DYLD_FRAMEWORK_PATH="$PROVENANCE_DYLD_FRAMEWORK_PATH"
elif [[ -n "$PYTHON_FRAMEWORK_ROOT" ]]; then
  if [[ -d "$PYTHON_FRAMEWORK_ROOT/Python.framework" ]]; then
    export DYLD_FRAMEWORK_PATH="$PYTHON_FRAMEWORK_ROOT"
  fi
fi
if [[ -n "${PROVENANCE_DYLD_LIBRARY_PATH:-}" ]]; then
  export DYLD_LIBRARY_PATH="$PROVENANCE_DYLD_LIBRARY_PATH"
elif [[ -n "$PYTHON_VERSION_ROOT" ]]; then
  if [[ -d "$PYTHON_VERSION_ROOT/lib" ]]; then
    export DYLD_LIBRARY_PATH="$PYTHON_VERSION_ROOT/lib"
  fi
fi

if ! REQUESTED_RUNTIME="$("$PYTHON_BIN" -c 'import platform, sys; print(platform.python_version() + "|" + sys.base_prefix)')"; then
  echo "build_helper: could not run $PYTHON_BIN" >&2
  echo "for a staged Python.framework, export its parent with DYLD_FRAMEWORK_PATH" >&2
  exit 1
fi
EXPECTED_PYTHON_VERSION="${REQUESTED_RUNTIME%%|*}"
if ! EXPECTED_OPENSSL_VERSION="$("$PYTHON_BIN" -c 'import ssl; print(ssl.OPENSSL_VERSION)')"; then
  echo "build_helper: the selected Python runtime could not import its ssl module" >&2
  exit 1
fi
CACHED_RUNTIME=""
MARKED_RUNTIME=""
if [[ -x "$VENV_DIR/bin/python" ]]; then
  CACHED_RUNTIME="$("$VENV_DIR/bin/python" -c 'import platform, sys; print(platform.python_version() + "|" + sys.base_prefix)' 2>/dev/null || true)"
fi
if [[ -f "$VENV_DIR/.provenance-runtime" ]]; then
  MARKED_RUNTIME="$(<"$VENV_DIR/.provenance-runtime")"
fi
if [[ -x "$VENV_DIR/bin/python" && ( "$CACHED_RUNTIME" != "$REQUESTED_RUNTIME" || "$MARKED_RUNTIME" != "$REQUESTED_RUNTIME" ) ]]; then
  echo "build_helper: recreating cached venv for runtime $REQUESTED_RUNTIME"
  rm -rf "$VENV_DIR"
fi
if [[ ! -x "$VENV_DIR/bin/python" ]]; then
  "$PYTHON_BIN" -m venv "$VENV_DIR"
fi
printf '%s\n' "$REQUESTED_RUNTIME" > "$VENV_DIR/.provenance-runtime"
VENV_PYTHON="$VENV_DIR/bin/python"

if ! verify_build_environment "$VENV_PYTHON" >/dev/null 2>&1; then
  PIP_DISABLE_PIP_VERSION_CHECK=1 \
    "$VENV_PYTHON" -m pip install --no-input --require-hashes \
      --only-binary=:all: --requirement "$HELPER_DIR/requirements-build.txt"
fi
verify_build_environment "$VENV_PYTHON"

BUILD_TMP="$(mktemp -d "${TMPDIR:-/tmp}/provenance-helper-build.XXXXXX")"
cleanup() {
  rm -rf "$BUILD_TMP"
}
trap cleanup EXIT

export PYTHONHASHSEED=0
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-946684800}"

PROVENANCE_BUILD_ROOT="$ROOT_DIR" \
PROVENANCE_BUILD_TARGET_ARCH="$TARGET_ARCH" \
"$VENV_PYTHON" -m PyInstaller \
  --noconfirm \
  --clean \
  --distpath "$BUILD_TMP/dist" \
  --workpath "$BUILD_TMP/work" \
  "$SPEC"

BUILT_APP="$BUILD_TMP/dist/ProvenanceEngine.app"
BUILT_BINARY="$BUILT_APP/Contents/MacOS/provenance-engine"
if [[ ! -x "$BUILT_BINARY" ]]; then
  echo "build_helper: PyInstaller did not produce $BUILT_BINARY" >&2
  exit 1
fi

replace_macho_runtime() {
  local source_file="$1"
  local destination_file="$2"
  local install_id="$3"
  local staged_file="$BUILD_TMP/runtime-$(basename "$destination_file")"

  if [[ "$TARGET_ARCH" == "universal2" ]]; then
    cp "$source_file" "$staged_file"
  else
    if ! lipo -archs "$source_file" | tr ' ' '\n' | grep -Fxq "$TARGET_ARCH"; then
      echo "build_helper: $source_file does not contain $TARGET_ARCH" >&2
      exit 1
    fi
    lipo "$source_file" -thin "$TARGET_ARCH" -output "$staged_file"
  fi
  chmod 755 "$staged_file"
  install_name_tool -id "$install_id" "$staged_file"
  mv "$staged_file" "$destination_file"
  codesign --force --sign - "$destination_file"
}

# python.org framework executables retain /Library install names even when an
# official package is extracted elsewhere.  PyInstaller therefore discovers
# the older system framework despite analyzing with the requested interpreter.
# Replace that collected library (and its matching OpenSSL/zstd dylibs) from
# the selected extracted runtime, then relocate and re-sign the thin copies.
if [[ -n "${PYTHON_VERSION_ROOT:-}" && -f "$PYTHON_VERSION_ROOT/Python" ]]; then
  BUNDLED_RUNTIME_DIR="$BUILT_APP/Contents/Frameworks"
  BUNDLED_PYTHON="$BUNDLED_RUNTIME_DIR/Python.framework/Versions/$(basename "$PYTHON_VERSION_ROOT")/Python"
  if [[ ! -f "$BUNDLED_PYTHON" ]]; then
    echo "build_helper: packaged Python framework layout was not found" >&2
    exit 1
  fi
  replace_macho_runtime "$PYTHON_VERSION_ROOT/Python" "$BUNDLED_PYTHON" "@rpath/Python"

  for RUNTIME_LIBRARY in libcrypto.3.dylib libssl.3.dylib libzstd.1.dylib; do
    SOURCE_LIBRARY="$PYTHON_VERSION_ROOT/lib/$RUNTIME_LIBRARY"
    BUNDLED_LIBRARY="$BUNDLED_RUNTIME_DIR/$RUNTIME_LIBRARY"
    if [[ -f "$SOURCE_LIBRARY" && -f "$BUNDLED_LIBRARY" ]]; then
      replace_macho_runtime \
        "$SOURCE_LIBRARY" \
        "$BUNDLED_LIBRARY" \
        "@rpath/$RUNTIME_LIBRARY"
    fi
  done

  BUNDLED_SSL="$BUNDLED_RUNTIME_DIR/libssl.3.dylib"
  if [[ -f "$BUNDLED_SSL" ]]; then
    install_name_tool \
      -change "/Library/Frameworks/Python.framework/Versions/$(basename "$PYTHON_VERSION_ROOT")/lib/libcrypto.3.dylib" \
      "@rpath/libcrypto.3.dylib" \
      "$BUNDLED_SSL"
    codesign --force --sign - "$BUNDLED_SSL"
  fi
  echo "build_helper: embedded CPython $EXPECTED_PYTHON_VERSION from $PYTHON_VERSION_ROOT"
fi

EXIFTOOL_BINARY="$BUILT_APP/Contents/Resources/tools/exiftool/exiftool"
if [[ -f "$EXIFTOOL_BINARY" ]]; then
  chmod 755 "$EXIFTOOL_BINARY"
fi

C2PATOOL_BINARY="$BUILT_APP/Contents/Frameworks/tools/c2patool/c2patool"
C2PATOOL_SETTINGS="$BUILT_APP/Contents/Resources/tools/c2patool/offline.toml"
if [[ -x "$C2PATOOL_BINARY" && ! -f "$C2PATOOL_SETTINGS" ]]; then
  echo "build_helper: refusing c2patool without its deny-all offline.toml" >&2
  exit 1
fi

FOUND_TOOL=0
for TOOL_PATH in \
  "$C2PATOOL_BINARY" \
  "$EXIFTOOL_BINARY" \
  "$BUILT_APP/Contents/Frameworks/tools/qpdf/qpdf"; do
  if [[ -x "$TOOL_PATH" ]]; then
    FOUND_TOOL=1
  fi
done
if [[ "$FOUND_TOOL" -eq 0 ]]; then
  echo "build_helper: warning: no staged metadata tools found under $STAGED_TOOLS_DIR" >&2
fi

# Ad-hoc signing keeps the development artifact internally verifiable without
# enabling library validation.  Hardened runtime is applied later, when the
# release script can sign the executable, Python framework, tools, and outer
# bundle with one real Developer ID identity.  An ad-hoc hardened-runtime
# signature has no stable Team ID and macOS rejects the embedded Python dylib.
codesign --force --deep --sign - "$BUILT_APP"
codesign --verify --deep --strict --verbose=2 "$BUILT_APP"

rm -rf "$LEGACY_OUTPUT_DIR" "$OUTPUT_APP"
mkdir -p "$(dirname "$OUTPUT_APP")"
mv "$BUILT_APP" "$OUTPUT_APP"

SMOKE_RESPONSE="$(
  printf '%s\n' '{"requestID":"build-smoke","operation":"capabilities"}' \
    | env -u DYLD_FRAMEWORK_PATH -u DYLD_LIBRARY_PATH -u PYTHONHOME -u PYTHONPATH "$OUTPUT_BINARY"
)"
printf '%s' "$SMOKE_RESPONSE" | "$VENV_PYTHON" -c \
  'import json, sys
r=json.load(sys.stdin)
assert r.get("requestID")=="build-smoke" and r.get("ok") is True and r.get("kind")=="capabilities"
runtime=r["report"]["runtime"]
assert runtime["pythonVersion"]==sys.argv[1], runtime
assert runtime["opensslVersion"]==sys.argv[2], runtime
assert runtime["packaged"] is True, runtime' \
  "$EXPECTED_PYTHON_VERSION" \
  "$EXPECTED_OPENSSL_VERSION"

echo "built provenance helper: $OUTPUT_BINARY"
