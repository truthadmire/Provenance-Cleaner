"""Release helpers freeze only the CPython extracted from the SHA-256-locked installer."""
from __future__ import annotations

import json
import os
import shlex
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LOCK = ROOT / "Config" / "Dependencies.lock.json"
STAGE_PYTHON = ROOT / "script" / "stage_locked_python.sh"
BUILD_HELPER = ROOT / "script" / "build_helper.sh"
DOWNLOADS = ROOT / "Vendor" / "Artifacts" / "downloads"
PKGUTIL = Path("/usr/sbin/pkgutil")


def locked_pkg() -> Path | None:
    try:
        name = json.loads(LOCK.read_text())["components"]["cpython"]["artifact"]["fileName"]
    except (OSError, KeyError, ValueError):
        return None
    path = DOWNLOADS / name
    return path if path.is_file() else None


def clean_env(**extra: str) -> dict[str, str]:
    env = {key: value for key, value in os.environ.items() if not key.startswith(("PROVENANCE_", "DYLD_"))}
    env.update(extra)
    return env


def parse_keys(stdout: str) -> dict[str, str]:
    return dict(line.split("=", 1) for line in stdout.splitlines() if "=" in line)


class TamperedLockTests(unittest.TestCase):
    def test_hash_mismatch_stops_before_extraction(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            tmp = Path(temporary)
            lock = json.loads(LOCK.read_text())
            lock["components"]["cpython"]["artifact"]["sha256"] = "0" * 64
            tampered = tmp / "Dependencies.lock.json"
            tampered.write_text(json.dumps(lock))
            downloads = tmp / "downloads"
            downloads.mkdir()
            (downloads / lock["components"]["cpython"]["artifact"]["fileName"]).write_bytes(b"not the installer")
            root = tmp / "root"
            (root / "Python.framework").mkdir(parents=True)  # stale staging must not survive
            result = subprocess.run(
                ["/bin/bash", str(STAGE_PYTHON), "--lock", str(tampered), "--downloads", str(downloads), "--root", str(root)],
                capture_output=True,
                text=True,
                env=clean_env(),
                timeout=120,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("SHA-256 mismatch", result.stderr)
            self.assertEqual(result.stdout, "")
            self.assertFalse((root / "Python.framework").exists())
            self.assertFalse((root / "LOCKED_SOURCE.txt").exists())

    def test_missing_installer_names_the_fetch_step(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            tmp = Path(temporary)
            result = subprocess.run(
                ["/bin/bash", str(STAGE_PYTHON), "--downloads", str(tmp / "empty"), "--root", str(tmp / "root")],
                capture_output=True,
                text=True,
                env=clean_env(),
                timeout=120,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("fetch_dependencies.sh fetch", result.stderr)


@unittest.skipUnless(locked_pkg() is not None and PKGUTIL.exists(), "locked CPython installer or pkgutil unavailable")
class StagedLockedPythonTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls._temporary = tempfile.TemporaryDirectory()
        cls.root = Path(cls._temporary.name).resolve() / "locked"
        result = subprocess.run(
            ["/bin/bash", str(STAGE_PYTHON), "--root", str(cls.root)],
            capture_output=True,
            text=True,
            env=clean_env(),
            timeout=600,
        )
        if result.returncode != 0:
            cls._temporary.cleanup()
            raise AssertionError(result.stderr)
        cls.keys = parse_keys(result.stdout)

    @classmethod
    def tearDownClass(cls) -> None:
        cls._temporary.cleanup()

    def run_python(self, code: str) -> str:
        return subprocess.run(
            [self.keys["PYTHON"], "-I", "-B", "-c", code],
            capture_output=True,
            text=True,
            check=True,
            env=clean_env(DYLD_FRAMEWORK_PATH=self.keys["FRAMEWORK_PATH"], DYLD_LIBRARY_PATH=self.keys["LIBRARY_PATH"]),
        ).stdout.strip()

    def build_helper_check(self, **extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/bash", str(BUILD_HELPER), "--check-locked-python-only"],
            capture_output=True,
            text=True,
            env=clean_env(PROVENANCE_REQUIRE_LOCKED_PYTHON=str(self.root), **extra),
            timeout=120,
        )

    def test_staged_interpreter_is_the_locked_runtime(self) -> None:
        lock = json.loads(LOCK.read_text())["components"]["cpython"]
        self.assertEqual(self.keys["PKG_SHA256"], lock["artifact"]["sha256"])
        self.assertEqual(self.run_python("import platform; print(platform.python_version())"), lock["version"])
        base_prefix = Path(self.run_python("import os, sys; print(os.path.realpath(sys.base_prefix))"))
        self.assertIn(self.root, base_prefix.parents)
        self.assertIn(f"sha256={lock['artifact']['sha256']}", (self.root / "LOCKED_SOURCE.txt").read_text())
        self.assertEqual(list((self.root / "Python.framework").rglob("*.pyc")), [])

    def test_build_helper_accepts_the_staged_interpreter(self) -> None:
        result = self.build_helper_check(PROVENANCE_PYTHON=self.keys["PYTHON"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("interpreter verified inside the locked CPython", result.stdout)

    def test_build_helper_rejects_another_interpreter_before_any_venv_work(self) -> None:
        result = self.build_helper_check(PROVENANCE_PYTHON="/usr/bin/python3")
        self.assertEqual(result.returncode, 1)
        self.assertIn("release builds use only the interpreter extracted from the locked installer", result.stderr)
        self.assertNotIn("venv", result.stdout)

    def test_build_helper_rejects_a_foreign_framework_path(self) -> None:
        with tempfile.TemporaryDirectory() as other:
            result = self.build_helper_check(
                PROVENANCE_PYTHON=self.keys["PYTHON"],
                PROVENANCE_DYLD_FRAMEWORK_PATH=other,
            )
        self.assertEqual(result.returncode, 1)
        self.assertIn("DYLD_FRAMEWORK_PATH must be exactly the locked Python root", result.stderr)

    def test_build_helper_rejects_an_unstaged_copy(self) -> None:
        with tempfile.TemporaryDirectory() as other:
            copy = Path(other) / "copy"
            copy.mkdir()
            shutil.copytree(self.root / "Python.framework", copy / "Python.framework", symlinks=True)
            result = subprocess.run(
                ["/bin/bash", str(BUILD_HELPER), "--check-locked-python-only"],
                capture_output=True,
                text=True,
                env=clean_env(
                    PROVENANCE_REQUIRE_LOCKED_PYTHON=str(copy),
                    PROVENANCE_PYTHON=str(copy / "Python.framework/Versions/3.14/bin/python3"),
                ),
                timeout=120,
            )
        self.assertEqual(result.returncode, 1)
        self.assertIn("was not staged from the locked CPython installer", result.stderr)

    # --- the runtime PyInstaller sees (scrubbed env, -s -P, no -I) ---------

    def hostile_python_env(self, scratch: Path) -> dict[str, str]:
        shadow = scratch / "shadow"
        shadow.mkdir(exist_ok=True)
        for name in ("os.py", "csv.py", "json.py"):
            (shadow / name).write_text("raise SystemExit('INJECTED stdlib')\n")
        home = Path("/Library/Frameworks/Python.framework/Versions/3.14")
        return {
            "PYTHONHOME": str(home if home.is_dir() else shadow),
            "PYTHONPATH": str(shadow),
            "PYTHONSTARTUP": str(shadow / "csv.py"),
            "PYTHONUSERBASE": str(shadow),
        }

    def run_probe(self, build_python: Path, locked_dir: Path, scratch: Path, **extra: str) -> subprocess.CompletedProcess[str]:
        script = "\n".join(
            [
                "set -euo pipefail",
                'die() { echo "build_helper: $*" >&2; exit 1; }',
                f"BUILD_TMP={shlex.quote(str(scratch / 'build-tmp'))}",
                'mkdir -p "$BUILD_TMP"',
                shell_function("resolve_path"),
                shell_function("run_build_python"),
                shell_function("verify_locked_build_runtime"),
                'export DYLD_FRAMEWORK_PATH="$LOCKED_FW" DYLD_LIBRARY_PATH="$LOCKED_LIB"',
                'verify_locked_build_runtime "$BUILD_PYTHON" "$LOCKED_DIR"',
                'run_build_python "$BUILD_PYTHON" -s -P -B -c "import os, sys; print(os.environ.get(\'DYLD_FRAMEWORK_PATH\', \'\')); print(sys.base_prefix)"',
            ]
        )
        env = clean_env(
            LOCKED_FW=self.keys["FRAMEWORK_PATH"],
            LOCKED_LIB=self.keys["LIBRARY_PATH"],
            BUILD_PYTHON=str(build_python),
            LOCKED_DIR=str(locked_dir),
            **extra,
        )
        # /bin/bash is SIP-protected and drops DYLD_*; the script re-exports them,
        # exactly as build_helper.sh does.
        return subprocess.run(["/bin/bash", "-c", script], capture_output=True, text=True, env=env, timeout=120)

    def make_venv(self, scratch: Path) -> Path:
        venv = scratch / "venv"
        subprocess.run(
            [self.keys["PYTHON"], "-I", "-B", "-m", "venv", "--without-pip", str(venv)],
            check=True,
            env=clean_env(DYLD_FRAMEWORK_PATH=self.keys["FRAMEWORK_PATH"], DYLD_LIBRARY_PATH=self.keys["LIBRARY_PATH"]),
            timeout=120,
        )
        return venv / "bin" / "python"

    def test_pyinstaller_runtime_stays_locked_despite_python_variables(self) -> None:
        locked_dir = (self.root / "Python.framework/Versions/3.14").resolve()
        with tempfile.TemporaryDirectory() as temporary:
            scratch = Path(temporary).resolve()
            venv_python = self.make_venv(scratch)
            result = self.run_probe(venv_python, locked_dir, scratch, **self.hostile_python_env(scratch))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("INJECTED", result.stdout + result.stderr)
        forwarded, base_prefix = result.stdout.strip().splitlines()[-2:]
        # The SIP-protected /usr/bin/env would drop DYLD_*; the wrapper must re-pass it.
        self.assertEqual(Path(forwarded).resolve(), self.root.resolve())
        self.assertEqual(Path(base_prefix).resolve(), locked_dir)

    def test_runtime_probe_fails_closed_outside_the_locked_tree(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            scratch = Path(temporary).resolve()
            venv_python = self.make_venv(scratch)
            elsewhere = scratch / "elsewhere"
            elsewhere.mkdir()
            result = self.run_probe(venv_python, elsewhere, scratch)
        self.assertEqual(result.returncode, 1)
        self.assertIn("outside", result.stderr)

    def test_build_helper_check_ignores_inherited_python_variables(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            result = self.build_helper_check(
                PROVENANCE_PYTHON=self.keys["PYTHON"], **self.hostile_python_env(Path(temporary))
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("INJECTED", result.stdout + result.stderr)


def shell_function(name: str) -> str:
    text = BUILD_HELPER.read_text()
    start = text.index(f"{name}() {{")
    end = text.index("\n}\n", start) + 3
    return text[start:end]


class ReleaseScriptEnvironmentTests(unittest.TestCase):
    def test_build_helper_verifies_the_pyinstaller_runtime_in_locked_mode(self) -> None:
        text = BUILD_HELPER.read_text()
        pyinstaller = text.index("-m PyInstaller")
        probe = text.rindex('verify_locked_build_runtime "$VENV_PYTHON" "$LOCKED_VERSION_DIR"', 0, pyinstaller)
        self.assertLess(probe, pyinstaller)
        self.assertIn('verify_locked_build_runtime "$PYTHON_BIN" "$LOCKED_VERSION_DIR"', text)

    def test_package_release_drops_inherited_python_variables(self) -> None:
        text = (ROOT / "script" / "package_release.sh").read_text()
        scrub = text.index("compgen -e | /usr/bin/grep '^PYTHON'")
        self.assertIn('unset "$inherited_python_variable"', text)
        self.assertLess(scrub, text.index('"$ROOT_DIR/script/build_helper.sh" --fresh-env'))
        self.assertLess(scrub, text.index("-m unittest discover"))
        self.assertIn('"$HELPER_PYTHON" -s -P -m unittest discover', text)


if __name__ == "__main__":
    unittest.main()
