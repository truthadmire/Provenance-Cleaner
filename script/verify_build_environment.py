"""Verify that a PyInstaller build environment matches Helper/requirements-build.txt.

Run it with the environment's own interpreter in isolated mode:

    <venv>/bin/python -I -B script/verify_build_environment.py Helper/requirements-build.txt

The pip hash lock is enforced by pip only while it downloads and installs.  This
check covers an environment that already exists, so a reused or tampered venv
fails closed instead of being trusted because six version strings still match:

* the interpreter is a venv that does not see the system site-packages;
* every locked distribution is installed exactly once at its locked version;
* no other distribution is installed, except the pip that this runtime's
  ensurepip bundles (venv bootstrap);
* every file a distribution's RECORD lists exists and matches its recorded
  SHA-256 and size (entries recorded without a hash, such as RECORD itself and
  compiled bytecode, are skipped);
* every file in site-packages, apart from compiled bytecode inside a
  ``__pycache__`` directory, belongs to some RECORD, so an injected module,
  ``*.pth`` file, ``sitecustomize`` or PyInstaller entry-point hook package
  cannot ride along;
* a sourceless ``.pyc``/``.pyo`` outside ``__pycache__`` (which the import
  system loads directly, and which can shadow a recorded ``.py``) fails unless
  RECORD lists it with a hash;
* no symbolic link exists anywhere in site-packages: a linked directory or file
  would bring in content that RECORD never describes;
* no ``sitecustomize`` or ``usercustomize`` module is importable at all.

Compiled bytecode in ``__pycache__`` cannot be verified from RECORD;
build_helper.sh therefore runs PyInstaller with a fresh PYTHONPYCACHEPREFIX so
no existing ``__pycache__`` file is read.  The same script also runs PyInstaller
from an empty working directory with PYTHONSAFEPATH set and every inherited
PYTHON* variable removed, so nothing outside the checked site-packages is on
its import path.
"""
from __future__ import annotations

import base64
import csv
import hashlib
import importlib.metadata
import importlib.util
import os
import re
import sys
import sysconfig
from pathlib import Path

PREFIX = "build_helper: locked build environment mismatch: "
BOOTSTRAP_DISTRIBUTION = "pip"


def normalize(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def parse_lock(path: Path) -> dict[str, str]:
    expected: dict[str, str] = {}
    logical = ""
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if line.startswith("#"):
            line = ""
        if line.endswith("\\"):
            logical += line[:-1] + " "
            continue
        logical += line
        entry, logical = logical.strip(), ""
        if not entry or entry.startswith("--"):
            continue
        requirement = entry.split()[0]
        if "==" not in requirement:
            raise SystemExit(PREFIX + f"lock entry is not pinned with ==: {requirement}")
        if "--hash=sha256:" not in entry:
            raise SystemExit(PREFIX + f"lock entry has no sha256 hash: {requirement}")
        name, version = requirement.split("==", 1)
        key = normalize(name)
        if key in expected:
            raise SystemExit(PREFIX + f"lock lists {name} twice")
        expected[key] = version.strip()
    if not expected:
        raise SystemExit("build_helper: requirements lock contains no pinned packages")
    return expected


def bundled_pip_version() -> str | None:
    try:
        import ensurepip
    except ImportError:
        return None
    try:
        return ensurepip.version()
    except Exception:  # pragma: no cover - defensive: a broken ensurepip allows no pip
        return None


def record_digest(path: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
            size += len(chunk)
    return base64.urlsafe_b64encode(digest.digest()).rstrip(b"=").decode("ascii"), size


def site_directories() -> list[Path]:
    seen: list[Path] = []
    for key in ("purelib", "platlib"):
        directory = Path(sysconfig.get_path(key)).resolve()
        if directory not in seen:
            seen.append(directory)
    return seen


def is_cached_bytecode(relative: Path) -> bool:
    """Bytecode the import system only reads as a cache for a sibling source.

    Only files inside a ``__pycache__`` directory qualify; a ``.pyc`` placed
    next to (or instead of) a ``.py`` is loaded as a sourceless module.
    """
    return relative.suffix in {".pyc", ".pyo"} and "__pycache__" in relative.parts[:-1]


def verify(lock_path: Path) -> list[str]:
    problems: list[str] = []
    expected = parse_lock(lock_path)

    if sys.prefix == sys.base_prefix:
        problems.append("interpreter is not a virtual environment")
    config = Path(sys.prefix) / "pyvenv.cfg"
    if config.is_file():
        for line in config.read_text(encoding="utf-8").splitlines():
            key, _, value = line.partition("=")
            if key.strip().lower() == "include-system-site-packages" and value.strip().lower() != "false":
                problems.append("pyvenv.cfg enables system site-packages")
    else:
        problems.append("pyvenv.cfg is missing")

    sites = site_directories()
    venv_root = Path(sys.prefix).resolve()
    for site in sites:
        if venv_root not in site.parents:
            problems.append(f"site-packages is outside the venv: {site}")
    for entry in sys.path:
        if not entry:
            continue
        resolved = Path(entry).resolve()
        if resolved.name in {"site-packages", "dist-packages"} and resolved not in sites:
            problems.append(f"unexpected site directory on sys.path: {resolved}")

    for hook in ("sitecustomize", "usercustomize"):
        spec = importlib.util.find_spec(hook)
        if spec is not None:
            problems.append(f"{hook} is importable from {spec.origin}")

    allowed = dict(expected)
    pip_version = bundled_pip_version()
    seen: dict[str, str] = {}
    recorded: set[Path] = set()
    recorded_with_hash: set[Path] = set()
    checked_files = 0
    for distribution in importlib.metadata.distributions(path=[str(site) for site in sites]):
        raw_name = distribution.metadata["Name"] or "<unnamed>"
        name = normalize(raw_name)
        version = distribution.version
        if name in seen:
            problems.append(f"{raw_name}: installed more than once ({seen[name]} and {version})")
            continue
        seen[name] = version
        if name == BOOTSTRAP_DISTRIBUTION and name not in allowed:
            if pip_version is None or version != pip_version:
                problems.append(f"pip: {version} (expected the ensurepip-bundled {pip_version})")
        elif name not in allowed:
            problems.append(f"{raw_name} {version}: not in the hash lock")
            continue
        elif version != allowed[name]:
            problems.append(f"{raw_name}: {version} (expected {allowed[name]})")

        # Parse RECORD directly: importlib.metadata's files() silently drops
        # entries whose file no longer exists, which would hide a deletion.
        record_text = distribution.read_text("RECORD")
        if record_text is None:
            problems.append(f"{raw_name}: RECORD is missing")
            continue
        for row in csv.reader(record_text.splitlines()):
            if not row:
                continue
            if len(row) != 3:
                problems.append(f"{raw_name}: malformed RECORD row {row!r}")
                continue
            entry, hash_field, size_field = row
            located = Path(distribution.locate_file(entry)).resolve()
            recorded.add(located)
            if not hash_field:
                continue
            recorded_with_hash.add(located)
            if not located.is_file():
                problems.append(f"{raw_name}: recorded file is missing: {entry}")
                continue
            mode, _, expected_digest = hash_field.partition("=")
            if mode != "sha256" or not expected_digest:
                problems.append(f"{raw_name}: unsupported RECORD hash {mode} for {entry}")
                continue
            actual, size = record_digest(located)
            checked_files += 1
            if actual != expected_digest:
                problems.append(f"{raw_name}: RECORD sha256 mismatch for {entry}")
            elif size_field and size_field != str(size):
                problems.append(f"{raw_name}: RECORD size mismatch for {entry}")

    for name, version in expected.items():
        if name not in seen:
            problems.append(f"{name}: missing (expected {version})")

    for site in sites:
        # os.walk does not descend into symlinked directories, so links are
        # reported here instead of being silently skipped.
        for directory, dir_names, names in os.walk(site, followlinks=False):
            current = Path(directory)
            for entry_name in list(dir_names) + list(names):
                entry_path = current / entry_name
                if entry_path.is_symlink():
                    problems.append(
                        f"symbolic link in site-packages: {entry_path.relative_to(site)} -> "
                        f"{os.readlink(entry_path)}"
                    )
            dir_names[:] = [name for name in dir_names if not (current / name).is_symlink()]
            for file_name in names:
                unresolved = current / file_name
                if unresolved.is_symlink():
                    continue
                relative = unresolved.relative_to(site)
                path = unresolved.resolve()
                if is_cached_bytecode(relative):
                    continue
                if path.suffix in {".pyc", ".pyo"}:
                    if path not in recorded_with_hash:
                        problems.append(f"unrecorded sourceless bytecode outside __pycache__: {relative}")
                    continue
                if path in recorded:
                    continue
                if path.suffix == ".pth":
                    problems.append(f"unrecorded .pth file: {relative}")
                else:
                    problems.append(f"file not owned by any locked distribution: {relative}")

    if not problems:
        print(
            "build_helper: locked PyInstaller environment verified "
            f"({len(seen)} distributions, {checked_files} recorded files hash-checked)"
        )
    return problems


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: python -I verify_build_environment.py REQUIREMENTS_LOCK", file=sys.stderr)
        return 2
    problems = verify(Path(argv[1]))
    if problems:
        print(PREFIX + "; ".join(problems), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
