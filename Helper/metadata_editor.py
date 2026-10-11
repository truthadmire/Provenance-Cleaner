"""Explicit field edits on staged copies; unrelated content is retained."""
from __future__ import annotations

import io
import json
import re
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET

OFFICE = {".docx", ".xlsx", ".pptx"}
IMAGES = {".jpg", ".jpeg", ".png", ".tif", ".tiff", ".webp"}
CP = "http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
DC = "http://purl.org/dc/elements/1.1/"
FIELDS = {"author": ("Author", DC, "creator"), "title": ("Title", DC, "title"),
          "subject": ("Subject", DC, "subject"), "description": ("Description", DC, "description"),
          "keywords": ("Keywords", CP, "keywords"), "lastModifiedBy": ("Last saved by", CP, "lastModifiedBy"),
          "copyright": ("Copyright", DC, "rights")}
TAGS = {"author": ["XMP-dc:Creator"], "title": ["XMP-dc:Title"], "subject": ["XMP-dc:Subject"],
        "description": ["XMP-dc:Description"], "keywords": ["XMP-pdf:Keywords"], "copyright": ["XMP-dc:Rights"]}


class MetadataError(ValueError):
    pass


def validate_options(value):
    if not isinstance(value, dict) or not value or set(value) - FIELDS.keys():
        raise MetadataError("Choose at least one supported metadata field.")
    for text in value.values():
        if not isinstance(text, str) or len(text) > 4096 or any(ord(c) < 32 and c not in "\n\t" for c in text):
            raise MetadataError("Metadata must be text of at most 4,096 characters without control characters.")
    return value


def _xml(raw):
    if re.search(br"<!\s*(DOCTYPE|ENTITY)", raw, re.I):
        raise MetadataError("XML entity declarations are not supported.")
    try:
        return ET.fromstring(raw)
    except ET.ParseError as exc:
        raise MetadataError("Document properties XML is malformed.") from exc


def _office(data):
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            infos = archive.infolist()
            if len(infos) > 10000 or len({i.filename for i in infos}) != len(infos) or sum(i.file_size for i in infos) > 128 << 20:
                raise MetadataError("Office package exceeds the size/part limit or contains duplicate parts.")
            parts = [(info, archive.read(info)) for info in infos]
            signed = any(info.filename.lower().startswith("_xmlsignatures/") or (info.filename == "[Content_Types].xml" and b"digital-signature" in raw) for info, raw in parts)
            core = next((raw for info, raw in parts if info.filename == "docProps/core.xml"), None)
            if core is None:
                raise MetadataError("This package has no standard document properties part to edit.")
            root = _xml(core)
            if root.tag != f"{{{CP}}}coreProperties":
                raise MetadataError("This document properties namespace is not supported.")
            return parts, root, signed, archive.comment
    except (zipfile.BadZipFile, RuntimeError, NotImplementedError) as exc:
        raise MetadataError("Office package is damaged, encrypted or unsupported.") from exc


def _tags(ext):
    result = {k: list(v) for k, v in TAGS.items()}
    if ext == ".pdf":
        for k, tag in {"author": "Author", "title": "Title", "subject": "Subject", "keywords": "Keywords"}.items():
            result[k].append("PDF:" + tag)
        # PDF Subject and XMP Description conventionally represent the same field.
        result.pop("description")
        result["subject"].append("XMP-dc:Description")
    if ext in {".jpg", ".jpeg", ".tif", ".tiff"}:
        for k, tags in {"author": ["IFD0:Artist"], "description": ["IFD0:ImageDescription"], "copyright": ["IFD0:Copyright"]}.items():
            result[k].extend(tags)
    if ext in {".jpg", ".jpeg", ".tif", ".tiff"}:
        for k, tag in {"author": "By-line", "title": "ObjectName", "description": "Caption-Abstract", "keywords": "Keywords", "copyright": "CopyrightNotice"}.items():
            result[k].append("IPTC:" + tag)
    if ext == ".png":
        for k, tag in {"author": "Author", "title": "Title", "description": "Description", "copyright": "Copyright"}.items():
            result[k].append("PNG:" + tag)
    return result


def _read_tags(path):
    tool = shutil.which("exiftool")
    if not tool:
        raise MetadataError("The bundled metadata reader is unavailable.")
    r = subprocess.run([tool, "-j", "-G1", "-s", "-charset", "filename=UTF8", str(path)], capture_output=True, text=True, timeout=5)
    try:
        values = json.loads(r.stdout)[0]
    except (ValueError, IndexError, TypeError) as exc:
        raise MetadataError("The metadata reader returned no usable result.") from exc
    if r.returncode != 0 or "ExifTool:Error" in values:
        raise MetadataError(str(values.get("ExifTool:Error", "The file could not be read.")))
    return values


def _text(value):
    return "; ".join(str(v) for v in value) if isinstance(value, list) else str(value)


def inspect(path, data=None):
    ext = path.suffix.lower()
    try:
        if ext in OFFICE:
            _, root, signed, _ = _office(data if data is not None else path.read_bytes())
            fields = [{"id": key, "label": label, "value": "; ".join(n.text or "" for n in root.findall(f"{{{ns}}}{tag}"))}
                      for key, (label, ns, tag) in FIELDS.items() if key != "copyright"]
            return {"available": True, "editable": not signed, "fields": fields,
                    "note": "Digitally signed Office packages cannot be edited." if signed else "Document properties only. Comment and revision author names are separate and stay unchanged."}
        if ext not in IMAGES | {".pdf"}:
            return {"available": False, "editable": False, "fields": [], "note": "Metadata editing supports DOCX, XLSX, PPTX, PDF, JPEG, PNG, TIFF and WebP."}
        values = _read_tags(path)
        fields = []
        for key, tags in _tags(ext).items():
            sources = [{"tag": tag, "value": _text(values[tag])} for tag in tags if tag in values]
            fields.append({"id": key, "label": FIELDS[key][0], "value": " / ".join(dict.fromkeys(s["value"] for s in sources)), "sources": sources})
        return {"available": True, "editable": True, "fields": fields,
                "note": "Edits may invalidate existing content credentials or digital signatures. Re-inspect the saved result."}
    except (MetadataError, OSError, subprocess.TimeoutExpired) as exc:
        return {"available": False, "editable": False, "fields": [], "note": str(exc), "incomplete": True}


def rewrite(data, ext, edits):
    edits = validate_options(edits)
    if ext in OFFICE:
        parts, root, signed, comment = _office(data)
        if signed:
            raise MetadataError("This Office package is digitally signed. Use an unsigned copy to edit properties.")
        if "copyright" in edits:
            raise MetadataError("Copyright is not an editable Office core property.")
        for key, text in edits.items():
            _, ns, tag = FIELDS[key]
            expanded = f"{{{ns}}}{tag}"
            nodes = root.findall(expanded)
            for node in nodes:
                root.remove(node)
            if text:
                ET.SubElement(root, expanded).text = text
        original_core = next(raw for info, raw in parts if info.filename == "docProps/core.xml")
        namespaces = dict(value for _, value in ET.iterparse(io.BytesIO(original_core), events=("start-ns",)))
        for prefix, uri in namespaces.items():
            if not re.fullmatch(r"ns\d+", prefix):
                ET.register_namespace(prefix, uri)
        encoded = ET.tostring(root, encoding="utf-8", xml_declaration=True)
        # Preserve prefixes used only inside QName attribute values (e.g.
        # xsi:type="dcterms:W3CDTF"), which ElementTree cannot track itself.
        for prefix, uri in namespaces.items():
            declaration = "xmlns" + (":" + prefix if prefix else "")
            if (declaration + "=").encode() not in encoded:
                root.set(declaration, uri)
        encoded = ET.tostring(root, encoding="utf-8", xml_declaration=True)
        _xml(encoded)
        output = io.BytesIO()
        with zipfile.ZipFile(output, "w") as archive:
            archive.comment = comment
            for info, raw in parts:
                archive.writestr(info, encoded if info.filename == "docProps/core.xml" else raw)
        cleaned = output.getvalue()
        after = inspect(Path("result" + ext), cleaned)
        actual = {f["id"]: f["value"] for f in after["fields"]}
        if any(actual.get(key) != value for key, value in edits.items()):
            raise MetadataError("Document property verification failed; no result was saved.")
        return cleaned
    if ext not in IMAGES | {".pdf"} or set(edits) - _tags(ext).keys():
        raise MetadataError("One or more fields cannot be edited in this file format.")
    tool = shutil.which("exiftool")
    if not tool:
        raise MetadataError("The bundled metadata writer is unavailable.")
    with tempfile.TemporaryDirectory(prefix="provenance-metadata-") as directory:
        path = Path(directory) / ("result" + ext)
        path.write_bytes(data)
        tags = _tags(ext)
        args = [tool, "-overwrite_original", "-charset", "filename=UTF8", "-charset", "IPTC=UTF8"]
        if ext in {".jpg", ".jpeg", ".tif", ".tiff"} and any(value for key, value in edits.items() if any(tag.startswith("IPTC:") for tag in tags[key])):
            args.append("-IPTC:CodedCharacterSet=UTF8")
        for key, value in edits.items():
            args.extend(f"-{tag}={value}" for tag in tags[key])
        r = subprocess.run([*args, str(path)], capture_output=True, text=True, timeout=30)
        if r.returncode != 0:
            raise MetadataError("Metadata write failed: " + r.stderr.strip()[:600])
        actual = _read_tags(path)
        for key, value in edits.items():
            for tag in tags[key]:
                if _text(actual.get(tag, "")) != value:
                    raise MetadataError(f"Could not verify {FIELDS[key][0]} in {tag}; no result was saved.")
        return path.read_bytes()
