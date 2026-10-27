"""Find and remove the traces PDF generators leave outside document metadata.

PyMuPDF, ReportLab and similar libraries name resources their own way (`/helv`,
`/gRLs0`, `/F2+0`), wrap page content in extra `q`/`Q` streams, tag every font
subset `AAAAAA+`, and keep the first document ID for life. A content
credential can also travel as an attached file. None of that is touched by
ExifTool, and Ghostscript only clears it by redrawing every page, which can
change how text copies out of the PDF.

This rewrite goes through qpdf's JSON form instead: content streams are decoded
only to rename resource operands, image and font data stay byte-identical, and
qpdf validates and serializes the result.
"""
from __future__ import annotations

import json
import re
import secrets
import shutil
import subprocess
import tempfile
import zlib
from pathlib import Path
from typing import Any

import metadata_editor

QPDF_TIMEOUT = 120
# The categories a content stream refers to by name, and the prefix for their
# new names.
CATEGORIES = {"/Font": "F", "/XObject": "X", "/ExtGState": "GS", "/Pattern": "P",
              "/Shading": "Sh", "/ColorSpace": "CS", "/Properties": "MC"}
_SUBSET_TAG = re.compile(r"^/([A-Z]{6})\+(.+)$")
_ENCODING_SUFFIX = re.compile(r"-Identity-[HV]$")
_DA_FONT = re.compile(r"/([^\s/\[\]()<>{}%]+)\s+[-+.\d]+\s+Tf")
_WHITESPACE = b"\x00\t\n\x0c\r "
_DELIMITERS = b"()<>[]{}/%"
_NUMBER = re.compile(rb"[+-]?(?:\d+\.?\d*|\.\d+)$")
_PYMUPDF_NAMES = re.compile(r"^/(?:helv|fzImg\d+|fzFrm\d+|fitz\w*)$")
_REPORTLAB_NAMES = re.compile(r"^/(?:gRLs\d+|F\d+\+\d+|FormXob\.[0-9a-f]+)$")
_EXIFTOOL_DATE = re.compile(r"^(\d{4}):(\d{2}):(\d{2}) (\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?)$")
_PROPERTY_TAGS = [("Producer", ("PDF:Producer", "XMP-pdf:Producer")),
                  ("Creator", ("PDF:Creator", "XMP-xmp:CreatorTool")),
                  ("Created", ("PDF:CreateDate", "XMP-xmp:CreateDate")),
                  ("Modified", ("PDF:ModifyDate", "XMP-xmp:ModifyDate"))]


class PdfTraceError(ValueError):
    pass


def _qpdf() -> str:
    tool = shutil.which("qpdf")
    if tool is None:
        raise PdfTraceError("the bundled qpdf is unavailable")
    return tool


def _run(args: list[str]) -> subprocess.CompletedProcess:
    try:
        return subprocess.run([_qpdf(), *args], capture_output=True, timeout=QPDF_TIMEOUT, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise PdfTraceError(f"qpdf could not run: {exc}") from exc


def _encrypted(path: Path) -> bool:
    # --requires-password exits 2 only for an unencrypted file.
    return _run(["--requires-password", str(path)]).returncode != 2


# --- Detection fixes ----------------------------------------------------------

def expand_object_streams(data: bytes) -> bytes | None:
    """The same PDF with compressed object streams written out as plain objects.

    Word, Chrome, Ghostscript and qpdf pack dictionaries, including the
    document-info dictionary, into compressed object streams, where a byte scan
    sees nothing. Other stream payloads stay as they are.
    """
    with tempfile.TemporaryDirectory(prefix="pdf-expand-") as temp:
        source, target = Path(temp) / "in.pdf", Path(temp) / "out.pdf"
        source.write_bytes(data)
        try:
            result = _run(["--object-streams=disable", "--decode-level=none", "--", str(source), str(target)])
        except PdfTraceError:
            return None
        if result.returncode not in (0, 3) or not target.is_file():
            return None
        return target.read_bytes()


def _literal_end(data: bytes, start: int) -> int:
    """Index after the PDF literal string that opens at *start*."""
    depth, index = 0, start
    while index < len(data):
        value = data[index]
        if value == 0x5C:  # backslash escapes the next byte
            index += 2
            continue
        if value == 0x28:
            depth += 1
        elif value == 0x29:
            depth -= 1
            if depth == 0:
                return index + 1
        index += 1
    return len(data)


_URI_KEY = re.compile(rb"/URI\s*(?=[(<])")


def without_link_targets(blob: bytes) -> bytes:
    """*blob* with every link URI emptied.

    A link to openai.com is page content, not a statement about who made the
    file, so it must not count as an AI marker.
    """
    parts, last = [], 0
    for match in _URI_KEY.finditer(blob):
        start = match.end()
        if start < last:
            continue
        if blob[start] == 0x28:
            end = _literal_end(blob, start)
        else:
            end = blob.find(b">", start)
            end = len(blob) if end < 0 else end + 1
        parts.extend((blob[last:start], b"()"))
        last = end
    parts.append(blob[last:])
    return b"".join(parts)


def has_images(data: bytes) -> bool:
    """True when the PDF has an image XObject or an attached file.

    Attachments count because the Ghostscript pass is also what drops them.
    """
    with tempfile.TemporaryDirectory(prefix="pdf-images-") as temp:
        source = Path(temp) / "in.pdf"
        source.write_bytes(data)
        result = _run(["--json=2", "--json-key=qpdf", "--json-stream-data=none", str(source)])
        if result.returncode not in (0, 3):
            return True  # unknown: let the deep pass decide as before
        objects = json.loads(result.stdout)["qpdf"][1]
    for value in objects.values():
        stream = value.get("stream")
        if stream and (stream["dict"].get("/Subtype") == "/Image" or stream["dict"].get("/Type") == "/EmbeddedFile"):
            return True
    return False


# --- qpdf JSON model -------------------------------------------------------------

class _Document:
    def __init__(self, path: Path, temp: Path):
        self.temp = temp
        self.json_path = temp / "doc.json"
        result = _run(["--json-output=2", "--json-stream-data=file", f"--json-stream-prefix={temp / 's'}",
                       "--decode-level=none", "--", str(path), str(self.json_path)])
        if result.returncode not in (0, 3):
            raise PdfTraceError("qpdf couldn't read the PDF")
        self.raw = json.loads(self.json_path.read_text("utf-8"))
        self.objects: dict[str, Any] = self.raw["qpdf"][1]
        self.trailer = self.objects["trailer"]["value"]

    def get(self, value):
        """Follow a reference to the object's value (or stream wrapper)."""
        if isinstance(value, str) and value.endswith(" R"):
            entry = self.objects.get(f"obj:{value}", {})
            return entry.get("value", entry if "stream" in entry else None)
        return value

    def dictionary(self, value) -> dict | None:
        value = self.get(value)
        if isinstance(value, dict) and "stream" in value:
            return value["stream"]["dict"]
        return value if isinstance(value, dict) else None

    def streams(self):
        for key, entry in self.objects.items():
            if "stream" in entry:
                yield key[4:], entry["stream"]

    def dictionaries(self):
        """Every dictionary in the file, including nested direct ones."""
        stack = [entry.get("value", entry.get("stream", {}).get("dict")) for entry in self.objects.values()]
        while stack:
            value = stack.pop()
            if isinstance(value, dict):
                yield value
                stack.extend(value.values())
            elif isinstance(value, list):
                stack.extend(value)

    def pages(self):
        stack = [self.dictionary(self.dictionary(self.trailer["/Root"]).get("/Pages"))]
        seen = set()
        while stack:
            node = stack.pop()
            if node is None or id(node) in seen:
                continue
            seen.add(id(node))
            if node.get("/Type") == "/Page" or "/Kids" not in node:
                yield node
            else:
                stack.extend(self.dictionary(kid) for kid in reversed(node["/Kids"]))

    def stream_data(self, stream: dict) -> bytes | None:
        """Decoded data of a content stream, or None if its filter isn't Flate."""
        raw = Path(stream["datafile"]).read_bytes()
        filters = stream["dict"].get("/Filter")
        filters = [filters] if isinstance(filters, str) else (filters or [])
        if not filters:
            return raw
        if filters != ["/FlateDecode"] or stream["dict"].get("/DecodeParms"):
            return None
        try:
            return zlib.decompress(raw)
        except zlib.error:
            return None

    def set_stream_data(self, stream: dict, data: bytes) -> None:
        target = self.temp / f"new-{secrets.token_hex(8)}"
        target.write_bytes(zlib.compress(data, 9))
        stream["datafile"] = str(target)
        stream["dict"]["/Filter"] = "/FlateDecode"
        stream["dict"].pop("/DecodeParms", None)
        stream["dict"].pop("/Length", None)

    def write(self, target: Path, extra: list[str]) -> None:
        self.json_path.write_text(json.dumps(self.raw), "utf-8")
        result = _run(["--json-input", *extra, "--", str(self.json_path), str(target)])
        if result.returncode not in (0, 3) or not target.is_file():
            raise PdfTraceError("qpdf couldn't write the rewritten PDF: " + result.stderr.decode("utf-8", "replace")[:300])


# --- Content streams -------------------------------------------------------------

_INLINE_END = re.compile(rb"[\x00\t\n\x0c\r ]EI(?=[\x00\t\n\x0c\r ]|$)")


def _tokens(data: bytes):
    """(kind, start, end) for each token; kind is name, word, open, close or other."""
    index, length = 0, len(data)
    while index < length:
        value = data[index]
        if value in _WHITESPACE:
            index += 1
        elif value == 0x25:
            ends = [p for p in (data.find(b"\n", index), data.find(b"\r", index)) if p >= 0]
            index = min(ends, default=length)
        elif value == 0x28:
            end = _literal_end(data, index)
            yield "other", index, end
            index = end
        elif value == 0x3C and data[index + 1:index + 2] == b"<":
            yield "open", index, index + 2
            index += 2
        elif value == 0x3C:
            end = data.find(b">", index)
            if end < 0:
                raise PdfTraceError("unterminated hex string in page content")
            yield "other", index, end + 1
            index = end + 1
        elif value == 0x3E:
            if data[index + 1:index + 2] != b">":
                raise PdfTraceError("unexpected '>' in page content")
            yield "close", index, index + 2
            index += 2
        elif value in b"[{":
            yield "open", index, index + 1
            index += 1
        elif value in b"]}":
            yield "close", index, index + 1
            index += 1
        else:
            end = index + 1
            while end < length and data[end] not in _WHITESPACE and data[end] not in _DELIMITERS:
                end += 1
            yield ("name" if value == 0x2F else "word"), index, end
            if data[index:end] == b"ID":
                # Inline image data runs from one byte after ID up to "EI".
                match = _INLINE_END.search(data, end + 1)
                if match is None:
                    raise PdfTraceError("unterminated inline image in page content")
                yield "other", end + 1, match.start() + 1
                end = match.start() + 1
            index = end


def _decode_name(raw: bytes) -> str:
    return "/" + re.sub(rb"#([0-9A-Fa-f]{2})", lambda m: bytes([int(m[1], 16)]), raw[1:]).decode("latin-1")


# Operator -> (category, operand index) of the resource it names.
_OPERAND = {b"Tf": ("/Font", -2), b"Do": ("/XObject", -1), b"gs": ("/ExtGState", -1),
            b"sh": ("/Shading", -1), b"cs": ("/ColorSpace", -1), b"CS": ("/ColorSpace", -1),
            b"scn": ("/Pattern", -1), b"SCN": ("/Pattern", -1), b"BDC": ("/Properties", -1),
            b"DP": ("/Properties", -1)}


def resource_references(data: bytes):
    """(category, start, end, name) for every resource named in a content stream."""
    operands: list[tuple[str, int, int]] = []
    depth = 0
    inline = False
    for kind, start, end in _tokens(data):
        if kind == "open":
            depth += 1
            continue
        if kind == "close":
            depth = max(0, depth - 1)
            if depth == 0:
                operands.append(("other", start, end))
            continue
        if depth:
            continue
        token = data[start:end]
        if kind != "word" or _NUMBER.match(token) or token in (b"true", b"false", b"null"):
            operands.append((kind, start, end))
            continue
        if token == b"ID" and inline:
            # Inline image keys /CS and /ColorSpace may name a resource.
            for key, value in zip(operands[::2], operands[1::2]):
                if data[key[1]:key[2]] in (b"/CS", b"/ColorSpace") and value[0] == "name":
                    yield "/ColorSpace", value[1], value[2], _decode_name(data[value[1]:value[2]])
        elif token in _OPERAND:
            category, position = _OPERAND[token]
            if len(operands) >= -position and operands[position][0] == "name":
                _, first, last = operands[position]
                yield category, first, last, _decode_name(data[first:last])
        inline = token == b"BI"
        operands = []


def _content_streams(doc: _Document) -> list[dict]:
    found: dict[int, dict] = {}

    def add(value):
        value = doc.get(value)
        if isinstance(value, list):
            for item in value:
                add(item)
        elif isinstance(value, dict) and "stream" in value:
            found[id(value["stream"])] = value["stream"]

    for page in doc.pages():
        add(page.get("/Contents"))
        for annotation in doc.get(page.get("/Annots")) or []:
            appearance = doc.dictionary((doc.dictionary(annotation) or {}).get("/AP"))
            for state in (appearance or {}).values():
                state = doc.get(state)
                if isinstance(state, dict) and "stream" not in state:
                    for item in state.values():
                        add(item)
                else:
                    add(state)
    for _, stream in doc.streams():
        if stream["dict"].get("/Subtype") == "/Form" or stream["dict"].get("/PatternType") == 1:
            found[id(stream)] = stream
    for dictionary in doc.dictionaries():
        if dictionary.get("/Subtype") == "/Type3":
            for proc in (doc.dictionary(dictionary.get("/CharProcs")) or {}).values():
                add(proc)
    return list(found.values())


def _resource_dictionaries(doc: _Document) -> list[tuple[str, dict, bool]]:
    """(category, dictionary, belongs to a form's /DR) for each one, once."""
    found: dict[int, tuple[str, dict, bool]] = {}
    for dictionary in doc.dictionaries():
        for key in ("/Resources", "/DR"):
            resources = doc.dictionary(dictionary.get(key))
            for category in CATEGORIES if resources is not None else ():
                inner = doc.dictionary(resources.get(category))
                if inner is not None:
                    previous = found.get(id(inner))
                    found[id(inner)] = (category, inner, key == "/DR" or bool(previous and previous[2]))
    return list(found.values())


# --- Inspection ------------------------------------------------------------------

def _page_content_wrapped(doc: _Document) -> bool:
    for page in doc.pages():
        contents = doc.get(page.get("/Contents"))
        if isinstance(contents, list) and len(contents) >= 3:
            first = doc.get(contents[0])
            if isinstance(first, dict) and "stream" in first and (doc.stream_data(first["stream"]) or b"").strip() == b"q":
                return True
    return False


def _properties(path: Path) -> list[dict]:
    try:
        tags = metadata_editor._read_tags(path)
    except metadata_editor.MetadataError:
        return []
    result = []
    for label, keys in _PROPERTY_TAGS:
        value = next((str(tags[key]) for key in keys if str(tags.get(key, "")).strip()), None)
        if value is not None:
            # ExifTool writes "2026:10:27 16:20:45+08:00"; the app reads ISO 8601.
            value = _EXIFTOOL_DATE.sub(r"\1-\2-\3T\4", value)
            result.append({"label": label, "value": value})
    return result


def inspect(path: Path, data: bytes) -> dict:
    """Document properties plus the generator traces this file still carries."""
    report: dict[str, Any] = {"properties": _properties(path), "generators": []}
    try:
        if _encrypted(path):
            return {**report, "available": False, "reason": "This PDF is encrypted, so its structure wasn't checked."}
        with tempfile.TemporaryDirectory(prefix="pdf-traces-") as temp:
            doc = _Document(path, Path(temp))
            names = {name for _, inner, _ in _resource_dictionaries(doc) for name in inner}
            tags = {match[1] for d in doc.dictionaries() for key in ("/BaseFont", "/FontName")
                    if isinstance(d.get(key), str) and (match := _SUBSET_TAG.match(d[key]))}
            wrapped = _page_content_wrapped(doc)
            c2pa = len(_c2pa_filespecs(doc))
    except (PdfTraceError, ValueError, KeyError, OSError) as exc:
        return {**report, "available": False, "reason": f"The PDF structure couldn't be checked: {exc}"}
    evidence = {"PyMuPDF": [], "ReportLab": []}
    if re.match(rb"%PDF-\d\.\d\s*%\xc2\xb5\xc2\xb6", data):
        evidence["PyMuPDF"].append("MuPDF file header")
    pymupdf = sorted(n for n in names if _PYMUPDF_NAMES.match(n))
    if pymupdf:
        evidence["PyMuPDF"].append("resources named " + ", ".join(pymupdf[:4]))
    if wrapped:
        evidence["PyMuPDF"].append("page content wrapped in extra q/Q streams")
    if b"ReportLab Generated PDF" in data[:4096] or b"% ReportLab generated PDF" in data[-4096:]:
        evidence["ReportLab"].append("ReportLab comments in the file")
    reportlab = sorted(n for n in names if _REPORTLAB_NAMES.match(n))
    if reportlab:
        evidence["ReportLab"].append("resources named " + ", ".join(reportlab[:4]))
    if "AAAAAA" in tags:
        evidence["ReportLab"].append("every font subset tagged AAAAAA+")
    report["generators"] = [{"name": name, "evidence": items} for name, items in evidence.items() if items]
    report.update({"available": True, "resourceNames": len(names), "subsetTags": len(tags),
                   "contentWrapped": wrapped, "c2paAttachments": c2pa})
    return report


# --- Removal ---------------------------------------------------------------------

def _is_c2pa_filespec(doc: _Document, value) -> bool:
    spec = doc.dictionary(value)
    if not spec:
        return False
    if spec.get("/AFRelationship") == "/C2PA_Manifest" or spec.get("/Subtype") in ("u:application/c2pa", "/application#2Fc2pa"):
        return True
    embedded = doc.dictionary(doc.dictionary(spec.get("/EF")) and doc.dictionary(spec.get("/EF")).get("/F"))
    return bool(embedded) and embedded.get("/Subtype") == "/application#2Fc2pa"


def _c2pa_filespecs(doc: _Document) -> set[str]:
    return {key[4:] for key, entry in doc.objects.items()
            if key.startswith("obj:") and _is_c2pa_filespec(doc, key[4:])}


def _remove_c2pa_attachments(doc: _Document) -> int:
    specs = _c2pa_filespecs(doc)
    if not specs:
        return 0
    catalog = doc.dictionary(doc.trailer["/Root"])
    for owner in [catalog, *doc.pages()]:
        files = doc.get(owner.get("/AF"))
        if isinstance(files, list):
            kept = [item for item in files if item not in specs]
            if kept:
                owner["/AF"] = kept
            else:
                owner.pop("/AF")

    def prune(node) -> bool:
        """Drop manifest entries from a name-tree node; True when it's empty."""
        node = doc.dictionary(node)
        if node is None:
            return True
        if "/Names" in node:
            pairs = doc.get(node["/Names"])
            node["/Names"] = [item for pair in zip(pairs[::2], pairs[1::2]) if pair[1] not in specs for item in pair]
        if "/Kids" in node:
            node["/Kids"] = [kid for kid in doc.get(node["/Kids"]) if not prune(kid)]
        empty = not node.get("/Names") and not node.get("/Kids")
        if empty:
            for key in ("/Names", "/Kids", "/Limits"):
                node.pop(key, None)
        return empty

    names = doc.dictionary(catalog.get("/Names"))
    if names and "/EmbeddedFiles" in names and prune(names["/EmbeddedFiles"]):
        names.pop("/EmbeddedFiles")
        if not names:
            catalog.pop("/Names")
    return len(specs)


def _rename_resources(doc: _Document) -> int:
    streams = _content_streams(doc)
    decoded = []
    for stream in streams:
        data = doc.stream_data(stream)
        if data is None:
            raise PdfTraceError("a page content stream uses an unsupported filter")
        decoded.append((stream, data, list(resource_references(data))))
    # Form-field appearance strings (/DA) name /DR fonts as text, so those
    # names stay as they are.
    keep = {"/" + name for d in doc.dictionaries() if isinstance(d.get("/DA"), str) for name in _DA_FONT.findall(d["/DA"])}
    dictionaries = list(_resource_dictionaries(doc))
    for category, inner, form in dictionaries:
        if form:
            keep.update(inner)
    # One mapping per category for the whole file, to names no dictionary
    # uses yet, so shared and inherited resources stay consistent.
    mapping: dict[str, dict[str, str]] = {category: {} for category in CATEGORIES}
    taken = {category: {name for c, d, _ in dictionaries if c == category for name in d} for category in CATEGORIES}
    counters = dict.fromkeys(CATEGORIES, 0)
    for category, inner, _ in dictionaries:
        for name in inner:
            if name in keep or name in mapping[category]:
                continue
            counters[category] += 1
            while f"/{CATEGORIES[category]}{counters[category]}" in taken[category]:
                counters[category] += 1
            mapping[category][name] = f"/{CATEGORIES[category]}{counters[category]}"
            taken[category].add(mapping[category][name])
    for category, inner, _ in dictionaries:
        for old in [name for name in inner if name in mapping[category]]:
            inner[mapping[category][old]] = inner.pop(old)
            # PDF 1.0's optional /Name repeats the old resource name.
            resource = doc.dictionary(inner[mapping[category][old]])
            if category in ("/Font", "/XObject") and resource is not None:
                resource.pop("/Name", None)
    for stream, data, references in decoded:
        parts, last = [], 0
        for category, start, end, name in references:
            new = mapping[category].get(name)
            if new:
                parts.extend((data[last:start], new.encode("ascii")))
                last = end
        if parts:
            parts.append(data[last:])
            doc.set_stream_data(stream, b"".join(parts))
    return sum(len(names) for names in mapping.values())


def _retag_subsets(doc: _Document) -> int:
    """Give each font subset a fresh tag, wherever the old tag is written."""
    tags: dict[tuple[str, str], str] = {}
    for dictionary in doc.dictionaries():
        for key in ("/BaseFont", "/FontName"):
            match = _SUBSET_TAG.match(dictionary[key]) if isinstance(dictionary.get(key), str) else None
            if not match:
                continue
            identity = (match[1], _ENCODING_SUFFIX.sub("", match[2]))
            new = tags.setdefault(identity, "".join(chr(65 + secrets.randbelow(26)) for _ in range(6)))
            dictionary[key] = f"/{new}+{match[2]}"
            # Some writers repeat the subset name in the ToUnicode CMap.
            cmap = doc.get(dictionary.get("/ToUnicode"))
            if isinstance(cmap, dict) and "stream" in cmap:
                data = doc.stream_data(cmap["stream"])
                old = f"{identity[0]}+{identity[1]}".encode("latin-1")
                if data and old in data:
                    doc.set_stream_data(cmap["stream"], data.replace(old, f"{new}+{identity[1]}".encode("latin-1")))
    return len(tags)


def normalize(path: Path) -> list[str]:
    """Rewrite *path* in place without generator traces; returns what changed."""
    if _encrypted(path):
        raise PdfTraceError("the PDF is encrypted")
    with tempfile.TemporaryDirectory(prefix="pdf-normalize-") as temp:
        doc = _Document(path, Path(temp))
        actions = []
        removed = _remove_c2pa_attachments(doc)
        if removed:
            actions.append(f"removed {removed} attached content credential{'s' if removed != 1 else ''}")
        try:
            renamed = _rename_resources(doc)
            actions.append(f"renamed {renamed} resource names")
        except PdfTraceError as exc:
            actions.append(f"kept resource names ({exc})")
        retagged = _retag_subsets(doc)
        if retagged:
            actions.append(f"gave {retagged} font subset{'s' if retagged != 1 else ''} new tags")
        doc.trailer["/ID"] = [f"b:{secrets.token_hex(16)}", f"b:{secrets.token_hex(16)}"]
        actions.append("merged page content streams and wrote a new document ID")
        target = Path(temp) / "out.pdf"
        doc.write(target, ["--coalesce-contents", "--object-streams=generate", "--linearize"])
        if _run(["--check", str(target)]).returncode not in (0, 3):
            raise PdfTraceError("the rewritten PDF failed validation")
        shutil.move(str(target), str(path))
    return actions


# --- Wiring into the pinned engine -----------------------------------------------

NO_IMAGES_ACTION = "deep image pass not needed: the PDF has no embedded images or attachments"


def install(container_meta) -> None:
    upstream_blob = container_meta._pdf_structured_blob
    upstream_rewrite = container_meta._pdf_structural_rewrite
    upstream_deep = container_meta._pdf_deep_image_clean

    def structured_blob(data: bytes) -> bytes:
        return without_link_targets(upstream_blob(expand_object_streams(data) or data))

    def structural_rewrite(dest, actions, deadline=None):
        rewritten = upstream_rewrite(dest, actions, deadline)
        if rewritten:
            try:
                actions.append("PDF traces: " + "; ".join(normalize(Path(dest))))
            except PdfTraceError as exc:
                actions.append(f"PDF traces kept: {exc}")
        return rewritten

    def deep_image_clean(dest, actions, *args, **kwargs):
        if not has_images(Path(dest).read_bytes()):
            actions.append(NO_IMAGES_ACTION)
            return False
        return upstream_deep(dest, actions, *args, **kwargs)

    container_meta._pdf_structured_blob = structured_blob
    container_meta._pdf_structural_rewrite = structural_rewrite
    container_meta._pdf_deep_image_clean = deep_image_clean
