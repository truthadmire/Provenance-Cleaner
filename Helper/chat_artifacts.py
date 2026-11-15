"""Leftovers of copying from an AI chat: link tracking, citation markers, page attributes.

Text pasted or exported from a chat assistant carries marks that have nothing
to do with its wording:
- links tagged `utm_source=chatgpt.com` (and the same for a few other assistants);
- citation markers: `citeturn0search0` between private-use delimiters,
  `【4†source】`, and `:contentReference[oaicite:0]{index=0}`;
- in copied HTML, the chat page's own attributes (`data-start`, `data-end`,
  `data-message-id`...).

They are found and removed in plain text, Markdown, HTML, CSV and JSON, in the
XML parts of DOCX, XLSX, PPTX, ODT and EPUB, and in a PDF's link targets
(through pdf_traces). A marker split across two formatting runs in a document,
and a marker drawn as text on a PDF page, are not found.
"""
from __future__ import annotations

import io
import re
import zipfile
from typing import Any

TEXT_SUFFIXES = frozenset({".txt", ".text", ".md", ".markdown", ".mdx", ".html", ".htm", ".csv", ".json"})
HTML_SUFFIXES = frozenset({".html", ".htm"})
ARCHIVE_PARTS = {
    ".docx": (".xml", ".rels"), ".xlsx": (".xml", ".rels"), ".pptx": (".xml", ".rels"),
    ".odt": (".xml",), ".epub": (".xhtml", ".html", ".htm", ".opf", ".ncx"),
}
MAX_PART_BYTES = 64 << 20

_SOURCES = r"(?:chatgpt\.com|chat\.openai\.com|openai\.com|openai|perplexity\.ai|perplexity|copilot\.com|claude\.ai|gemini\.google\.com)"
# In XML and HTML the separator is written &amp;.
_TRACKING = re.compile(r"(\?|&amp;|&)utm_source=" + _SOURCES + r"(?![\w.-])(&amp;|&)?", re.I)
# None of these cross a tag, so removing one never breaks XML or HTML.
# A marker takes the one space before it along, so "a fact 【4†source】." reads "a fact."
_CITATIONS = re.compile(
    "[ \\t]?(?:"
    "\\ue200[^\\ue200\\ue201<>]{0,2000}\\ue201"
    "|(?<![A-Za-z])cite(?:\\ue202?turn\\d+[a-z]+\\d+)+"
    "|【\\d+(?::\\d+)?†[^】<>\\n]{0,80}】"
    "|:contentReference\\[oaicite:\\d+\\]\\{index=\\d+\\}"
    ")"
)
_ATTRIBUTES = re.compile(
    r"""\s+data-(?:start|end)=["']\d+["']"""
    r"""|\s+data-(?:message-id|message-author-role|message-model-slug|turn-id|is-last-node|is-only-node)=(?:"[^"<>]*"|'[^'<>]*')"""
)


def _drop_tracking(match: re.Match[str]) -> str:
    lead, trail = match.group(1), match.group(2)
    if lead == "?":
        return "?" if trail else ""
    return trail or ""


def clean_text(text: str, *, html: bool = False) -> tuple[str, dict[str, int]]:
    """*text* without chat leftovers, and how many of each kind were removed."""
    text, links = _TRACKING.subn(_drop_tracking, text)
    text, citations = _CITATIONS.subn("", text)
    attributes = 0
    if html:
        text, attributes = _ATTRIBUTES.subn("", text)
    return text, {"links": links, "citations": citations, "attributes": attributes}


def strip_link_tracking(url: str) -> tuple[str, int]:
    return _TRACKING.subn(_drop_tracking, url)


def _add(total: dict[str, int], counts: dict[str, int]) -> None:
    for key, value in counts.items():
        total[key] = total.get(key, 0) + value


def _decode(data: bytes) -> str | None:
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return None


def _archive(data: bytes, endings: tuple[str, ...]) -> tuple[bytes, dict[str, int]]:
    total = {"links": 0, "citations": 0, "attributes": 0}
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            entries = [(info, archive.read(info)) for info in archive.infolist()
                       if info.file_size <= MAX_PART_BYTES or not info.filename.lower().endswith(endings)]
            if len(entries) != len(archive.infolist()):
                return data, total
            comment = archive.comment
    except (zipfile.BadZipFile, RuntimeError, NotImplementedError, OSError):
        return data, total
    replacements: dict[str, bytes] = {}
    for info, raw in entries:
        if not info.filename.lower().endswith(endings):
            continue
        text = _decode(raw)
        if text is None:
            continue
        cleaned, counts = clean_text(text, html=info.filename.lower().endswith((".xhtml", ".html", ".htm")))
        if cleaned != text:
            replacements[info.filename] = cleaned.encode("utf-8")
            _add(total, counts)
    if not replacements:
        return data, total
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as rebuilt:
        rebuilt.comment = comment
        for info, raw in entries:
            # Reusing the ZipInfo keeps order, timestamps and compression.
            rebuilt.writestr(info, replacements.get(info.filename, raw))
    return output.getvalue(), total


def clean(data: bytes, suffix: str) -> tuple[bytes, dict[str, int]]:
    """*data* without chat leftovers. PDFs are handled in pdf_traces.normalize."""
    none = {"links": 0, "citations": 0, "attributes": 0}
    if suffix in TEXT_SUFFIXES:
        text = _decode(data)
        if text is None:
            return data, none
        cleaned, counts = clean_text(text, html=suffix in HTML_SUFFIXES)
        return (cleaned.encode("utf-8"), counts) if cleaned != text else (data, none)
    if suffix in ARCHIVE_PARTS:
        return _archive(data, ARCHIVE_PARTS[suffix])
    return data, none


def count(data: bytes, suffix: str) -> dict[str, int]:
    """How many chat leftovers *data* holds."""
    if suffix == ".pdf":
        text = data.decode("latin-1")
        return {"links": len(_TRACKING.findall(text)), "citations": 0, "attributes": 0}
    return clean(data, suffix)[1]


def _plural(n: int) -> str:
    return "" if n == 1 else "s"


def findings(counts: dict[str, int]) -> list[str]:
    result = []
    if counts.get("links"):
        result.append(f"AI chat link tracking (utm_source) in {counts['links']} link{_plural(counts['links'])}")
    if counts.get("citations"):
        result.append(f"AI chat citation markers: {counts['citations']}")
    if counts.get("attributes"):
        result.append(f"AI chat page attributes (data-start, data-end and similar): {counts['attributes']}")
    return result


def actions(counts: dict[str, int]) -> list[str]:
    result = []
    if counts.get("links"):
        result.append(f"Removed AI chat link tracking from {counts['links']} link{_plural(counts['links'])}")
    if counts.get("citations"):
        result.append(f"Removed {counts['citations']} AI chat citation marker{_plural(counts['citations'])}")
    if counts.get("attributes"):
        result.append(f"Removed {counts['attributes']} AI chat page attribute{_plural(counts['attributes'])}")
    return result


def present(report: dict[str, Any], counts: dict[str, int]) -> None:
    """Add chat-leftover findings to an inspection report."""
    sentences = findings(counts)
    if not sentences:
        return
    existing = report.setdefault("findings", [])
    confidences = report.setdefault("findings_confidence", ["probable"] * len(existing))
    existing.extend(sentences)
    confidences.extend(["probable"] * len(sentences))
    report["suspicious"] = True
