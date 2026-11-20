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
LOCK_FILE="$ROOT_DIR/Config/Dependencies.lock.json"
REQUIREMENTS_LOCK="$HELPER_DIR/requirements-build.txt"
ENVIRONMENT_VERIFIER="$ROOT_DIR/script/verify_build_environment.py"
IF_NEEDED=0
FRESH_ENV=0
CHECK_LOCKED_PYTHON_ONLY=0
if [[ "${PROVENANCE_HELPER_FRESH_ENV:-0}" == "1" ]]; then
  FRESH_ENV=1
fi

case "$TARGET_ARCH" in
  arm64|x86_64|universal2)
    ;;
  *)
    echo "build_helper: unsupported PROVENANCE_HELPER_ARCH: $TARGET_ARCH" >&2
    exit 2
    ;;
esac

usage() {
  cat >&2 <<USAGE
usage: $0 [--if-needed] [--fresh-env] [--check-locked-python-only]

  --if-needed    exit early when the helper is newer than its sources and the
                 cached Helper/.venv still verifies against its hash lock
  --fresh-env    build in a new temporary venv installed only from the
                 hash-locked wheels (also PROVENANCE_HELPER_FRESH_ENV=1);
                 Helper/.venv is neither read nor modified. Release builds
                 always use this.
  --check-locked-python-only
                 with PROVENANCE_REQUIRE_LOCKED_PYTHON, stop after the
                 interpreter provenance checks (no venv, no PyInstaller)
USAGE
}

die() {
  echo "build_helper: $*" >&2
  exit 1
}

# Compiled bytecode is not covered by RECORD hashes, so nothing in this build
# reads a pre-existing __pycache__ file: every interpreter run that matters uses
# a fresh pycache prefix inside BUILD_TMP.
verify_build_environment() {
  local environment_python="$1"
  "$environment_python" -I -B -X pycache_prefix="$BUILD_TMP/verify-pycache" \
    "$ENVIRONMENT_VERIFIER" "$REQUIREMENTS_LOCK" || return 1
  "$environment_python" -I -B -X pycache_prefix="$BUILD_TMP/verify-pycache" \
    -m pip --isolated --disable-pip-version-check check || return 1
}

# Every build-time interpreter run that loads PyInstaller (or pip) must import
# only what verify_build_environment checked.  `python -m X` and `python -c`
# put the working directory first on sys.path, and the caller's PYTHONPATH,
# PYTHONHOME or PYTHONSTARTUP would add or override modules, so run_build_python
# starts from an empty directory inside BUILD_TMP, removes every inherited
# PYTHON* variable and sets PYTHONSAFEPATH (inherited by PyInstaller's own
# subprocesses).  Leading NAME=VALUE arguments are passed through env.
run_build_python() {
  local scrub=() loader=() name
  while IFS= read -r name; do
    scrub+=(-u "$name")
  done < <(compgen -e | grep '^PYTHON' || true)
  # /usr/bin/env is SIP-protected, so macOS drops DYLD_* from its environment
  # when it starts; an inherited DYLD_FRAMEWORK_PATH would never reach the
  # interpreter and a staged framework's python would silently load
  # /Library/Frameworks instead.  Hand the loader paths to env as assignments,
  # which env applies after it starts.
  for name in DYLD_FRAMEWORK_PATH DYLD_LIBRARY_PATH; do
    if [[ -n "${!name:-}" ]]; then
      loader+=("$name=${!name}")
    fi
  done
  mkdir -p "$BUILD_TMP/cwd" "$BUILD_TMP/pycache"
  (
    cd "$BUILD_TMP/cwd" &&
      exec env ${scrub[@]+"${scrub[@]}"} ${loader[@]+"${loader[@]}"} \
        PYTHONSAFEPATH=1 \
        PYTHONNOUSERSITE=1 \
        PYTHONHASHSEED=0 \
        PYTHONPYCACHEPREFIX="$BUILD_TMP/pycache" \
        "$@"
  )
}

resolve_path() {
  /bin/realpath "$1" 2>/dev/null
}

# Locked builds: prove the runtime PyInstaller actually sees -- the same
# run_build_python environment and the same -s -P flags, not the -I probes
# above -- is the locked tree.  base_prefix, os.py (the pure stdlib) and the
# lib-dynload extension directory must all resolve
# inside the locked Versions/3.14 tree, and nothing else may precede the stdlib
# on sys.path.  Fails closed.
verify_locked_build_runtime() {
  local build_python="$1" locked_version_dir="$2" report
  # run_build_python changes directory; keep venv symlinks unresolved.
  [[ "$build_python" == /* ]] || build_python="$PWD/$build_python"
  report="$(run_build_python "$build_python" -s -P -B -c '
import os, sys, _ssl
print("base_prefix=" + sys.base_prefix)
print("os=" + os.__file__)
print("dynload=" + os.path.dirname(_ssl.__file__))
for entry in sys.path:
    if not entry:
        continue
    if entry.endswith((".zip", "site-packages")) or os.path.realpath(entry).startswith(os.path.realpath(sys.base_prefix) + os.sep):
        continue
    print("unexpected=" + entry)
')" || die "could not probe the build runtime $build_python"
  local key value resolved
  while IFS='=' read -r key value; do
    [[ -n "$key" ]] || continue
    if [[ "$key" == "unexpected" ]]; then
      die "locked build runtime has an unexpected sys.path entry before PyInstaller: $value"
    fi
    resolved="$(resolve_path "$value")" || die "locked build runtime $key does not exist: $value"
    [[ "$resolved" == "$locked_version_dir" || "$resolved" == "$locked_version_dir/"* ]] || \
      die "locked build runtime loads its $key from $resolved, outside $locked_version_dir"
  done <<<"$report"
  [[ "$report" == *"os="* && "$report" == *"dynload="* ]] || die "incomplete build runtime probe from $build_python"
}

for ARGUMENT in "$@"; do
  case "$ARGUMENT" in
    --if-needed)
      IF_NEEDED=1
      ;;
    --fresh-env)
      FRESH_ENV=1
      ;;
    --check-locked-python-only)
      CHECK_LOCKED_PYTHON_ONLY=1
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done
if [[ "$CHECK_LOCKED_PYTHON_ONLY" -eq 1 && -z "${PROVENANCE_REQUIRE_LOCKED_PYTHON:-}" ]]; then
  die "--check-locked-python-only requires PROVENANCE_REQUIRE_LOCKED_PYTHON"
fi

if [[ ! -f "$SOURCE" || ! -f "$SPEC" || ! -d "$UPSTREAM_DIR" || ! -f "$ENVIRONMENT_VERIFIER" ]]; then
  die "helper source, environment verifier or vendored upstream is missing"
fi

BUILD_TMP="$(mktemp -d "${TMPDIR:-/tmp}/provenance-helper-build.XXXXXX")"
cleanup() {
  rm -rf "$BUILD_TMP"
}
trap cleanup EXIT

if [[ -n "${PROVENANCE_PYTHON:-}" ]]; then
  PYTHON_BIN="$PROVENANCE_PYTHON"
else
  PYTHON_BIN="$(command -v python3 || true)"
fi
if [[ -n "$PYTHON_BIN" && "$PYTHON_BIN" != */* ]]; then
  PYTHON_BIN="$(command -v "$PYTHON_BIN" || true)"
fi
if [[ -z "$PYTHON_BIN" || ! -x "$PYTHON_BIN" ]]; then
  die "set PROVENANCE_PYTHON to an executable Python 3 interpreter"
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

# Release builds (package_release.sh) pin the interpreter to the tree that
# script/stage_locked_python.sh freshly extracted from the SHA-256-locked
# python.org installer.  Every path the loader may use has to resolve inside
# that tree; a version string alone proves nothing about provenance.
LOCKED_PYTHON_ROOT=""
if [[ -n "${PROVENANCE_REQUIRE_LOCKED_PYTHON:-}" ]]; then
  LOCKED_PYTHON_ROOT="$(resolve_path "$PROVENANCE_REQUIRE_LOCKED_PYTHON")" || \
    die "locked Python root does not exist: $PROVENANCE_REQUIRE_LOCKED_PYTHON"
  LOCKED_VERSION_DIR="$LOCKED_PYTHON_ROOT/Python.framework/Versions/3.14"
  LOCKED_PKG_SHA256="$(/usr/bin/plutil -extract components.cpython.artifact.sha256 raw -o - "$LOCK_FILE")" || \
    die "could not read the locked CPython installer hash"
  LOCKED_VERSION="$(/usr/bin/plutil -extract components.cpython.version raw -o - "$LOCK_FILE")" || \
    die "could not read the locked CPython version"
  [[ -f "$LOCKED_PYTHON_ROOT/LOCKED_SOURCE.txt" ]] && \
    /usr/bin/grep -Fxq "sha256=$LOCKED_PKG_SHA256" "$LOCKED_PYTHON_ROOT/LOCKED_SOURCE.txt" || \
    die "$LOCKED_PYTHON_ROOT was not staged from the locked CPython installer; run script/stage_locked_python.sh"
  RESOLVED_PYTHON_BIN="$(resolve_path "$PYTHON_BIN")" || die "could not resolve $PYTHON_BIN"
  [[ "$RESOLVED_PYTHON_BIN" == "$LOCKED_VERSION_DIR/bin/"* ]] || \
    die "release builds use only the interpreter extracted from the locked installer; $PYTHON_BIN resolves to $RESOLVED_PYTHON_BIN, outside $LOCKED_VERSION_DIR/bin"
  [[ -n "${DYLD_FRAMEWORK_PATH:-}" && "$(resolve_path "$DYLD_FRAMEWORK_PATH")" == "$LOCKED_PYTHON_ROOT" ]] || \
    die "DYLD_FRAMEWORK_PATH must be exactly the locked Python root $LOCKED_PYTHON_ROOT (got ${DYLD_FRAMEWORK_PATH:-unset})"
  [[ -n "${DYLD_LIBRARY_PATH:-}" && "$(resolve_path "$DYLD_LIBRARY_PATH")" == "$LOCKED_VERSION_DIR/lib" ]] || \
    die "DYLD_LIBRARY_PATH must be exactly $LOCKED_VERSION_DIR/lib (got ${DYLD_LIBRARY_PATH:-unset})"
  [[ -n "$PYTHON_VERSION_ROOT" && "$(resolve_path "$PYTHON_VERSION_ROOT")" == "$LOCKED_VERSION_DIR" && \
     -f "$PYTHON_VERSION_ROOT/Python" ]] || \
    die "the locked Python framework library is missing under $LOCKED_VERSION_DIR"
fi

if ! REQUESTED_RUNTIME="$("$PYTHON_BIN" -I -B -c 'import platform, sys; print(platform.python_version() + "|" + sys.base_prefix)')"; then
  echo "build_helper: could not run $PYTHON_BIN" >&2
  echo "for a staged Python.framework, export its parent with DYLD_FRAMEWORK_PATH" >&2
  exit 1
fi
EXPECTED_PYTHON_VERSION="${REQUESTED_RUNTIME%%|*}"
if [[ -n "$LOCKED_PYTHON_ROOT" ]]; then
  [[ "$EXPECTED_PYTHON_VERSION" == "$LOCKED_VERSION" ]] || \
    die "locked interpreter reports $EXPECTED_PYTHON_VERSION, expected $LOCKED_VERSION"
  RESOLVED_BASE_PREFIX="$(resolve_path "${REQUESTED_RUNTIME#*|}")" || die "could not resolve sys.base_prefix"
  [[ "$RESOLVED_BASE_PREFIX" == "$LOCKED_VERSION_DIR" ]] || \
    die "locked interpreter loaded the runtime at $RESOLVED_BASE_PREFIX instead of $LOCKED_VERSION_DIR"
  verify_locked_build_runtime "$PYTHON_BIN" "$LOCKED_VERSION_DIR"
  echo "build_helper: interpreter verified inside the locked CPython $LOCKED_VERSION tree $LOCKED_PYTHON_ROOT"
  if [[ "$CHECK_LOCKED_PYTHON_ONLY" -eq 1 ]]; then
    exit 0
  fi
fi

if [[ "$IF_NEEDED" -eq 1 && "$FRESH_ENV" -eq 0 && -z "$LOCKED_PYTHON_ROOT" && -x "$OUTPUT_BINARY" ]]; then
  WATCH_PATHS=(
    "$SOURCE"
    "$HELPER_DIR/word_editing_traces.py"
    "$HELPER_DIR/metadata_editor.py"
    "$HELPER_DIR/credential_inspection.py"
    "$HELPER_DIR/office_credentials.py"
    "$HELPER_DIR/upstream_fixes.py"
    "$HELPER_DIR/pdf_traces.py"
    "$HELPER_DIR/injection_scan.py"
    "$HELPER_DIR/injection_extract.py"
    "$HELPER_DIR/generator_fields.py"
    "$HELPER_DIR/chat_artifacts.py"
    "$HELPER_DIR/zip_guard.py"
    "$HELPER_DIR/report_budget.py"
    "$HELPER_DIR/png_text_limits.py"
    "$SPEC"
    "$UPSTREAM_DIR"
    "$REQUIREMENTS_LOCK"
    "$ROOT_DIR/script/build_helper.sh"
    "$ENVIRONMENT_VERIFIER"
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

if ! EXPECTED_OPENSSL_VERSION="$("$PYTHON_BIN" -I -B -c 'import ssl; print(ssl.OPENSSL_VERSION)')"; then
  die "the selected Python runtime could not import its ssl module"
fi

if [[ "$FRESH_ENV" -eq 1 ]]; then
  # A new venv every time: nothing from Helper/.venv, the user's pip
  # configuration or pip's cache can reach the release build.  ensurepip comes
  # from the selected runtime; every other wheel is checked against its
  # SHA-256 in the requirements lock while pip installs it.
  VENV_DIR="$BUILD_TMP/venv"
  "$PYTHON_BIN" -I -B -m venv "$VENV_DIR"
  VENV_PYTHON="$VENV_DIR/bin/python"
  PIP_CONFIG_FILE=/dev/null \
    "$VENV_PYTHON" -I -B -m pip install --isolated --no-input --disable-pip-version-check \
      --no-cache-dir --require-hashes --only-binary=:all: --no-deps \
      --requirement "$REQUIREMENTS_LOCK"
  echo "build_helper: created a fresh hash-locked build environment in $VENV_DIR"
else
  CACHED_RUNTIME=""
  MARKED_RUNTIME=""
  if [[ -x "$VENV_DIR/bin/python" ]]; then
    CACHED_RUNTIME="$("$VENV_DIR/bin/python" -I -B -c 'import platform, sys; print(platform.python_version() + "|" + sys.base_prefix)' 2>/dev/null || true)"
  fi
  if [[ -f "$VENV_DIR/.provenance-runtime" ]]; then
    MARKED_RUNTIME="$(<"$VENV_DIR/.provenance-runtime")"
  fi
  if [[ -x "$VENV_DIR/bin/python" && ( "$CACHED_RUNTIME" != "$REQUESTED_RUNTIME" || "$MARKED_RUNTIME" != "$REQUESTED_RUNTIME" ) ]]; then
    echo "build_helper: recreating cached venv for runtime $REQUESTED_RUNTIME"
    rm -rf "$VENV_DIR"
  fi
  if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    "$PYTHON_BIN" -I -B -m venv "$VENV_DIR"
  fi
  printf '%s\n' "$REQUESTED_RUNTIME" > "$VENV_DIR/.provenance-runtime"
  VENV_PYTHON="$VENV_DIR/bin/python"

  if ! verify_build_environment "$VENV_PYTHON" >/dev/null 2>&1; then
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
      "$VENV_PYTHON" -I -B -m pip install --no-input --require-hashes \
        --only-binary=:all: --requirement "$REQUIREMENTS_LOCK"
  fi
fi
if ! verify_build_environment "$VENV_PYTHON"; then
  if [[ "$FRESH_ENV" -eq 0 ]]; then
    echo "build_helper: the cached $VENV_DIR differs from its hash lock; delete it or use --fresh-env" >&2
  fi
  exit 1
fi
if [[ -n "${PROVENANCE_BUILD_ENV_REPORT:-}" ]]; then
  {
    echo "# PyInstaller build environment ($([[ "$FRESH_ENV" -eq 1 ]] && echo fresh || echo cached))"
    echo "# runtime: $REQUESTED_RUNTIME"
    echo "# requirements lock sha256: $(/usr/bin/shasum -a 256 "$REQUIREMENTS_LOCK" | /usr/bin/awk '{print $1}')"
    "$VENV_PYTHON" -I -B -m pip --isolated --disable-pip-version-check list --format=freeze
  } > "$PROVENANCE_BUILD_ENV_REPORT"
fi

export PYTHONHASHSEED=0
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-946684800}"

if [[ -n "$LOCKED_PYTHON_ROOT" ]]; then
  verify_locked_build_runtime "$VENV_PYTHON" "$LOCKED_VERSION_DIR"
  echo "build_helper: PyInstaller runtime (scrubbed environment) verified inside $LOCKED_VERSION_DIR"
fi

run_build_python \
  PROVENANCE_BUILD_ROOT="$ROOT_DIR" \
  PROVENANCE_BUILD_TARGET_ARCH="$TARGET_ARCH" \
  "$VENV_PYTHON" -s -P -m PyInstaller \
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
  "$BUILT_APP/Contents/Frameworks/tools/qpdf/qpdf" \
  "$BUILT_APP/Contents/Frameworks/tools/ghostscript/gs"; do
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
printf '%s' "$SMOKE_RESPONSE" | "$VENV_PYTHON" -I -B -c \
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
