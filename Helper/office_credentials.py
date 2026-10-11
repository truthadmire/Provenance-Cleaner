"""Bounded OOXML credential inspection without extracting archive paths."""
from __future__ import annotations

import re
import tempfile
import time
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET

MANIFEST_PATH = "META-INF/content_credential.c2pa"
MAX_PARTS = 10000
MAX_ASSETS = 128
MAX_ASSET_BYTES = 64 << 20
MAX_TOTAL_BYTES = 256 << 20
MAX_SECONDS = 90
IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".webp", ".avif", ".heic", ".heif", ".gif", ".bmp", ".tif", ".tiff", ".svg", ".emf", ".wmf", ".emz", ".wmz"}


def _unresolved(message):
    return {"state": "inconclusive", "inspectionIncomplete": True,
            "signature": "unknown", "contentBinding": "unknown", "trust": "unknown",
            "error": message}


def _image_suffix(raw, name):
    # Media parts sometimes use a .bin or incorrect suffix. Verify the actual
    # bytes using a private generated name; archive paths never reach disk.
    for header, ext in ((b"\xff\xd8\xff", ".jpg"), (b"\x89PNG\r\n\x1a\n", ".png"),
                        (b"GIF8", ".gif"), (b"II*\x00", ".tif"), (b"MM\x00*", ".tif"), (b"BM", ".bmp")):
        if raw.startswith(header):
            return ext
    if raw[:4] == b"RIFF" and raw[8:12] == b"WEBP":
        return ".webp"
    if raw[4:8] == b"ftyp":
        return ".avif" if b"avif" in raw[8:64] or b"avis" in raw[8:64] else ".heic"
    return Path(name).suffix.lower() or ".bin"


def _image_parts(archive, infos):
    names, extensions = set(), set()
    # Content types cover images outside the conventional word/media directory.
    if "[Content_Types].xml" in archive.namelist():
        info = archive.getinfo("[Content_Types].xml")
        if info.file_size > 4 << 20:
            raise ValueError("Office content types exceed the inspection limit")
        raw = archive.read(info)
        if re.search(br"<!\s*(DOCTYPE|ENTITY)", raw, re.I):
            raise ValueError("Office content types contain unsupported XML declarations")
        root = ET.fromstring(raw)
        for element in root:
            if element.get("ContentType", "").lower().startswith("image/"):
                if element.get("PartName"):
                    names.add(element.get("PartName").lstrip("/"))
                if element.get("Extension"):
                    extensions.add("." + element.get("Extension").lower())
    return [i for i in infos if not i.is_dir() and (
        re.match(r"^(word|xl|ppt)/media/", i.filename, re.I) or
        i.filename in names or Path(i.filename).suffix.lower() in IMAGE_SUFFIXES | extensions)]


def inspect_office(path: Path, verify) -> dict:
    started = time.monotonic()
    document = _unresolved("Document inspection has not completed")
    assets, errors = [], []
    manifest_present, asset_count = False, 0
    available = True
    try:
        with zipfile.ZipFile(path) as archive:
            infos = archive.infolist()
            manifest_present = any(i.filename == MANIFEST_PATH for i in infos)
            if len(infos) > MAX_PARTS or sum(i.file_size for i in infos) > MAX_TOTAL_BYTES:
                raise ValueError("Office package exceeds the part or decompressed-size limit")
            if len({i.filename for i in infos}) != len(infos):
                raise ValueError("Office package contains duplicate part names")
            if any(i.flag_bits & 1 for i in infos):
                raise ValueError("Encrypted Office parts could not be inspected")
            main_part = {".docx": "word/document.xml", ".xlsx": "xl/workbook.xml", ".pptx": "ppt/presentation.xml"}[path.suffix.lower()]
            if "[Content_Types].xml" not in archive.namelist() or main_part not in archive.namelist():
                raise ValueError("The archive is missing required Office document parts")
            probe = verify(path, timeout=15)
            available = probe.get("available", False)
            document = probe["details"]
            # The standard ZIP entry is evidence even if the verifier cannot
            # decode it. A parser error or empty manifest is never absence.
            if manifest_present and document["state"] != "present":
                document.update(state="present_unverified", inspectionIncomplete=True)
                document["error"] = probe.get("error") or "The package contains a C2PA entry, but no verifiable manifest could be read."
            document["manifestPresent"] = manifest_present or probe.get("has_manifest", False)
            try:
                media = _image_parts(archive, infos)
            except (ValueError, RuntimeError, zipfile.BadZipFile, NotImplementedError, ET.ParseError) as exc:
                errors.append(f"Image content types could not be read: {exc}")
                # Retain checks whose locations are still known independently.
                media = [i for i in infos if not i.is_dir() and (
                    re.match(r"^(word|xl|ppt)/media/", i.filename, re.I) or
                    Path(i.filename).suffix.lower() in IMAGE_SUFFIXES)]
            asset_count = len(media)
            total = 0
            with tempfile.TemporaryDirectory(prefix="provenance-office-c2pa-") as folder:
                for index, info in enumerate(media[:MAX_ASSETS]):
                    remaining = MAX_SECONDS - (time.monotonic() - started)
                    if remaining <= 0:
                        errors.append(f"Inspection time limit reached; {len(media) - index} embedded assets were not inspected.")
                        break
                    try:
                        if info.file_size > MAX_ASSET_BYTES or total + info.file_size > MAX_TOTAL_BYTES:
                            raise ValueError("Embedded asset exceeds the inspection size limit")
                        with archive.open(info) as stream:
                            raw = stream.read(min(MAX_ASSET_BYTES, MAX_TOTAL_BYTES - total) + 1)
                        if len(raw) > MAX_ASSET_BYTES or total + len(raw) > MAX_TOTAL_BYTES:
                            raise ValueError("Embedded asset exceeds the inspection size limit")
                        total += len(raw)
                        target = Path(folder) / (str(index) + _image_suffix(raw, info.filename))
                        target.write_bytes(raw)
                        result = verify(target, timeout=max(0.1, min(15, remaining / 2)))
                        detail = result["details"]
                        # Do not leak disposable extraction paths into the UI.
                        for field in ("error", "certificateError"):
                            if field in detail:
                                detail[field] = detail[field].replace(str(target), info.filename)
                        target.unlink()
                    except (OSError, ValueError, RuntimeError, zipfile.BadZipFile, NotImplementedError) as exc:
                        detail = _unresolved(str(exc))
                    assets.append({"path": info.filename, **detail})
            if len(media) > MAX_ASSETS:
                errors.append(f"Embedded asset limit reached; only the first {MAX_ASSETS} of {len(media)} assets were inspected.")
    except (OSError, ValueError, RuntimeError, zipfile.BadZipFile, NotImplementedError, ET.ParseError) as exc:
        errors.append(str(exc))

    if manifest_present and document["state"] == "inconclusive":
        document.update(state="present_unverified", manifestPresent=True)
    all_details = [document, *assets]
    present = manifest_present or any(d["state"] in {"present", "present_unverified"} for d in all_details)
    incomplete = bool(errors) or any(d.get("inspectionIncomplete", True) for d in all_details)
    details = {
        "isContainer": True, "state": "present" if present else "inconclusive" if incomplete else "absent",
        "document": document, "embeddedAssets": assets, "embeddedCount": asset_count,
        "inspectedEmbeddedCount": len(assets), "coverageErrors": errors,
        "inspectionIncomplete": incomplete,
        "validationFailed": any(d.get("validationFailed", False) for d in all_details),
        "scope": "The document and embedded images are checked independently. An image credential does not authenticate the Word document or its author. External linked images, sidecars and remote manifests are not read. Validation is offline; live revocation and CAWG identity are not checked.",
    }
    return {"available": available, "ok": not incomplete, "has_manifest": present, "details": details}
