"""The PyInstaller build environment is verified file by file, and releases build it fresh.

script/verify_build_environment.py runs inside a throwaway venv here. The venv
holds a tiny wheel built in the test (no network), installed the way pip does it:
unpacked, with a RECORD of SHA-256 digests.
"""
from __future__ import annotations

import base64
import hashlib
import os
import re
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VERIFIER = ROOT / "script" / "verify_build_environment.py"
BUILD_HELPER = ROOT / "script" / "build_helper.sh"
PACKAGE_RELEASE = ROOT / "script" / "package_release.sh"
STAGE_PYTHON = ROOT / "script" / "stage_locked_python.sh"


def record_hash(data: bytes) -> str:
    return "sha256=" + base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()


def build_wheel(directory: Path, name: str, version: str) -> Path:
    module = name.replace("-", "_")
    dist_info = f"{module}-{version}.dist-info"
    files = {
        f"{module}/__init__.py": f"VALUE = {version!r}\n".encode(),
        f"{dist_info}/METADATA": f"Metadata-Version: 2.1\nName: {name}\nVersion: {version}\n".encode(),
        f"{dist_info}/WHEEL": b"Wheel-Version: 1.0\nGenerator: test\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
    }
    record_lines = [f"{path},{record_hash(data)},{len(data)}" for path, data in files.items()]
    record_lines.append(f"{dist_info}/RECORD,,")
    files[f"{dist_info}/RECORD"] = ("\n".join(record_lines) + "\n").encode()
    wheel = directory / f"{module}-{version}-py3-none-any.whl"
    with zipfile.ZipFile(wheel, "w") as archive:
        for path, data in files.items():
            archive.writestr(path, data)
    return wheel


def install_wheel(wheel: Path, site_packages: Path) -> None:
    """Install like pip: unpack, add INSTALLER and rewrite RECORD with every file's hash."""

    with zipfile.ZipFile(wheel) as archive:
        archive.extractall(site_packages)
        names = archive.namelist()
    dist_info = next(name.split("/")[0] for name in names if name.split("/")[0].endswith(".dist-info"))
    installer = site_packages / dist_info / "INSTALLER"
    installer.write_text("pip\n")
    rows = []
    for name in [*names, f"{dist_info}/INSTALLER"]:
        if name.endswith("/RECORD"):
            continue
        data = (site_packages / name).read_bytes()
        rows.append(f"{name},{record_hash(data)},{len(data)}")
    rows.append(f"{dist_info}/RECORD,,")
    (site_packages / dist_info / "RECORD").write_text("\n".join(rows) + "\n")


def lock_text(entries: list[tuple[str, str, Path]]) -> str:
    lines = ["# test lock"]
    for name, version, wheel in entries:
        digest = hashlib.sha256(wheel.read_bytes()).hexdigest()
        lines.append(f"{name}=={version} \\\n    --hash=sha256:{digest}")
    return "\n".join(lines) + "\n"


class VerifyBuildEnvironmentTests(unittest.TestCase):
    def setUp(self) -> None:
        self._temporary = tempfile.TemporaryDirectory()
        self.tmp = Path(self._temporary.name)
        self.venv = self.tmp / "venv"
        subprocess.run([sys.executable, "-m", "venv", "--without-pip", str(self.venv)], check=True)
        self.python = self.venv / "bin" / "python"
        self.site = Path(
            subprocess.run(
                [str(self.python), "-I", "-c", "import sysconfig; print(sysconfig.get_path('purelib'))"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
        )
        self.wheel = build_wheel(self.tmp, "demo-pkg", "1.0")
        install_wheel(self.wheel, self.site)
        self.lock = self.tmp / "requirements-build.txt"
        self.lock.write_text(lock_text([("demo-pkg", "1.0", self.wheel)]))

    def tearDown(self) -> None:
        self._temporary.cleanup()

    def verify(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(self.python), "-I", "-B", str(VERIFIER), str(self.lock)],
            capture_output=True,
            text=True,
            timeout=120,
        )

    def assert_mismatch(self, fragment: str) -> None:
        result = self.verify()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("locked build environment mismatch", result.stderr)
        self.assertIn(fragment, result.stderr)

    def test_clean_environment_passes(self) -> None:
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("locked PyInstaller environment verified", result.stdout)

    def test_changed_byte_in_installed_file_fails(self) -> None:
        module = self.site / "demo_pkg" / "__init__.py"
        data = bytearray(module.read_bytes())
        data[0] ^= 0x01
        module.write_bytes(bytes(data))
        self.assert_mismatch("RECORD sha256 mismatch for demo_pkg/__init__.py")

    def test_missing_recorded_file_fails(self) -> None:
        (self.site / "demo_pkg" / "__init__.py").unlink()
        self.assert_mismatch("recorded file is missing: demo_pkg/__init__.py")

    def test_extra_unlocked_distribution_fails(self) -> None:
        install_wheel(build_wheel(self.tmp, "extra-hook", "0.1"), self.site)
        self.assert_mismatch("extra-hook 0.1: not in the hash lock")

    def test_injected_pth_file_fails(self) -> None:
        (self.site / "zz-inject.pth").write_text("import os\n")
        self.assert_mismatch("unrecorded .pth file: zz-inject.pth")

    def test_injected_sitecustomize_fails(self) -> None:
        (self.site / "sitecustomize.py").write_text("")
        result = self.verify()
        self.assertEqual(result.returncode, 1)
        self.assertIn("sitecustomize is importable", result.stderr)

    def test_unrecorded_module_inside_package_fails(self) -> None:
        (self.site / "demo_pkg" / "planted.py").write_text("")
        self.assert_mismatch("file not owned by any locked distribution: demo_pkg/planted.py")

    def test_stale_bytecode_is_ignored_not_trusted(self) -> None:
        cache = self.site / "demo_pkg" / "__pycache__"
        cache.mkdir()
        (cache / "__init__.cpython-314.pyc").write_bytes(b"not verified by RECORD")
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        # build_helper.sh never reads pre-existing bytecode: PyInstaller runs
        # with a fresh pycache prefix.
        self.assertIn('PYTHONPYCACHEPREFIX="$BUILD_TMP/pycache"', BUILD_HELPER.read_text())

    def test_sourceless_bytecode_outside_pycache_fails(self) -> None:
        # A bytecode-only package is importable and is not cached bytecode, so
        # it must not be skipped like __pycache__ files are.
        package = self.site / "evilpkg"
        package.mkdir()
        source = self.tmp / "evil_source.py"
        source.write_text("print('EVIL')\n")
        import py_compile

        py_compile.compile(str(source), cfile=str(package / "__init__.pyc"), doraise=True)
        self.assert_mismatch("unrecorded sourceless bytecode outside __pycache__: evilpkg/__init__.pyc")

    def test_sourceless_bytecode_shadowing_recorded_module_fails(self) -> None:
        (self.site / "demo_pkg" / "__init__.pyc").write_bytes(b"shadow")
        self.assert_mismatch("unrecorded sourceless bytecode outside __pycache__: demo_pkg/__init__.pyc")

    def test_symlinked_directory_fails(self) -> None:
        outside = self.tmp / "outside"
        outside.mkdir()
        (outside / "__init__.py").write_text("value = 1\n")
        (self.site / "linkedpkg").symlink_to(outside, target_is_directory=True)
        self.assert_mismatch("symbolic link in site-packages: linkedpkg")

    def test_symlinked_file_fails_even_when_it_points_at_a_recorded_file(self) -> None:
        (self.site / "alias.py").symlink_to(self.site / "demo_pkg" / "__init__.py")
        self.assert_mismatch("symbolic link in site-packages: alias.py")

    def test_version_mismatch_fails(self) -> None:
        self.lock.write_text(lock_text([("demo-pkg", "2.0", self.wheel)]))
        self.assert_mismatch("demo-pkg: 1.0 (expected 2.0)")

    def test_missing_locked_package_fails(self) -> None:
        other = build_wheel(self.tmp, "absent-pkg", "3.0")
        self.lock.write_text(lock_text([("demo-pkg", "1.0", self.wheel), ("absent-pkg", "3.0", other)]))
        self.assert_mismatch("absent-pkg: missing (expected 3.0)")

    def test_unhashed_lock_entry_is_rejected(self) -> None:
        self.lock.write_text("demo-pkg==1.0\n")
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no sha256 hash", result.stderr + result.stdout)


def run_build_python_function() -> str:
    text = BUILD_HELPER.read_text()
    start = text.index("run_build_python() {")
    end = text.index("\n}\n", start) + 3
    return text[start:end]


class BuildInterpreterIsolationTests(unittest.TestCase):
    """PyInstaller must not import code from the caller's cwd or PYTHONPATH."""

    def setUp(self) -> None:
        self._temporary = tempfile.TemporaryDirectory()
        self.tmp = Path(self._temporary.name)
        self.venv = self.tmp / "venv"
        subprocess.run([sys.executable, "-m", "venv", "--without-pip", str(self.venv)], check=True)
        self.caller_cwd = self.tmp / "caller"
        self.caller_cwd.mkdir()
        source = self.tmp / "planted.py"
        source.write_text("print('INJECTED PyInstaller')\n")
        import py_compile

        # .gitignore lists *.pyc, so a planted repo-root PyInstaller.pyc passes
        # the release clean-tree gate; it must still never be imported.
        py_compile.compile(str(source), cfile=str(self.caller_cwd / "PyInstaller.pyc"), doraise=True)
        self.pythonpath = self.tmp / "pythonpath"
        (self.pythonpath / "PyInstaller").mkdir(parents=True)
        (self.pythonpath / "PyInstaller" / "__main__.py").write_text("print('INJECTED via PYTHONPATH')\n")
        (self.pythonpath / "PyInstaller" / "__init__.py").write_text("")
        self.build_tmp = self.tmp / "build"
        self.build_tmp.mkdir()

    def tearDown(self) -> None:
        self._temporary.cleanup()

    def run_script(self, body: str) -> subprocess.CompletedProcess[str]:
        script = "set -euo pipefail\n" + run_build_python_function() + body
        env = dict(os.environ)
        env.update(
            BUILD_TMP=str(self.build_tmp),
            PYTHONPATH=str(self.pythonpath),
            PYTHONSTARTUP=str(self.pythonpath / "PyInstaller" / "__main__.py"),
            PYTHONSAFEPATH="",
        )
        return subprocess.run(
            ["/bin/bash", "-c", script],
            cwd=self.caller_cwd,
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
        )

    def test_planted_modules_shadow_without_the_wrapper(self) -> None:
        # Control: the plain invocation really is exposed to both channels.
        python = self.venv / "bin" / "python"
        result = self.run_script(f'"{python}" -B -m PyInstaller\n')
        self.assertIn("INJECTED", result.stdout)

    def test_wrapper_ignores_cwd_and_pythonpath(self) -> None:
        python = self.venv / "bin" / "python"
        result = self.run_script(f'run_build_python PROBE=1 "{python}" -s -P -m PyInstaller || true\n')
        self.assertNotIn("INJECTED", result.stdout + result.stderr)
        self.assertIn("No module named PyInstaller", result.stderr)

    def test_wrapper_scrubs_python_variables_and_keeps_build_settings(self) -> None:
        python = self.venv / "bin" / "python"
        probe = (
            "import json, os, sys; print(json.dumps({"
            "'env': {k: v for k, v in os.environ.items() if k.startswith(('PYTHON', 'PROBE'))},"
            "'cwd': os.getcwd(), 'path0': sys.path[0]}))"
        )
        result = self.run_script(f"run_build_python PROBE=1 \"{python}\" -c \"{probe}\"\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        import json

        report = json.loads(result.stdout)
        self.assertEqual(
            report["env"],
            {
                "PYTHONSAFEPATH": "1",
                "PYTHONNOUSERSITE": "1",
                "PYTHONHASHSEED": "0",
                "PYTHONPYCACHEPREFIX": str(self.build_tmp / "pycache"),
                "PROBE": "1",
            },
        )
        self.assertEqual(Path(report["cwd"]).resolve(), (self.build_tmp / "cwd").resolve())
        self.assertNotEqual(Path(report["path0"]).resolve(), self.caller_cwd.resolve())

    def test_pyinstaller_runs_through_the_wrapper(self) -> None:
        text = BUILD_HELPER.read_text()
        invocations = [line for line in text.splitlines() if "-m PyInstaller" in line]
        self.assertEqual(len(invocations), 1, invocations)
        self.assertIn("-s -P -m PyInstaller", invocations[0])
        before = text[: text.index(invocations[0])]
        self.assertTrue(before.rstrip().splitlines()[-3].strip().startswith("run_build_python"))
        # Other venv interpreter runs are isolated too.
        for line in text.splitlines():
            if re.search(r'"\$(VENV_PYTHON|PYTHON_BIN|VENV_DIR/bin/python)" -(m|c) ', line):
                self.fail(f"interpreter run without -I: {line.strip()}")


class ReleaseScriptWiringTests(unittest.TestCase):
    def test_scripts_parse(self) -> None:
        for script in (BUILD_HELPER, PACKAGE_RELEASE, STAGE_PYTHON):
            result = subprocess.run(["/bin/bash", "-n", str(script)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, f"{script.name}: {result.stderr}")

    def test_release_builds_the_helper_in_a_fresh_environment(self) -> None:
        text = PACKAGE_RELEASE.read_text()
        invocations = re.findall(r'^\s*"\$ROOT_DIR/script/build_helper\.sh"[^\n]*', text, re.MULTILINE)
        self.assertTrue(invocations)
        for invocation in invocations:
            self.assertIn("--fresh-env", invocation)

    def test_fresh_environment_install_is_isolated_and_hash_locked(self) -> None:
        text = BUILD_HELPER.read_text()
        fresh = text[text.index('if [[ "$FRESH_ENV" -eq 1 ]]; then\n  # A new venv'):]
        fresh = fresh[: fresh.index("else\n")]
        for flag in ("--isolated", "--no-cache-dir", "--require-hashes", "--only-binary=:all:", "--no-deps"):
            self.assertIn(flag, fresh)
        self.assertIn('VENV_DIR="$BUILD_TMP/venv"', fresh)

    def test_watch_paths_include_the_verifier(self) -> None:
        text = BUILD_HELPER.read_text()
        watch = text[text.index("WATCH_PATHS=("): text.index(")", text.index("WATCH_PATHS=("))]
        self.assertIn('"$ENVIRONMENT_VERIFIER"', watch)

    def test_fresh_env_is_accepted_with_if_needed(self) -> None:
        env = {key: value for key, value in os.environ.items() if not key.startswith(("PROVENANCE_", "DYLD_"))}
        result = subprocess.run(
            ["/bin/bash", str(BUILD_HELPER), "--if-needed", "--fresh-env", "--bogus"],
            capture_output=True,
            text=True,
            env=env,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("--fresh-env", result.stderr)


if __name__ == "__main__":
    unittest.main()
