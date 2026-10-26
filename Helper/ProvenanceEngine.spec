# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller recipe for the signed nested provenance-engine app bundle."""

from __future__ import annotations

import os
from pathlib import Path


ROOT = Path(os.environ["PROVENANCE_BUILD_ROOT"]).resolve()
SOURCE = ROOT / "Helper" / "provenance_helper.py"
UPSTREAM = ROOT / "Vendor" / "watermarks-remover" / "service" / "scripts"
STAGED_TOOLS = ROOT / "Vendor" / "Artifacts" / "staged"
TARGET_ARCH = os.environ.get("PROVENANCE_BUILD_TARGET_ARCH", "arm64")


def staged_tool_files() -> tuple[list[tuple[str, str]], list[tuple[str, str]]]:
    """Classify native tools as code and scripts/licenses as sealed resources."""

    binaries: list[tuple[str, str]] = []
    datas: list[tuple[str, str]] = []
    for tool_name, executable_name in (("c2patool", "c2patool"), ("qpdf", "qpdf"), ("ghostscript", "gs")):
        tool_root = STAGED_TOOLS / tool_name
        executable = tool_root / executable_name
        if executable.is_file():
            binaries.append((str(executable), f"tools/{tool_name}"))
        if tool_root.is_dir():
            for item in sorted(tool_root.rglob("*")):
                if item.is_file() and item != executable:
                    relative_parent = item.relative_to(tool_root).parent
                    destination = Path("tools") / tool_name / relative_parent
                    datas.append((str(item), str(destination)))

    exiftool_root = STAGED_TOOLS / "exiftool"
    if exiftool_root.is_dir():
        for item in sorted(exiftool_root.rglob("*")):
            if item.is_file():
                relative_parent = item.relative_to(exiftool_root).parent
                destination = Path("tools") / "exiftool" / relative_parent
                datas.append((str(item), str(destination)))
    return binaries, datas


TOOL_BINARIES, TOOL_DATAS = staged_tool_files()

a = Analysis(
    [str(SOURCE)],
    pathex=[str(SOURCE.parent), str(UPSTREAM)],
    binaries=TOOL_BINARIES,
    datas=TOOL_DATAS,
    hiddenimports=[],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)
exe = EXE(
    pyz,
    a.scripts,
    exclude_binaries=True,
    name="provenance-engine",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=TARGET_ARCH,
    codesign_identity=None,
    entitlements_file=None,
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name="ProvenanceEngine",
)
app = BUNDLE(
    coll,
    name="ProvenanceEngine.app",
    icon=None,
    bundle_identifier="com.provenancecleaner.mac.engine",
    version="0.5.1",
    info_plist={
        "CFBundleDisplayName": "Provenance Engine",
        "CFBundleName": "ProvenanceEngine",
        "LSBackgroundOnly": True,
        "LSMinimumSystemVersion": "14.0",
        "NSHighResolutionCapable": True,
    },
)
