"""Corrections applied to reports and output from the pinned upstream engine.

The vendored engine is locked by checksum, so its defects are corrected here,
after it runs, rather than by editing it.
"""
from __future__ import annotations

import io
import re
import zipfile
from typing import Any, Callable

import image_meta

OFFICE_SUFFIXES = frozenset({".docx", ".xlsx", ".pptx"})

# --- Office preview images -------------------------------------------------
#
# The engine rewrites every docProps/ part as UTF-8 text, which destroys binary
# parts such as docProps/thumbnail.jpeg. Those parts are rebuilt from the
# original: metadata is stripped the way the engine strips embedded media, or
# the part is dropped with its relationship and content-type entry when it
# can't be stripped. Corrupted bytes are never kept.

_STRIPPERS: dict[str, Callable[[bytes], tuple[bytes, list[str]]]] = {
    "jpeg": lambda data: image_meta.strip_jpeg(data, strip_all_app=True),
    "png": lambda data: image_meta.strip_png(data, strip_all_text=True),
    "webp": lambda data: image_meta.strip_webp(data, strip_all_metadata=True),
    "tiff": lambda data: image_meta.strip_tiff(data, strip_all_metadata=True),
    "gif": lambda data: image_meta.strip_gif(data, strip_all_metadata=True),
    "bmp": lambda data: image_meta.strip_bmp(data, strip_all_metadata=True),
}
_PROVENANCE_MARKERS = (b"c2pa", b"jumb", b"contentauth")


def _is_binary_docprops_part(name: str) -> bool:
    return name.startswith("docProps/") and not name.lower().endswith(".xml")


def _remove_part_references(name: str, rels: bytes, content_types: bytes) -> tuple[bytes, bytes]:
    target = re.escape(name)
    rels = re.sub(
        rb'<Relationship\b[^>]*\bTarget="/?' + target.encode() + rb'"[^>]*/>',
        b"",
        rels,
    )
    content_types = re.sub(
        rb'<Override\b[^>]*\bPartName="/' + target.encode() + rb'"[^>]*/>',
        b"",
        content_types,
    )
    return rels, content_types


def repair_office_preview_parts(
    original: bytes, cleaned: bytes
) -> tuple[bytes, list[str], list[str], list[str]]:
    """Return (output, actions, residual findings, rebuilt part names)."""

    with zipfile.ZipFile(io.BytesIO(original)) as source:
        parts = {
            info.filename: source.read(info)
            for info in source.infolist()
            if _is_binary_docprops_part(info.filename)
        }
    if not parts:
        return cleaned, [], [], []

    replacements: dict[str, bytes] = {}
    dropped: set[str] = set()
    actions: list[str] = []
    residual: list[str] = []
    for name, raw in sorted(parts.items()):
        stripper = _STRIPPERS.get(image_meta.detect_format(raw))
        try:
            if stripper is None:
                raise ValueError("unsupported preview image format")
            stripped, _ = stripper(raw)
        except Exception:  # malformed or unsupported: drop rather than keep unverified bytes
            dropped.add(name)
            actions.append(f"Preview image {name} removed: its metadata couldn't be cleaned.")
            continue
        replacements[name] = stripped
        actions.append(f"Preview image {name} kept; its metadata was removed.")
        lowered = stripped.lower()
        if any(marker in lowered for marker in _PROVENANCE_MARKERS):
            residual.append(f"{name}: provenance markers remain in the preview image.")

    output = io.BytesIO()
    with zipfile.ZipFile(io.BytesIO(cleaned)) as archive, zipfile.ZipFile(output, "w") as rebuilt:
        entries = [(info, archive.read(info)) for info in archive.infolist()]
        rels = next((data for info, data in entries if info.filename == "_rels/.rels"), b"")
        content_types = next((data for info, data in entries if info.filename == "[Content_Types].xml"), b"")
        for name in sorted(dropped):
            rels, content_types = _remove_part_references(name, rels, content_types)
        for info, data in entries:
            name = info.filename
            if name in dropped:
                continue
            if name in replacements:
                data = replacements[name]
            elif dropped and name == "_rels/.rels":
                data = rels
            elif dropped and name == "[Content_Types].xml":
                data = content_types
            # Reusing the ZipInfo keeps order, timestamps and compression.
            rebuilt.writestr(info, data)
    return output.getvalue(), actions, residual, sorted(parts)


def drop_findings_for_parts(findings: list[Any], names: list[str]) -> list[Any]:
    """Remove the engine's post-clean findings about parts that were rebuilt."""

    prefixes = tuple(f"{name}:" for name in names)
    return [item for item in findings if not (isinstance(item, str) and item.startswith(prefixes))]


# --- Out-of-scope report content -------------------------------------------
#
# The engine adds an AI-authorship (stylometry) score to text reports and
# SynthID/pixel keys to image reports, and its notes point at command-line
# rewrite options. None of that is in this app's deterministic scope, so it is
# removed, and a "suspicious" flag derived from the score is recomputed.

OUT_OF_SCOPE_KEYS = ("stylometry", "text_detectors", "synthid", "synthid_before", "synthid_after", "pixel_removal")

_NOTE_REWRITES: tuple[tuple[re.Pattern[str], str | None], ...] = (
    (re.compile(r"^Layer A only: invisible/format Unicode"),
     "Text is checked for invisible and look-alike Unicode characters."),
    (re.compile(r"^Statistical \(token-sampling\) watermarks are not detectable here"),
     "Statistical watermarks carried by word choice can't be detected or removed by this app."),
    (re.compile(r"^Inspect kinds:"), None),
    (re.compile(r"^No deterministic Layer A \(invisible Unicode/format\) carriers detected"),
     "No invisible or look-alike characters were found. Statistical and image-pixel watermarks "
     "are outside what this app checks."),
    (re.compile(r"^Load-bearing invisibles are preserved by default during cleaning"),
     "Invisible characters that scripts and emoji need, such as joiners and variation "
     "selectors, are kept when cleaning. Bidirectional controls are still reported."),
)
_LAYER_A_COUNT = re.compile(r"^layer A: (\d+) invisible/format codepoint\(s\) in body text; clean removes these$")
_PDF_BEST_EFFORT = "PDF inspection is best-effort; exiftool/c2patool give more reliable metadata detection"


def _rewrite_note(note: Any, report: dict[str, Any]) -> Any:
    if not isinstance(note, str):
        return note
    for pattern, replacement in _NOTE_REWRITES:
        if pattern.search(note):
            return replacement
    count = _LAYER_A_COUNT.match(note)
    if count:
        n = int(count.group(1))
        return f"{n} invisible or format character{'' if n == 1 else 's'} in the body text; cleaning removes {'it' if n == 1 else 'them'}."
    if note.startswith(_PDF_BEST_EFFORT):
        tools = report.get("tools") if isinstance(report.get("tools"), dict) else {}
        ran = all(
            isinstance(tools.get(name), dict) and tools[name].get("available") is not False
            for name in ("exiftool", "c2patool")
        )
        if ran:
            return ("PDF checks are best-effort: document metadata is read with ExifTool, content "
                    "credentials with c2patool, and images inside the PDF get a byte-level scan.")
    # Unknown notes pass through: they may carry the wording that marks a check incomplete.
    return note


def present_report(report: dict[str, Any], *, inspection: bool) -> dict[str, Any]:
    had_score = "stylometry" in report
    for container in (report, report.get("meta")):
        if isinstance(container, dict):
            for key in OUT_OF_SCOPE_KEYS:
                container.pop(key, None)
    notes = report.get("notes")
    if isinstance(notes, list):
        rewritten = [_rewrite_note(note, report) for note in notes]
        report["notes"] = [note for note in rewritten if note is not None]
    if inspection and had_score:
        report["suspicious"] = bool(
            report.get("suspicious_total") or report.get("has_c2pa") or report.get("has_ai_metadata")
        )
    return report
