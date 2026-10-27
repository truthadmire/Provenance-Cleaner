"""Inspect and rewrite existing DOCX editing metadata without rebuilding XML.

Expat resolves namespaces and validates the XML; edits replace byte ranges only.
Visible text, revision contents, relationship IDs, and all other parts are kept.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import io
import math
import re
import secrets
import zipfile
from xml.parsers import expat

W_NAMESPACES = {
    "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
    "http://purl.oclc.org/ooxml/wordprocessingml/main",
}
CORE_NAMESPACES = {
    "http://schemas.openxmlformats.org/package/2006/metadata/core-properties",
    "http://purl.oclc.org/ooxml/package/metadata/core-properties",
}
DCTERMS = "http://purl.org/dc/terms/"
RSID_NAMES = {"rsidR", "rsidRPr", "rsidRDefault", "rsidP", "rsidDel", "rsidSect"}
MAX_EXPANDED_BYTES = 128 << 20
MAX_PARTS = 10000
MAX_FIELDS = 200000
MAX_AUTHORS = 50
# Revision markup that keeps earlier content or formatting in the file.
REVISION_KINDS = {
    "ins": "insertions", "cellIns": "insertions",
    "del": "deletions", "cellDel": "deletions",
    "moveFrom": "moves",
    **{name: "formattingChanges" for name in (
        "rPrChange", "pPrChange", "sectPrChange", "tblPrChange", "tblPrExChange",
        "trPrChange", "tcPrChange", "tblGridChange", "numberingChange", "cellMerge")},
}
_ATTRIBUTE = re.compile(rb'''\s+([^\s=/>]+)\s*=\s*(["'])(.*?)\2''', re.S)


class WordTraceError(ValueError):
    pass


@dataclass(frozen=True)
class Field:
    kind: str
    part: str
    start: int
    end: int
    remove_start: int
    remove_end: int
    value: str


def _name(expanded: str) -> tuple[str, str, str]:
    chunks = expanded.split("|")
    if len(chunks) == 1:
        return "", chunks[0], chunks[0]
    uri, local = chunks[:2]
    lexical = f"{chunks[2]}:{local}" if len(chunks) == 3 else local
    return uri, local, lexical


def _tag_end(raw: bytes, start: int) -> int:
    quote = 0
    for index in range(start, len(raw)):
        value = raw[index]
        if quote:
            if value == quote:
                quote = 0
        elif value in (34, 39):
            quote = value
        elif value == 62:
            return index + 1
    raise WordTraceError("An XML tag is incomplete.")


def _xml_fields(part: str, raw: bytes, review: dict | None = None) -> tuple[list[Field], list[tuple[int, int]]]:
    # Byte patches are intentionally restricted to UTF-8. Refuse other encodings
    # instead of round-tripping a document through a lossy XML serializer.
    try:
        raw.decode("utf-8-sig")
    except UnicodeDecodeError as exc:
        raise WordTraceError(f"{part} uses an unsupported XML encoding; UTF-8 is required.") from exc
    if b"\x00" in raw:
        raise WordTraceError(f"{part} uses an unsupported XML encoding; UTF-8 is required.")
    parser = expat.ParserCreate(namespace_separator="|")
    parser.namespace_prefixes = True
    fields: list[Field] = []
    containers: list[tuple[int, int]] = []
    stack: list[tuple[str, str, int, int, bool]] = []

    def reject_doctype(*_args):
        raise WordTraceError("DOCX XML with a DTD or entity declaration is not supported.")

    def start(name, attrs):
        uri, local, _ = _name(name)
        begin = parser.CurrentByteIndex
        finish = _tag_end(raw, begin)
        stack.append((uri, local, begin, finish, raw[begin:finish].rstrip().endswith(b"/>")))
        spans = {match[1].decode("utf-8"): match for match in _ATTRIBUTE.finditer(raw, begin, finish)}
        if review is not None and uri in W_NAMESPACES and (local in REVISION_KINDS or local in {"moveTo", "comment"}):
            if local in REVISION_KINDS:
                review[REVISION_KINDS[local]] += 1
            elif local == "comment":
                review["comments"] += 1
            author = next((value for expanded, value in attrs.items() if _name(expanded)[0] in W_NAMESPACES and _name(expanded)[1] == "author"), "").strip()
            if author:
                review["commentAuthors" if local == "comment" else "changeAuthors"].add(author)
        for expanded, value in attrs.items():
            attr_uri, attr_local, lexical = _name(expanded)
            kind = None
            if uri in W_NAMESPACES and attr_uri in W_NAMESPACES:
                if attr_local in RSID_NAMES or (local in {"rsid", "rsidRoot"} and attr_local == "val"):
                    kind = "rsid"
                elif attr_local == "date":
                    kind = "annotationDate"
            if attr_local == "dateUtc" and attr_uri.startswith("http://schemas.microsoft.com/office/word/"):
                kind = "annotationDate"
            if kind:
                match = spans.get(lexical)
                if match is None:
                    raise WordTraceError(f"Cannot locate an XML metadata attribute in {part}.")
                fields.append(Field(kind, part, match.start(3), match.end(3), match.start(), match.end(), value))
        if len(fields) > MAX_FIELDS or len(stack) > 512:
            raise WordTraceError("The document exceeds the editing-metadata complexity limit.")

    def end(_name_value):
        uri, local, begin, content_start, self_closed = stack.pop()
        content_end = content_start if self_closed else parser.CurrentByteIndex
        finish = content_start if self_closed else _tag_end(raw, content_end)
        if uri in W_NAMESPACES and local == "rsids":
            containers.append((begin, finish))
        is_date = (uri == DCTERMS and local in {"created", "modified"}) or (uri in CORE_NAMESPACES and local == "lastPrinted")
        if part.startswith("docProps/") and is_date:
            value = raw[content_start:content_end].decode("utf-8").strip()
            fields.append(Field("documentDate", part, content_start, content_end, begin, finish, value))

    parser.StartElementHandler = start
    parser.EndElementHandler = end
    parser.StartDoctypeDeclHandler = reject_doctype
    parser.EntityDeclHandler = reject_doctype
    parser.ExternalEntityRefHandler = reject_doctype
    try:
        parser.Parse(raw, True)
    except expat.ExpatError as exc:
        raise WordTraceError(f"Cannot read {part}: malformed XML.") from exc
    return fields, containers


def parse_date(value: str) -> datetime:
    # An offset is required for dates chosen in the UI. Legacy Word annotations
    # without an offset are interpreted as UTC consistently, and reported.
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?", value):
        raise ValueError("Expected an ISO 8601 date and time")
    result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return result.replace(tzinfo=result.tzinfo or timezone.utc).astimezone(timezone.utc)


def validate_options(options: dict) -> dict:
    if type(options) is not dict or set(options) - {"rsids", "dates", "start", "end", "resetArchiveDates"}:
        raise WordTraceError("Unsupported Word editing-trace options.")
    result = {"rsids": "randomize", "dates": "keep", "start": "", "end": "", "resetArchiveDates": False, **options}
    for key in ("rsids", "dates"):
        if type(result[key]) is not str or result[key] not in {"keep", "randomize", "remove"}:
            raise WordTraceError(f"Word {key} must be keep, randomize, or remove.")
    if type(result["resetArchiveDates"]) is not bool:
        raise WordTraceError("resetArchiveDates must be a boolean.")
    if type(result["start"]) is not str or type(result["end"]) is not str:
        raise WordTraceError("The date range must contain ISO 8601 strings.")
    if result["dates"] == "randomize":
        try:
            first, last = parse_date(result["start"]), parse_date(result["end"])
            if first >= last or first.year < 1900 or last.year > 2100:
                raise ValueError()
            if not all(re.search(r"(?:Z|[+-]\d{2}:\d{2})$", result[key]) for key in ("start", "end")):
                raise ValueError()
        except (ValueError, OverflowError) as exc:
            raise WordTraceError("Choose a start before the end, between 1900 and 2100, with a time zone.") from exc
    return result


def _read_package(data: bytes):
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            infos = archive.infolist()
            names = [info.filename for info in infos]
            if len(infos) > MAX_PARTS or len(set(names)) != len(names):
                raise WordTraceError("The DOCX contains too many or duplicate package parts.")
            if "word/document.xml" not in names or "[Content_Types].xml" not in names:
                raise WordTraceError("This file is not a supported DOCX package.")
            parts = []
            fields = []
            containers = {}
            review = {"insertions": 0, "deletions": 0, "moves": 0, "formattingChanges": 0, "comments": 0,
                      "changeAuthors": set(), "commentAuthors": set()}
            budget = MAX_EXPANDED_BYTES
            for info in infos:
                if info.flag_bits & 1:
                    raise WordTraceError("Encrypted DOCX packages are not supported.")
                if info.file_size > budget:
                    raise WordTraceError("DOCX expanded data exceeds the 128 MiB limit.")
                with archive.open(info) as entry:
                    raw = entry.read(budget + 1)
                budget -= len(raw)
                if budget < 0:
                    raise WordTraceError("DOCX expanded data exceeds the 128 MiB limit.")
                parts.append((info, raw))
                if info.filename.endswith(".xml") and info.filename.startswith(("word/", "docProps/")):
                    found, ranges = _xml_fields(info.filename, raw, review if info.filename.startswith("word/") else None)
                    fields.extend(found)
                    containers[info.filename] = ranges
                    if len(fields) > MAX_FIELDS:
                        raise WordTraceError("The document exceeds the editing-metadata complexity limit.")
            return parts, fields, containers, archive.comment, review
    except (zipfile.BadZipFile, RuntimeError, NotImplementedError) as exc:
        raise WordTraceError("The DOCX package is damaged, encrypted, or unsupported.") from exc


def _review_summary(review) -> dict:
    result = {}
    for key, value in review.items():
        if isinstance(value, set):
            names = sorted(value, key=str.casefold)
            result[key] = names[:MAX_AUTHORS]
            result[key[:-1] + "Count"] = len(names)
        else:
            result[key] = value
    return result


def _summary(parts, fields, review) -> dict:
    dates = [field for field in fields if field.kind != "rsid"]
    parsed = []
    invalid = 0
    unzoned = 0
    for field in dates:
        try:
            parsed.append(parse_date(field.value))
            unzoned += not bool(re.search(r"(?:Z|[+-]\d{2}:\d{2})$", field.value))
        except (ValueError, OverflowError):
            invalid += 1
    identifiers = [field.value.upper() for field in fields if field.kind == "rsid"]
    return {
        "rsidReferences": len(identifiers), "sessionIDs": len(set(identifiers)),
        "annotationDates": sum(field.kind == "annotationDate" for field in dates),
        "documentDates": sum(field.kind == "documentDate" for field in dates),
        "invalidDates": invalid, "datesWithoutTimezone": unzoned,
        "earliest": min(parsed).isoformat().replace("+00:00", "Z") if parsed else None,
        "latest": max(parsed).isoformat().replace("+00:00", "Z") if parsed else None,
        "archiveEntries": len(parts),
        **_review_summary(review),
        "signed": any(info.filename.lower().startswith("_xmlsignatures/") or (info.filename == "[Content_Types].xml" and b"digital-signature" in raw) for info, raw in parts),
    }


def inspect(data: bytes) -> dict:
    try:
        parts, fields, _, _, review = _read_package(data)
        return {"available": True, **_summary(parts, fields, review)}
    except (WordTraceError, ValueError) as exc:
        return {"available": False, "reason": str(exc)}


def rewrite(data: bytes, options: dict) -> tuple[bytes, dict]:
    options = validate_options(options)
    parts, fields, containers, comment, review = _read_package(data)
    before = _summary(parts, fields, review)
    if before["signed"]:
        raise WordTraceError("This DOCX has a digital signature. Editing traces would invalidate it; use an unsigned copy.")
    identifier_set = {field.value.upper() for field in fields if field.kind == "rsid"}
    identifiers = sorted(identifier_set)
    rsid_map = {}
    if options["rsids"] == "randomize":
        if any(not re.fullmatch(r"[0-9A-F]{8}", value) for value in identifiers):
            raise WordTraceError("A session identifier is malformed. Choose Remove or Keep for session IDs.")
        values = set()
        while len(values) < len(identifiers):
            value = f"{secrets.randbelow(0xFFFFFFFE) + 1:08X}"
            if value not in identifier_set:
                values.add(value)
        rsid_map = dict(zip(identifiers, sorted(values)))
    date_map = {}
    if options["dates"] == "randomize":
        if before["invalidDates"]:
            raise WordTraceError("A recorded date is malformed or empty. Choose Remove or Keep for dates.")
        originals = sorted({parse_date(field.value) for field in fields if field.kind != "rsid"})
        first = math.ceil(parse_date(options["start"]).timestamp())
        last = math.floor(parse_date(options["end"]).timestamp())
        # Sample without replacement in O(n), even for very narrow ranges.
        if last - first + 1 < len(originals):
            raise WordTraceError("Choose a wider date range to preserve the order of distinct timestamps.")
        chosen = set()
        for upper in range(last - first + 1 - len(originals), last - first + 1):
            candidate = secrets.randbelow(upper + 1)
            chosen.add(upper if candidate in chosen else candidate)
        date_map = {old: datetime.fromtimestamp(first + offset, timezone.utc).isoformat().replace("+00:00", "Z") for old, offset in zip(originals, sorted(chosen))}
    fields_by_part = {}
    for field in fields:
        fields_by_part.setdefault(field.part, []).append(field)
    changes = []
    changed_fields = 0
    changed_parts = 0
    reset_entries = 0
    destination = io.BytesIO()
    with zipfile.ZipFile(destination, "w") as output:
        output.comment = comment
        for info, raw in parts:
            patches = []
            removals = containers.get(info.filename, []) if options["rsids"] == "remove" else []
            patches.extend((start, end, b"") for start, end in removals)
            for field in fields_by_part.get(info.filename, []):
                mode = options["rsids"] if field.kind == "rsid" else options["dates"]
                if mode == "keep":
                    continue
                if mode == "remove":
                    if not any(start <= field.start < end for start, end in removals):
                        patches.append((field.remove_start, field.remove_end, b""))
                    replacement = None
                else:
                    replacement = rsid_map[field.value.upper()] if field.kind == "rsid" else date_map[parse_date(field.value)]
                    patches.append((field.start, field.end, replacement.encode("ascii")))
                changed_fields += 1
                if len(changes) < 200:
                    changes.append({"part": field.part, "kind": field.kind, "before": field.value, "after": replacement})
            if patches:
                chunks = []
                cursor = 0
                for start, end, replacement in sorted(patches):
                    if start < cursor:
                        raise WordTraceError("Overlapping metadata fields cannot be rewritten safely.")
                    chunks.extend((raw[cursor:start], replacement))
                    cursor = end
                chunks.append(raw[cursor:])
                raw = b"".join(chunks)
            if patches:
                changed_parts += 1
                _xml_fields(info.filename, raw)  # validate every edited XML part
            if options["resetArchiveDates"]:
                info.date_time = (1980, 1, 1, 0, 0, 0)
                # Extended timestamp / NTFS extras can otherwise retain dates.
                extra = info.extra
                kept_extra = bytearray()
                offset = 0
                while offset + 4 <= len(extra):
                    kind = int.from_bytes(extra[offset:offset + 2], "little")
                    size = int.from_bytes(extra[offset + 2:offset + 4], "little")
                    end = offset + 4 + size
                    if end > len(extra):
                        raise WordTraceError("Malformed ZIP extra metadata.")
                    if kind not in {0x5455, 0x000A, 0x5855, 0x000D}:
                        kept_extra.extend(extra[offset:end])
                    offset = end
                if offset != len(extra):
                    raise WordTraceError("Malformed ZIP extra metadata.")
                info.extra = bytes(kept_extra)
                reset_entries += 1
            output.writestr(info, raw)
    cleaned = destination.getvalue() if changed_fields or reset_entries else data
    return cleaned, {
        "before": before, "after": inspect(cleaned), "options": options,
        "changedFields": changed_fields, "changedParts": changed_parts,
        "archiveDatesReset": reset_entries, "changes": changes,
        "changesTruncated": changed_fields > len(changes),
    }
