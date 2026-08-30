#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/Vendor/watermarks-remover"
MANIFEST="$ROOT_DIR/Config/UpstreamWatermarksRemover.manifest.sha256"
DEPENDENCY_LOCK="$ROOT_DIR/Config/Dependencies.lock.json"

die() {
  echo "verify_upstream_snapshot: $*" >&2
  exit 1
}

[[ -d "$VENDOR_DIR" ]] || die "vendored upstream directory is missing"
[[ -f "$MANIFEST" ]] || die "upstream tree manifest is missing"
[[ -f "$DEPENDENCY_LOCK" ]] || die "dependency lock is missing"

expected_manifest_hash="$(/usr/bin/plutil \
  -extract components.watermarksRemover.treeManifestSha256 raw -o - \
  "$DEPENDENCY_LOCK")"
actual_manifest_hash="$(/usr/bin/shasum -a 256 "$MANIFEST" | /usr/bin/awk '{print $1}')"
[[ "$actual_manifest_hash" == "$expected_manifest_hash" ]] || \
  die "manifest hash does not match Config/Dependencies.lock.json"

expected_file_count="$(/usr/bin/plutil \
  -extract components.watermarksRemover.treeFileCount raw -o - \
  "$DEPENDENCY_LOCK")"
actual_file_count="$(/usr/bin/awk '!/^#/ {count++} END {print count + 0}' "$MANIFEST")"
[[ "$actual_file_count" == "$expected_file_count" ]] || \
  die "manifest file count does not match Config/Dependencies.lock.json"

generated_manifest="$(/usr/bin/mktemp /private/tmp/provenance-upstream-manifest.XXXXXX)"
cleanup() {
  /bin/rm -f -- "$generated_manifest"
}
trap cleanup EXIT

while IFS= read -r -d '' file_path; do
  relative_path="${file_path#"$VENDOR_DIR"/}"
  if [[ -x "$file_path" ]]; then
    file_mode=100755
  else
    file_mode=100644
  fi
  file_hash="$(/usr/bin/shasum -a 256 "$file_path" | /usr/bin/awk '{print $1}')"
  printf '%s  %s  %s\n' "$file_mode" "$file_hash" "$relative_path"
done < <(/usr/bin/find "$VENDOR_DIR" \
  \( -type d \( -name .git -o -name .pytest_cache -o -name __pycache__ \) -prune \) -o \
  \( -type f ! -name '*.pyc' ! -name '.DS_Store' -print0 \) | LC_ALL=C /usr/bin/sort -z) \
  > "$generated_manifest"

if ! /usr/bin/diff -u <(/usr/bin/awk '!/^#/' "$MANIFEST") "$generated_manifest"; then
  die "vendored upstream tree differs from the pinned path/mode/SHA-256 manifest"
fi

if /usr/bin/git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if ! /usr/bin/diff -u \
    <(/usr/bin/awk '!/^#/ {line=$0; sub(/^[^ ]+  [^ ]+  /, "", line); print $1 "  " line}' "$MANIFEST") \
    <(
      /usr/bin/git -C "$ROOT_DIR" ls-files --stage -z -- Vendor/watermarks-remover | \
        while IFS= read -r -d '' index_entry; do
          metadata="${index_entry%%$'\t'*}"
          indexed_path="${index_entry#*$'\t'}"
          indexed_mode="${metadata%% *}"
          relative_path="${indexed_path#Vendor/watermarks-remover/}"
          printf '%s  %s\n' "$indexed_mode" "$relative_path"
        done
    ); then
    die "Git index does not contain the complete pinned upstream path/mode set"
  fi
else
  echo "verify_upstream_snapshot: no Git worktree; verified filesystem snapshot only" >&2
fi

echo "verified watermarks-remover commit 3f84d3e3964368b82172112b09ef3e7c02b25749 ($actual_file_count files)"
