"""Pull a file's text apart by whether a reader would actually see it.

An AI assistant reading a document sees text a person doesn't: hidden Word runs,
white PDF text, HTML comments, metadata. Each piece of text keeps its location
and one of three channels:

- visible: on the page for a person to read.
- side: not on the page, but with an ordinary purpose (comments, alt text,
  metadata). Only suspicious content in it matters.
- hidden: kept out of a reader's sight. Its presence alone is worth reporting.
"""
from __future__ import annotations

import io
import math
import re
import shutil
import subprocess
import tempfile
import zipfile
from dataclasses import dataclass, field, replace
from html.parser import HTMLParser
from pathlib import Path
from typing import Any
from xml.etree import ElementTree as ET

import metadata_editor
import pdf_traces
import word_editing_traces

VISIBLE, SIDE, HIDDEN = "visible", "side", "hidden"

TEXT_SUFFIXES = {"txt", "text", "css", "js", "py", "rs", "go", "json", "yaml", "yml", "toml", "csv"}
MARKDOWN_SUFFIXES = {"md", "markdown", "mdx"}
GHOSTSCRIPT_TIMEOUT = 120
_NOT_IN_TAGS = ("System:", "File:", "ExifTool:", "Composite:")
_PDF_MAX_OPERATIONS = 5_000_000
_PDF_MAX_FORM_DEPTH = 6


class ExtractError(ValueError):
    pass


@dataclass
class Piece:
    channel: str
    location: str
    text: str
    reason: str = ""
    # An OCR layer: invisible by design, repeating what a scanned page shows.
    ocr: bool = False


@dataclass
class Extraction:
    pieces: list[Piece] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)
    # Markup source, for link checks that the extracted text no longer shows.
    sources: list[str] = field(default_factory=list)

    def add(self, channel: str, location: str, text: str, reason: str = "", ocr: bool = False) -> None:
        if text and text.strip():
            self.pieces.append(Piece(channel, location, text.strip(), reason, ocr))


def decode_text(data: bytes) -> str:
    if data.startswith(b"\xef\xbb\xbf"):
        return data[3:].decode("utf-8", "replace")
    if data.startswith((b"\xff\xfe", b"\xfe\xff")):
        return data.decode("utf-16", "replace")
    for encoding in ("utf-8", "gb18030"):
        try:
            return data.decode(encoding)
        except UnicodeDecodeError:
            continue
    return data.decode("latin-1")


# --- HTML, Markdown and SVG -------------------------------------------------------

_HIDING_CSS = re.compile(
    r"display\s*:\s*none|visibility\s*:\s*(?:hidden|collapse)|opacity\s*:\s*0(?:\.0+)?(?![.\d])"
    r"|font-size\s*:\s*0(?:\.\d+)?(?:px|pt|em|rem|%)?(?![.\d])"
    r"|(?:left|top|text-indent|margin-left)\s*:\s*-\d{3,}",
    re.I,
)
_WHITE_CSS = re.compile(r"(?<![-\w])color\s*:\s*(?:white|transparent|#fff(?:fff)?\b)", re.I)
_BACKGROUND_CSS = re.compile(r"background", re.I)
_CSS_RULE = re.compile(r"([^{}]+)\{([^{}]*)\}")
_CSS_SELECTOR = re.compile(r"^\s*(?:[\w-]*)?([.#])([\w-]+)\s*$")
_STYLE_BLOCK = re.compile(r"<style\b[^>]*>(.*?)</style\s*>", re.I | re.S)
_MARKDOWN_COMMENT = re.compile(r"^\s*\[[^\]]*\]:\s*(?:#|<>)\s*[(\"'](.*?)[)\"']\s*$", re.M)
_BLOCK_TAGS = {"p", "div", "br", "li", "tr", "td", "th", "h1", "h2", "h3", "h4", "h5", "h6", "section", "article", "text", "tspan"}
_IMPLICIT_CLOSE = {"p", "li", "tr", "td", "th", "option", "dt", "dd"}
_VOID_TAGS = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}
_SIDE_TAGS = {"title": "Title", "desc": "Description", "metadata": "Embedded metadata", "script": "Script",
              "noscript": "No-script content", "template": "Template"}
_SIDE_ATTRIBUTES = {"alt": "Alt text", "title": "Tooltip", "aria-label": "Accessibility label",
                    "placeholder": "Placeholder", "content": "Meta tag", "data-prompt": "Data attribute"}


def _hiding_classes(css: str) -> dict[str, str]:
    """Selectors whose rule hides text, as ".name" or "#name"."""
    found = {}
    for selectors, body in _CSS_RULE.findall(css):
        reason = _css_reason(body)
        if reason:
            for selector in selectors.split(","):
                match = _CSS_SELECTOR.match(selector)
                if match:
                    found[match[1] + match[2]] = reason
    return found


def _css_reason(style: str) -> str:
    if _HIDING_CSS.search(style):
        return "hidden with CSS"
    if _WHITE_CSS.search(style) and not _BACKGROUND_CSS.search(style):
        return "white or transparent text"
    return ""


class _Markup(HTMLParser):
    def __init__(self, label: str, css: str = ""):
        super().__init__(convert_charrefs=True)
        self.label = label
        self.hiding = _hiding_classes(css)
        self.stack: list[tuple[str, str, str]] = []
        self.chunks: dict[tuple[str, str, str], list[str]] = {}

    def _note(self, channel: str, location: str, text: str, reason: str = "") -> None:
        self.chunks.setdefault((channel, location, reason), []).append(text)

    def _attribute_reason(self, attrs: dict[str, str | None]) -> str:
        if "hidden" in attrs or attrs.get("aria-hidden") == "true":
            return "marked hidden"
        if attrs.get("display") == "none" or attrs.get("visibility") == "hidden":
            return "hidden with an attribute"
        if attrs.get("opacity") in ("0", "0.0") or attrs.get("fill-opacity") in ("0", "0.0") or attrs.get("font-size") == "0":
            return "hidden with an attribute"
        if attrs.get("type") == "hidden":
            return "hidden field"
        reason = _css_reason(attrs.get("style") or "")
        if reason:
            return reason
        names = [f".{name}" for name in (attrs.get("class") or "").split()]
        if attrs.get("id"):
            names.append(f"#{attrs['id']}")
        return next((self.hiding[name] for name in names if name in self.hiding), "")

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        reason = self._attribute_reason(values)
        inherited = next((entry[1] for entry in reversed(self.stack) if entry[1]), "")
        for name, label in _SIDE_ATTRIBUTES.items():
            if values.get(name):
                self._note(SIDE, f"{self.label}: {label}", values[name] + "\n")
        if values.get("type") == "hidden" and values.get("value"):
            self._note(HIDDEN, self.label, values["value"] + "\n", "hidden field")
        if tag in _BLOCK_TAGS:
            self._break()
        # These close implicitly, so unclosed ones mustn't pile up on the stack.
        if tag in _IMPLICIT_CLOSE and self.stack and self.stack[-1][0] == tag:
            self.stack.pop()
        if tag not in _VOID_TAGS:
            self.stack.append((tag, reason or inherited, _SIDE_TAGS.get(tag, "")))

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in _VOID_TAGS and self.stack and self.stack[-1][0] == tag:
            self.stack.pop()

    def handle_endtag(self, tag):
        for index in range(len(self.stack) - 1, -1, -1):
            if self.stack[index][0] == tag:
                del self.stack[index:]
                break
        if tag in _BLOCK_TAGS:
            self._break()

    def _break(self) -> None:
        for chunk in self.chunks.values():
            if chunk and chunk[-1] != "\n":
                chunk.append("\n")

    def handle_data(self, data):
        if any(entry[0] == "style" for entry in self.stack):
            return
        reason = next((entry[1] for entry in reversed(self.stack) if entry[1]), "")
        side = next((entry[2] for entry in reversed(self.stack) if entry[2]), "")
        if reason:
            self._note(HIDDEN, self.label, data, reason)
        elif side:
            self._note(SIDE, f"{self.label}: {side}", data)
        else:
            self._note(VISIBLE, self.label, data)

    def handle_comment(self, data):
        self._note(SIDE, f"{self.label}: comment", data + "\n")


def _markup(result: Extraction, source: str, label: str, css: str = "") -> None:
    css = css + "\n" + "\n".join(_STYLE_BLOCK.findall(source))
    parser = _Markup(label, css)
    parser.feed(source)
    parser.close()
    for (channel, location, reason), chunks in parser.chunks.items():
        result.add(channel, location, "".join(chunks), reason)
    result.sources.append(source)


# --- Office packages --------------------------------------------------------------

def _zip_parts(data: bytes) -> dict[str, bytes]:
    """Every part, under the limits the Word trace reader applies."""
    budget = word_editing_traces.MAX_EXPANDED_BYTES
    parts = {}
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            infos = archive.infolist()
            if len(infos) > word_editing_traces.MAX_PARTS:
                raise ExtractError("The package has too many parts to check.")
            for info in infos:
                if info.flag_bits & 1:
                    raise ExtractError("The package is encrypted, so its text can't be checked.")
                if info.is_dir():
                    continue
                if info.file_size > budget:
                    raise ExtractError("The package's expanded data exceeds the 128 MiB limit.")
                with archive.open(info) as entry:
                    raw = entry.read(budget + 1)
                budget -= len(raw)
                if budget < 0:
                    raise ExtractError("The package's expanded data exceeds the 128 MiB limit.")
                parts[info.filename] = raw
    except (zipfile.BadZipFile, RuntimeError, NotImplementedError) as exc:
        raise ExtractError("The package is damaged, encrypted or unsupported.") from exc
    return parts


def _xml(result: Extraction, name: str, raw: bytes) -> ET.Element | None:
    try:
        return metadata_editor._xml(raw)
    except metadata_editor.MetadataError:
        result.notes.append(f"{name} couldn't be read.")
        return None


def _local(element: ET.Element) -> str:
    return element.tag.rsplit("}", 1)[-1] if isinstance(element.tag, str) else ""


def _attr(element: ET.Element, name: str) -> str | None:
    """An attribute by local name, whatever its namespace."""
    for key, value in element.attrib.items():
        if key.rsplit("}", 1)[-1] == name:
            return value
    return None


def _child(element: ET.Element, name: str) -> ET.Element | None:
    return next((child for child in element if _local(child) == name), None)


def _natural(name: str) -> list:
    return [int(chunk) if chunk.isdigit() else chunk for chunk in re.split(r"(\d+)", name)]


def _is_white(value: str | None) -> bool:
    if not value or not re.fullmatch(r"[0-9A-Fa-f]{6}", value):
        return False
    return all(int(value[index:index + 2], 16) >= 0xF5 for index in (0, 2, 4))


def _is_shaded(value: str | None) -> bool:
    return bool(value) and value.lower() != "auto" and not _is_white(value)


def _properties_text(result: Extraction, parts: dict[str, bytes]) -> None:
    for name in sorted(parts):
        if name.startswith("docProps/") and name.endswith(".xml"):
            root = _xml(result, name, parts[name])
            for element in root.iter() if root is not None else ():
                if len(element) == 0 and element.text:
                    result.add(SIDE, f"Document property: {_local(element)}", element.text)


def _drawing_text(result: Extraction, element: ET.Element, location: str) -> None:
    for node in element.iter():
        if _local(node) in ("docPr", "cNvPr"):
            for name in ("descr", "title"):
                result.add(SIDE, f"{location}: alt text", _attr(node, name) or "")


def _media_note(result: Extraction, parts: dict[str, bytes]) -> None:
    if any("/media/" in name for name in parts):
        result.notes.append("Text inside images isn't read.")
    if any("/embeddings/" in name for name in parts):
        result.notes.append("Embedded files aren't checked.")


@dataclass(frozen=True)
class _RunStyle:
    hidden: bool = False
    white: bool = False
    tiny: bool = False
    shaded: bool = False


def _word_run_style(properties: ET.Element | None, base: _RunStyle) -> _RunStyle:
    if properties is None:
        return base
    style = base
    for child in properties:
        name, value = _local(child), _attr(child, "val")
        if name in ("vanish", "specVanish"):
            style = replace(style, hidden=value not in ("0", "false"))
        elif name == "color":
            style = replace(style, white=_is_white(value))
        elif name == "sz" and value and value.isdigit():
            style = replace(style, tiny=int(value) <= 4)  # half-points
        elif name in ("shd", "highlight"):
            fill = _attr(child, "fill") if name == "shd" else value
            if _is_shaded(fill) and fill not in ("white", "none", "clear"):
                style = replace(style, shaded=True)
    return style


def _word_styles(result: Extraction, parts: dict[str, bytes]) -> dict[str, _RunStyle]:
    raw = parts.get("word/styles.xml")
    root = _xml(result, "word/styles.xml", raw) if raw else None
    if root is None:
        return {}
    definitions = {}
    for style in root:
        if _local(style) == "style" and _attr(style, "styleId"):
            based_on = _child(style, "basedOn")
            definitions[_attr(style, "styleId")] = (_attr(based_on, "val") if based_on is not None else None, _child(style, "rPr"))
    resolved: dict[str, _RunStyle] = {}

    def resolve(name: str, depth: int = 0) -> _RunStyle:
        if name in resolved:
            return resolved[name]
        parent, properties = definitions.get(name, (None, None))
        base = resolve(parent, depth + 1) if parent and depth < 16 else _RunStyle()
        resolved[name] = _word_run_style(properties, base)
        return resolved[name]

    return {name: resolve(name) for name in definitions}


def _word_part(result: Extraction, root: ET.Element, location: str, channel: str, styles: dict[str, _RunStyle], dark_page: bool) -> None:
    chunks: dict[tuple[str, str, str], list[str]] = {}

    def emit(channel_name: str, where: str, text: str, reason: str = "") -> None:
        chunks.setdefault((channel_name, where, reason), []).append(text)

    def walk(element: ET.Element, base: _RunStyle, deleted: bool) -> None:
        name = _local(element)
        if name in ("del", "moveFrom"):
            deleted = True
        if name == "tc":
            properties = _child(element, "tcPr")
            shading = _child(properties, "shd") if properties is not None else None
            if shading is not None and _is_shaded(_attr(shading, "fill")):
                base = replace(base, shaded=True)
        if name == "p":
            properties = _child(element, "pPr")
            if properties is not None:
                style = _child(properties, "pStyle")
                if style is not None:
                    base = _merge_styles(base, styles.get(_attr(style, "val") or "", _RunStyle()))
                shading = _child(properties, "shd")
                if shading is not None and _is_shaded(_attr(shading, "fill")):
                    base = replace(base, shaded=True)
        if name == "r":
            properties = _child(element, "rPr")
            style = base
            if properties is not None:
                reference = _child(properties, "rStyle")
                if reference is not None:
                    style = _merge_styles(style, styles.get(_attr(reference, "val") or "", _RunStyle()))
            style = _word_run_style(properties, style)
            for child in element:
                child_name = _local(child)
                if child_name in ("t", "delText") and child.text:
                    if deleted or child_name == "delText":
                        emit(SIDE, f"{location}: deleted text", child.text)
                    elif style.hidden:
                        emit(HIDDEN, location, child.text, "hidden text in Word")
                    elif style.tiny:
                        emit(HIDDEN, location, child.text, "text of 2 pt or smaller")
                    elif style.white and not style.shaded and not dark_page:
                        emit(HIDDEN, location, child.text, "white text")
                    else:
                        emit(channel, location, child.text)
                elif child_name in ("tab", "br", "cr"):
                    emit(channel, location, " ")
        for child in element:
            if _local(child) != "rPr":
                walk(child, base, deleted)
        if name == "p":
            for chunk in chunks.values():
                if chunk and chunk[-1] != "\n":
                    chunk.append("\n")

    walk(root, _RunStyle(), False)
    for (channel_name, where, reason), chunk in chunks.items():
        result.add(channel_name, where, "".join(chunk), reason)
    _drawing_text(result, root, location)


def _merge_styles(base: _RunStyle, other: _RunStyle) -> _RunStyle:
    return _RunStyle(base.hidden or other.hidden, base.white or other.white, base.tiny or other.tiny, base.shaded or other.shaded)


def _docx(result: Extraction, data: bytes) -> None:
    parts = _zip_parts(data)
    styles = _word_styles(result, parts)
    document = parts.get("word/document.xml")
    if document is None:
        raise ExtractError("This file is not a supported DOCX package.")
    labels = [("word/document.xml", "Document body", VISIBLE), ("word/footnotes.xml", "Footnotes", VISIBLE),
              ("word/endnotes.xml", "Endnotes", VISIBLE), ("word/comments.xml", "Comments", SIDE)]
    labels += [(name, "Header" if "header" in name else "Footer", VISIBLE) for name in sorted(parts)
               if re.fullmatch(r"word/(?:header|footer)\d*\.xml", name)]
    dark_page = False
    for name, location, channel in labels:
        root = _xml(result, name, parts[name]) if name in parts else None
        if root is None:
            continue
        background = _child(root, "background") if name == "word/document.xml" else None
        if background is not None and _is_shaded(_attr(background, "color")):
            dark_page = True
        _word_part(result, root, location, channel, styles, dark_page)
    settings = _xml(result, "word/settings.xml", parts["word/settings.xml"]) if "word/settings.xml" in parts else None
    for node in settings.iter() if settings is not None else ():
        if _local(node) == "docVar":
            result.add(SIDE, "Document variable", _attr(node, "val") or "")
    for name in sorted(parts):
        if name.startswith("customXml/item") and name.endswith(".xml") and "/_rels/" not in name and "Props" not in name:
            root = _xml(result, name, parts[name])
            if root is not None:
                result.add(SIDE, "Custom XML", " ".join(text.strip() for text in root.itertext() if text.strip()))
    _properties_text(result, parts)
    _media_note(result, parts)


def _relationships(result: Extraction, parts: dict[str, bytes], name: str) -> dict[str, str]:
    raw = parts.get(name)
    root = _xml(result, name, raw) if raw else None
    if root is None:
        return {}
    return {node.get("Id"): node.get("Target", "") for node in root if node.get("Id")}


def _column_index(reference: str) -> int:
    index = 0
    for letter in re.match(r"[A-Za-z]*", reference)[0].upper():
        index = index * 26 + ord(letter) - 64
    return index


def _xlsx(result: Extraction, data: bytes) -> None:
    parts = _zip_parts(data)
    workbook = _xml(result, "xl/workbook.xml", parts["xl/workbook.xml"]) if "xl/workbook.xml" in parts else None
    if workbook is None:
        raise ExtractError("This file is not a supported XLSX package.")
    shared: list[str] = []
    raw_shared = parts.get("xl/sharedStrings.xml")
    root = _xml(result, "xl/sharedStrings.xml", raw_shared) if raw_shared else None
    for item in root if root is not None else ():
        shared.append("".join(node.text or "" for node in item.iter() if _local(node) == "t"))
    targets = _relationships(result, parts, "xl/_rels/workbook.xml.rels")
    sheets = next((node for node in workbook if _local(node) == "sheets"), [])
    for sheet in sheets:
        name = _attr(sheet, "name") or "Sheet"
        location = f"Sheet “{name}”"
        hidden_sheet = _attr(sheet, "state") in ("hidden", "veryHidden")
        result.add(SIDE, "Sheet name", name)
        target = targets.get(_attr(sheet, "id") or "", "")
        part = target.lstrip("/") if target.startswith("/") else f"xl/{target}"
        root = _xml(result, part, parts[part]) if part in parts else None
        if root is None:
            continue
        hidden_columns: list[tuple[int, int]] = []
        for node in root.iter():
            if _local(node) == "col" and _attr(node, "hidden") in ("1", "true"):
                hidden_columns.append((int(_attr(node, "min") or 0), int(_attr(node, "max") or 0)))
        visible, hidden_rows = [], []
        for row in root.iter():
            if _local(row) != "row":
                continue
            row_hidden = _attr(row, "hidden") in ("1", "true")
            for cell in row:
                if _local(cell) != "c":
                    continue
                kind = _attr(cell, "t")
                text = ""
                if kind == "s":
                    value = _child(cell, "v")
                    if value is not None and value.text and value.text.isdigit() and int(value.text) < len(shared):
                        text = shared[int(value.text)]
                elif kind == "inlineStr":
                    text = "".join(node.text or "" for node in cell.iter() if _local(node) == "t")
                elif kind == "str":
                    value = _child(cell, "v")
                    text = (value.text or "") if value is not None else ""
                if not text:
                    continue
                column = _column_index(_attr(cell, "r") or "")
                if row_hidden or any(first <= column <= last for first, last in hidden_columns):
                    hidden_rows.append(text)
                else:
                    visible.append(text)
        reason = "hidden sheet" if hidden_sheet else ""
        result.add(HIDDEN if hidden_sheet else VISIBLE, location, "\n".join(visible), reason)
        result.add(HIDDEN, location, "\n".join(hidden_rows), "hidden sheet" if hidden_sheet else "hidden row or column")
    for name in sorted(parts):
        if re.search(r"xl/(?:threadedComments/|comments)[^/]*\.xml$", name):
            root = _xml(result, name, parts[name])
            if root is not None:
                result.add(SIDE, "Cell comments", "\n".join(text.strip() for text in root.itertext() if text.strip()))
        elif name.startswith("xl/drawings/") and name.endswith(".xml") and "/_rels/" not in name:
            root = _xml(result, name, parts[name])
            if root is not None:
                result.add(SIDE, "Drawing text", " ".join(node.text or "" for node in root.iter() if _local(node) == "t"))
                _drawing_text(result, root, "Drawing")
    _properties_text(result, parts)
    _media_note(result, parts)


def _slide_text(result: Extraction, root: ET.Element, location: str, channel: str, slide_hidden: bool) -> None:
    visible, hidden = [], {}

    def walk(element: ET.Element, shape_hidden: bool) -> None:
        name = _local(element)
        if name in ("sp", "pic", "graphicFrame", "grpSp"):
            properties = next((node for node in element.iter() if _local(node) == "cNvPr"), None)
            if properties is not None and _attr(properties, "hidden") in ("1", "true"):
                shape_hidden = True
        if name == "r":
            properties = _child(element, "rPr")
            size = _attr(properties, "sz") if properties is not None else None
            text = next((node.text or "" for node in element if _local(node) == "t"), "")
            if shape_hidden or slide_hidden:
                hidden.setdefault("hidden slide" if slide_hidden else "hidden shape", []).append(text)
            elif size and size.isdigit() and int(size) <= 200:  # hundredths of a point
                hidden.setdefault("text of 2 pt or smaller", []).append(text)
            else:
                visible.append(text)
        for child in element:
            walk(child, shape_hidden)
        if name == "p":
            for bucket in [visible, *hidden.values()]:
                if bucket and bucket[-1] != "\n":
                    bucket.append("\n")

    walk(root, False)
    result.add(channel, location, "".join(visible))
    for reason, chunk in hidden.items():
        result.add(HIDDEN, location, "".join(chunk), reason)
    _drawing_text(result, root, location)


def _pptx(result: Extraction, data: bytes) -> None:
    parts = _zip_parts(data)
    slides = sorted((name for name in parts if re.fullmatch(r"ppt/slides/slide\d+\.xml", name)), key=_natural)
    if not slides and "ppt/presentation.xml" not in parts:
        raise ExtractError("This file is not a supported PPTX package.")
    for name in slides:
        number = re.search(r"(\d+)\.xml$", name)[1]
        root = _xml(result, name, parts[name])
        if root is not None:
            _slide_text(result, root, f"Slide {number}", VISIBLE, root.get("show") == "0")
    for name in sorted(parts, key=_natural):
        if re.fullmatch(r"ppt/notesSlides/notesSlide\d+\.xml", name):
            root = _xml(result, name, parts[name])
            if root is not None:
                result.add(SIDE, f"Speaker notes {re.search(r'(\d+)\.xml$', name)[1]}",
                           " ".join(node.text or "" for node in root.iter() if _local(node) == "t"))
        elif re.search(r"ppt/(?:comments|modernComment)[^/]*/?[^/]*\.xml$", name) and "/_rels/" not in name:
            root = _xml(result, name, parts[name])
            if root is not None:
                result.add(SIDE, "Slide comments", "\n".join(text.strip() for text in root.itertext() if text.strip()))
    _properties_text(result, parts)
    _media_note(result, parts)


def _odt(result: Extraction, data: bytes) -> None:
    parts = _zip_parts(data)
    root = _xml(result, "content.xml", parts["content.xml"]) if "content.xml" in parts else None
    if root is None:
        raise ExtractError("This file is not a supported ODT package.")
    hiding: dict[str, str] = {}
    for style in root.iter():
        if _local(style) != "style":
            continue
        for properties in style:
            if _local(properties) != "text-properties":
                continue
            size = _attr(properties, "font-size") or ""
            size_match = re.fullmatch(r"([\d.]+)pt", size)
            colour = (_attr(properties, "color") or "").lstrip("#")
            if _attr(properties, "display") == "none":
                hiding[_attr(style, "name") or ""] = "hidden text style"
            elif size_match and float(size_match[1]) <= 2:
                hiding[_attr(style, "name") or ""] = "text of 2 pt or smaller"
            elif _is_white(colour) and not _is_shaded((_attr(properties, "background-color") or "").lstrip("#")):
                hiding[_attr(style, "name") or ""] = "white text"
    visible: list[str] = []
    hidden: dict[str, list[str]] = {}

    def walk(element: ET.Element, reason: str, comment: bool) -> None:
        name = _local(element)
        if name in ("automatic-styles", "font-face-decls", "scripts"):
            return
        comment = comment or name == "annotation"
        if name == "hidden-text":
            result.add(HIDDEN, "Document body", _attr(element, "string-value") or "", "hidden text field")
        if name == "hidden-paragraph" or (name == "p" and _attr(element, "is-hidden") == "true"):
            reason = "hidden paragraph"
        reason = hiding.get(_attr(element, "style-name") or "", reason)

        def take(text: str | None) -> None:
            if not text:
                return
            if comment:
                result.add(SIDE, "Comments", text)
            elif reason:
                hidden.setdefault(reason, []).append(text)
            else:
                visible.append(text)

        take(element.text)
        for child in element:
            walk(child, reason, comment)
            take(child.tail)
        if name in ("p", "h"):
            visible.append("\n")

    walk(root, "", False)
    result.add(VISIBLE, "Document body", "".join(visible))
    for reason, chunk in hidden.items():
        result.add(HIDDEN, "Document body", "".join(chunk), reason)
    meta = _xml(result, "meta.xml", parts["meta.xml"]) if "meta.xml" in parts else None
    for node in meta.iter() if meta is not None else ():
        if len(node) == 0 and node.text:
            result.add(SIDE, f"Document property: {_local(node)}", node.text)
    if any(name.startswith("Pictures/") for name in parts):
        result.notes.append("Text inside images isn't read.")


def _epub(result: Extraction, data: bytes) -> None:
    parts = _zip_parts(data)
    css = "\n".join(decode_text(raw) for name, raw in parts.items() if name.lower().endswith(".css"))
    chapters = sorted((name for name in parts if name.lower().endswith((".xhtml", ".html", ".htm"))), key=_natural)
    if not chapters:
        raise ExtractError("This EPUB has no readable chapters.")
    for name in chapters:
        _markup(result, decode_text(parts[name]), Path(name).name, css)
    for name in sorted(parts):
        if name.lower().endswith((".opf", ".ncx")):
            root = _xml(result, name, parts[name])
            if root is not None:
                result.add(SIDE, "Book metadata", "\n".join(text.strip() for text in root.itertext() if text.strip()))
    if any(name.lower().endswith((".png", ".jpg", ".jpeg", ".gif", ".webp")) for name in parts):
        result.notes.append("Text inside images isn't read.")


# --- Embedded metadata via ExifTool -----------------------------------------------

def _tags(result: Extraction, path: Path) -> None:
    try:
        tags = metadata_editor._read_tags(path)
    except (metadata_editor.MetadataError, subprocess.TimeoutExpired, OSError):
        result.notes.append("Embedded metadata couldn't be read.")
        return
    for key, value in tags.items():
        if key.startswith(_NOT_IN_TAGS) or key == "SourceFile":
            continue
        values = value if isinstance(value, list) else [value]
        for item in values:
            if isinstance(item, str) and not item.startswith(("(Binary data", "base64:")):
                result.add(SIDE, f"Metadata: {key}", item)


# --- PDF --------------------------------------------------------------------------

_IDENTITY = (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
_BF_CHAR = re.compile(rb"beginbfchar(.*?)endbfchar", re.S)
_BF_RANGE = re.compile(rb"beginbfrange(.*?)endbfrange", re.S)
_HEX_PAIR = re.compile(rb"<([0-9A-Fa-f\s]*)>\s*<([0-9A-Fa-f\s]*)>")
_HEX_RANGE = re.compile(rb"<([0-9A-Fa-f\s]*)>\s*<([0-9A-Fa-f\s]*)>\s*(?:<([0-9A-Fa-f\s]*)>|\[(.*?)\])", re.S)
_HEX_ITEM = re.compile(rb"<([0-9A-Fa-f\s]*)>")
_COMPONENT_SPACES = {"/DeviceGray", "/DeviceRGB", "/DeviceCMYK", "/CalGray", "/CalRGB", "/ICCBased"}
_LITERAL_ESCAPES = {0x6E: 0x0A, 0x72: 0x0D, 0x74: 0x09, 0x62: 0x08, 0x66: 0x0C}


def _multiply(first: tuple, second: tuple) -> tuple:
    """Apply *first*, then *second*."""
    a, b, c, d, e, f = first
    g, h, i, j, k, l = second
    return (a * g + b * i, a * h + b * j, c * g + d * i, c * h + d * j, e * g + f * i + k, e * h + f * j + l)


def _apply(matrix: tuple, x: float, y: float) -> tuple[float, float]:
    return (matrix[0] * x + matrix[2] * y + matrix[4], matrix[1] * x + matrix[3] * y + matrix[5])


def _literal(raw: bytes) -> bytes:
    """The bytes of a PDF literal string, without its parentheses."""
    output = bytearray()
    index, end = 1, len(raw) - 1
    while index < end:
        value = raw[index]
        index += 1
        if value != 0x5C or index >= end:
            output.append(value)
            continue
        escaped = raw[index]
        index += 1
        if escaped in _LITERAL_ESCAPES:
            output.append(_LITERAL_ESCAPES[escaped])
        elif 0x30 <= escaped <= 0x37:
            digits = chr(escaped)
            while len(digits) < 3 and index < end and 0x30 <= raw[index] <= 0x37:
                digits += chr(raw[index])
                index += 1
            output.append(int(digits, 8) & 0xFF)
        elif escaped in (0x0A, 0x0D):
            if escaped == 0x0D and index < end and raw[index] == 0x0A:
                index += 1
        else:
            output.append(escaped)
    return bytes(output)


def _hex_bytes(raw: bytes) -> bytes:
    digits = re.sub(rb"[^0-9A-Fa-f]", b"", raw)
    if len(digits) % 2:
        digits += b"0"
    return bytes.fromhex(digits.decode("ascii"))


def _operations(data: bytes):
    """(operator, operands) for each operation in a content stream."""
    stack: list[list] = []
    operands: list = []
    for kind, start, end in pdf_traces._tokens(data):
        target = stack[-1] if stack else operands
        token = data[start:end]
        if kind == "open":
            stack.append([])
        elif kind == "close":
            if stack:
                closed = stack.pop()
                (stack[-1] if stack else operands).append(closed)
        elif kind == "name":
            target.append(pdf_traces._decode_name(token))
        elif kind == "other":
            if token.startswith(b"("):
                target.append(_literal(token))
            elif token.startswith(b"<"):
                target.append(_hex_bytes(token[1:-1]))
        elif pdf_traces._NUMBER.match(token):
            target.append(float(token))
        elif token not in (b"true", b"false", b"null"):
            if not stack:
                yield token, operands
                operands = []


@dataclass
class _GraphicsState:
    ctm: tuple = _IDENTITY
    fill: tuple | None = (0.0, 0.0, 0.0)
    fill_has_components: bool = True
    render_mode: int = 0
    font: dict | None = None
    size: float = 0.0
    leading: float = 0.0
    alpha: float = 1.0
    clipped_away: bool = False


@dataclass
class _PageText:
    hidden: dict[str, list[str]] = field(default_factory=dict)
    visible: list[str] = field(default_factory=list)
    characters: int = 0
    invisible_characters: int = 0
    has_image: bool = False


class _PdfWalker:
    def __init__(self, doc):
        self.doc = doc
        self.fonts: dict[int, tuple] = {}
        self.operations = 0
        self.incomplete = False
        self.unreadable_fonts = False
        self.has_image = False
        properties = doc.dictionary(doc.dictionary(doc.trailer["/Root"]).get("/OCProperties")) or {}
        default = doc.dictionary(properties.get("/D")) or {}
        self.layers_off = set(doc.get(default.get("/OFF")) or [])

    def _inherited(self, page: dict, key: str):
        node, depth = page, 0
        while node is not None and depth < 64:
            if key in node:
                return node[key]
            node = self.doc.dictionary(node.get("/Parent"))
            depth += 1
        return None

    def _font(self, reference) -> tuple:
        font = self.doc.dictionary(reference)
        if font is None:
            return ({}, (), False)
        cached = self.fonts.get(id(font))
        if cached:
            return cached
        cmap: dict[bytes, str] = {}
        stream = self.doc.get(font.get("/ToUnicode"))
        data = self.doc.stream_data(stream["stream"]) if isinstance(stream, dict) and "stream" in stream else None
        for block in _BF_CHAR.findall(data or b""):
            for source, target in _HEX_PAIR.findall(block):
                cmap[_hex_bytes(source)] = _hex_bytes(target).decode("utf-16-be", "replace")
        for block in _BF_RANGE.findall(data or b""):
            for first, last, target, items in _HEX_RANGE.findall(block):
                low, high = _hex_bytes(first), _hex_bytes(last)
                count = int.from_bytes(high, "big") - int.from_bytes(low, "big") + 1
                if not 0 < count <= 65536:
                    continue
                values = [_hex_bytes(item) for item in _HEX_ITEM.findall(items)] if items else None
                base = _hex_bytes(target) if not items else b""
                for offset in range(count):
                    code = (int.from_bytes(low, "big") + offset).to_bytes(len(low), "big")
                    if values is not None:
                        if offset < len(values):
                            cmap[code] = values[offset].decode("utf-16-be", "replace")
                    elif base:
                        mapped = int.from_bytes(base, "big") + offset
                        cmap[code] = mapped.to_bytes(len(base), "big").decode("utf-16-be", "replace")
        lengths = tuple(sorted({len(code) for code in cmap}, reverse=True))
        result = (cmap, lengths, font.get("/Subtype") == "/Type0")
        self.fonts[id(font)] = result
        return result

    def _decode(self, state: _GraphicsState, raw: bytes) -> str:
        cmap, lengths, composite = self._font(state.font) if state.font is not None else ({}, (), False)
        if not cmap:
            if composite:
                self.unreadable_fonts = True
                return "[unreadable glyphs]"
            return raw.decode("cp1252", "replace")
        output, index = [], 0
        while index < len(raw):
            for length in lengths:
                code = raw[index:index + length]
                if code in cmap:
                    output.append(cmap[code])
                    index += length
                    break
            else:
                index += lengths[-1]
        return "".join(output)

    def page(self, page: dict) -> _PageText:
        text = _PageText()
        resources = self.doc.dictionary(self._inherited(page, "/Resources")) or {}
        box = self.doc.get(self._inherited(page, "/CropBox") or self._inherited(page, "/MediaBox")) or [0, 0, 612, 792]
        box = [float(self.doc.get(value)) for value in box]
        box = (min(box[0], box[2]), min(box[1], box[3]), max(box[0], box[2]), max(box[1], box[3]))
        contents = self.doc.get(page.get("/Contents"))
        chunks = []
        for item in contents if isinstance(contents, list) else [contents]:
            stream = self.doc.get(item)
            if isinstance(stream, dict) and "stream" in stream:
                data = self.doc.stream_data(stream["stream"])
                if data is None:
                    self.incomplete = True
                else:
                    chunks.append(data)
        try:
            self._run(b"\n".join(chunks), resources, _GraphicsState(), text, box, [], 0, set())
        except (pdf_traces.PdfTraceError, ValueError, IndexError, TypeError):
            self.incomplete = True
        return text

    def _run(self, data, resources, state, text, box, painted, depth, active) -> None:
        """Interpret one content stream, adding to *text* and *painted*."""
        stack: list[_GraphicsState] = []
        text_matrix = line_matrix = _IDENTITY
        moved = True
        path: list[tuple[float, float]] = []
        pending_clip = False
        marked: list[bool] = []
        for operator, operands in _operations(data):
            self.operations += 1
            if self.operations > _PDF_MAX_OPERATIONS:
                self.incomplete = True
                return
            numbers = [value for value in operands if isinstance(value, float)]
            if operator == b"q":
                stack.append(replace(state))
            elif operator == b"Q":
                if stack:
                    state = stack.pop()
            elif operator == b"cm" and len(numbers) >= 6:
                state.ctm = _multiply(tuple(numbers[:6]), state.ctm)
            elif operator == b"g" and numbers:
                state.fill, state.fill_has_components = (numbers[0],) * 3, True
            elif operator == b"rg" and len(numbers) >= 3:
                state.fill, state.fill_has_components = tuple(numbers[:3]), True
            elif operator == b"k" and len(numbers) >= 4:
                state.fill, state.fill_has_components = _cmyk(numbers), True
            elif operator == b"cs" and operands:
                space = operands[-1]
                entry = self.doc.get((self.doc.dictionary(resources.get("/ColorSpace")) or {}).get(space))
                family = (self.doc.get(entry[0]) if isinstance(entry, list) and entry else entry) or space
                state.fill = (0.0, 0.0, 0.0)
                state.fill_has_components = family in _COMPONENT_SPACES
            elif operator in (b"sc", b"scn"):
                if not state.fill_has_components or (operands and not isinstance(operands[-1], float)):
                    state.fill = None
                elif len(numbers) == 1:
                    state.fill = (numbers[0],) * 3
                elif len(numbers) == 3:
                    state.fill = tuple(numbers)
                elif len(numbers) == 4:
                    state.fill = _cmyk(numbers)
            elif operator == b"gs" and operands:
                graphics = self.doc.dictionary((self.doc.dictionary(resources.get("/ExtGState")) or {}).get(operands[-1])) or {}
                if isinstance(graphics.get("/ca"), (int, float)):
                    state.alpha = float(graphics["/ca"])
            elif operator == b"re" and len(numbers) >= 4:
                x, y, width, height = numbers[:4]
                path += [_apply(state.ctm, x, y), _apply(state.ctm, x + width, y + height),
                         _apply(state.ctm, x + width, y), _apply(state.ctm, x, y + height)]
            elif operator in (b"m", b"l") and len(numbers) >= 2:
                path.append(_apply(state.ctm, numbers[0], numbers[1]))
            elif operator in (b"c", b"v", b"y"):
                for index in range(0, len(numbers) - 1, 2):
                    path.append(_apply(state.ctm, numbers[index], numbers[index + 1]))
            elif operator in (b"W", b"W*"):
                pending_clip = True
            elif operator in (b"f", b"F", b"f*", b"B", b"B*", b"b", b"b*", b"S", b"s", b"n"):
                if operator not in (b"S", b"s", b"n") and path and state.alpha > 0.02 and not _near_white(state.fill):
                    painted.append(_bounds(path))
                if pending_clip and path:
                    left, bottom, right, top = _bounds(path)
                    if right - left < 0.01 or top - bottom < 0.01:
                        state.clipped_away = True
                path, pending_clip = [], False
            elif operator == b"sh":
                painted.append((-math.inf, -math.inf, math.inf, math.inf))
            elif operator == b"BT":
                text_matrix = line_matrix = _IDENTITY
                moved = True
            elif operator == b"Tf" and len(operands) >= 2:
                fonts = self.doc.dictionary(resources.get("/Font")) or {}
                state.font = fonts.get(operands[-2])
                state.size = operands[-1] if isinstance(operands[-1], float) else state.size
            elif operator == b"Tr" and numbers:
                state.render_mode = int(numbers[0])
            elif operator == b"TL" and numbers:
                state.leading = numbers[0]
            elif operator in (b"Td", b"TD") and len(numbers) >= 2:
                if operator == b"TD":
                    state.leading = -numbers[1]
                line_matrix = _multiply((1.0, 0.0, 0.0, 1.0, numbers[0], numbers[1]), line_matrix)
                text_matrix, moved = line_matrix, True
            elif operator == b"Tm" and len(numbers) >= 6:
                text_matrix = line_matrix = tuple(numbers[:6])
                moved = True
            elif operator in (b"T*", b"'", b'"'):
                line_matrix = _multiply((1.0, 0.0, 0.0, 1.0, 0.0, -state.leading), line_matrix)
                text_matrix, moved = line_matrix, True
            if operator in (b"Tj", b"TJ", b"'", b'"') and operands:
                shown = self._shown(state, operands[-1])
                if shown:
                    self._record(shown, state, text_matrix, box, painted, text, moved, any(marked))
                    moved = False
            elif operator == b"BDC":
                hidden = False
                if len(operands) >= 2 and operands[-2] == "/OC" and isinstance(operands[-1], str):
                    reference = (self.doc.dictionary(resources.get("/Properties")) or {}).get(operands[-1])
                    hidden = reference in self.layers_off
                marked.append(hidden)
            elif operator == b"BMC":
                marked.append(False)
            elif operator == b"EMC":
                if marked:
                    marked.pop()
            elif operator == b"Do" and operands:
                reference = (self.doc.dictionary(resources.get("/XObject")) or {}).get(operands[-1])
                entry = self.doc.get(reference)
                if not (isinstance(entry, dict) and "stream" in entry):
                    continue
                dictionary = entry["stream"]["dict"]
                if dictionary.get("/Subtype") == "/Image":
                    corners = [_apply(state.ctm, x, y) for x, y in ((0, 0), (1, 1), (1, 0), (0, 1))]
                    painted.append(_bounds(corners))
                    text.has_image = self.has_image = True
                elif dictionary.get("/Subtype") == "/Form" and depth < _PDF_MAX_FORM_DEPTH and id(entry) not in active:
                    form_data = self.doc.stream_data(entry["stream"])
                    if form_data is None:
                        self.incomplete = True
                        continue
                    inner = replace(state)
                    matrix = self.doc.get(dictionary.get("/Matrix"))
                    if isinstance(matrix, list) and len(matrix) == 6:
                        inner.ctm = _multiply(tuple(float(value) for value in matrix), inner.ctm)
                    own = self.doc.dictionary(dictionary.get("/Resources")) or resources
                    self._run(form_data, own, inner, text, box, painted, depth + 1, active | {id(entry)})

    def _shown(self, state: _GraphicsState, operand) -> str:
        if isinstance(operand, bytes):
            return self._decode(state, operand)
        if not isinstance(operand, list):
            return ""
        output = []
        for item in operand:
            if isinstance(item, bytes):
                output.append(self._decode(state, item))
            elif isinstance(item, float) and item < -200:
                output.append(" ")
        return "".join(output)

    def _record(self, shown, state, text_matrix, box, painted, text, moved, hidden_layer) -> None:
        matrix = _multiply(text_matrix, state.ctm)
        x, y = matrix[4], matrix[5]
        scale = math.sqrt(abs(matrix[0] * matrix[3] - matrix[1] * matrix[2]))
        reason = ""
        if state.render_mode in (3, 7):
            reason = "invisible render mode"
        elif state.alpha <= 0.02:
            reason = "fully transparent text"
        elif hidden_layer:
            reason = "hidden layer"
        elif state.clipped_away:
            reason = "clipped out of view"
        elif abs(state.size) * scale < 1:
            reason = "font smaller than 1 pt"
        elif not (box[0] - 5 <= x <= box[2] + 5 and box[1] - 5 <= y <= box[3] + 5):
            reason = "positioned outside the page"
        elif state.render_mode in (0, 2) and _near_white(state.fill) and not any(
                left <= x <= right and bottom <= y <= top for left, bottom, right, top in painted):
            reason = "white text on a white page"
        stripped = len(shown.strip())
        text.characters += stripped
        bucket = text.hidden.setdefault(reason, []) if reason else text.visible
        if reason == "invisible render mode":
            text.invisible_characters += stripped
        if moved and bucket:
            bucket.append(" ")
        bucket.append(shown)


def _cmyk(numbers: list[float]) -> tuple:
    c, m, y, k = numbers[:4]
    return ((1 - c) * (1 - k), (1 - m) * (1 - k), (1 - y) * (1 - k))


def _near_white(fill: tuple | None) -> bool:
    return fill is not None and all(value >= 0.96 for value in fill)


def _bounds(points: list[tuple[float, float]]) -> tuple[float, float, float, float]:
    xs, ys = [point[0] for point in points], [point[1] for point in points]
    return (min(xs), min(ys), max(xs), max(ys))


def _pdf_string(value: Any) -> str:
    if not isinstance(value, str):
        return ""
    if value.startswith("u:"):
        return value[2:]
    if value.startswith("b:"):
        return decode_text(bytes.fromhex(value[2:]))
    return ""


def _pdf_side_text(result: Extraction, doc) -> None:
    attachments = 0
    for dictionary in doc.dictionaries():
        if dictionary.get("/Type") == "/Annot" or "/Rect" in dictionary and "/Subtype" in dictionary:
            for key, label in (("/Contents", "Annotation"), ("/T", "Form field"), ("/TU", "Form field"), ("/V", "Form field")):
                result.add(SIDE, label, _pdf_string(doc.get(dictionary.get(key))))
            action = doc.dictionary(dictionary.get("/A"))
            uri = _pdf_string(doc.get(action.get("/URI"))) if action else ""
            result.add(SIDE, "Link", uri)
        if "/Title" in dictionary and any(key in dictionary for key in ("/Parent", "/First", "/Dest", "/A")):
            result.add(SIDE, "Bookmark", _pdf_string(doc.get(dictionary["/Title"])))
        if dictionary.get("/Type") == "/Filespec":
            attachments += 1
            for key in ("/UF", "/F", "/Desc"):
                result.add(SIDE, "Attachment name", _pdf_string(doc.get(dictionary.get(key))))
        if "/JS" in dictionary:
            script = doc.get(dictionary["/JS"])
            if isinstance(script, dict) and "stream" in script:
                body = decode_text(doc.stream_data(script["stream"]) or b"")
            else:
                body = _pdf_string(script)
            result.add(SIDE, "PDF JavaScript", body)
    if attachments:
        result.notes.append("Attached files aren't checked.")


def _ghostscript_text(path: Path) -> str | None:
    tool = shutil.which("gs")
    if tool is None:
        return None
    with tempfile.TemporaryDirectory(prefix="pdf-text-") as temp:
        target = Path(temp) / "text.txt"
        try:
            run = subprocess.run(
                [tool, "-q", "-dSAFER", "-dBATCH", "-dNOPAUSE", "-sDEVICE=txtwrite", f"-sOutputFile={target}", str(path)],
                capture_output=True, timeout=GHOSTSCRIPT_TIMEOUT, check=False)
        except (OSError, subprocess.TimeoutExpired):
            return None
        if run.returncode != 0 or not target.is_file():
            return None
        return target.read_text("utf-8", "replace")


def _pdf(result: Extraction, path: Path) -> None:
    try:
        if pdf_traces._encrypted(path):
            raise ExtractError("This PDF is encrypted, so its text can't be checked.")
    except pdf_traces.PdfTraceError as exc:
        raise ExtractError("The PDF couldn't be read.") from exc
    _tags(result, path)
    page_text: list[tuple[int, _PageText]] = []
    with tempfile.TemporaryDirectory(prefix="pdf-injection-") as temp:
        try:
            doc = pdf_traces._Document(path, Path(temp))
        except (pdf_traces.PdfTraceError, ValueError, KeyError, OSError) as exc:
            raise ExtractError("The PDF couldn't be read.") from exc
        walker = _PdfWalker(doc)
        for number, page in enumerate(doc.pages(), start=1):
            text = walker.page(page)
            page_text.append((number, text))
            for reason, chunks in text.hidden.items():
                location = f"Page {number}"
                ocr = (reason == "invisible render mode" and text.has_image
                       and text.invisible_characters >= 0.8 * max(text.characters, 1))
                result.add(HIDDEN, location, "".join(chunks), reason, ocr)
        _pdf_side_text(result, doc)
        if walker.incomplete:
            result.notes.append("Some page content couldn't be read, so hidden text there wasn't checked.")
        if walker.unreadable_fonts:
            result.notes.append("Some text uses fonts with no character map, so it can't be read.")
        if walker.has_image:
            result.notes.append("Text inside images isn't read.")
    visible = _ghostscript_text(path)
    if visible is not None:
        result.add(VISIBLE, "Page text", visible)
        return
    result.notes.append("Ghostscript couldn't extract the page text, so text was read directly from the pages.")
    for number, text in page_text:
        result.add(VISIBLE, f"Page {number}", "".join(text.visible))


# --- Entry point ------------------------------------------------------------------

def extract(path: Path, data: bytes) -> Extraction:
    """Every piece of text in the file at *path*, whose bytes are *data*."""
    suffix = path.suffix.lower().lstrip(".")
    result = Extraction()
    if suffix in TEXT_SUFFIXES:
        result.add(VISIBLE, "File text", decode_text(data))
    elif suffix in ("html", "htm", "svg"):
        _markup(result, decode_text(data), "SVG" if suffix == "svg" else "Page")
    elif suffix in MARKDOWN_SUFFIXES:
        source = decode_text(data)
        _markup(result, source, "Document")
        for comment in _MARKDOWN_COMMENT.findall(source):
            result.add(SIDE, "Document: comment", comment)
    elif suffix == "pdf":
        _pdf(result, path)
    elif suffix == "docx":
        _docx(result, data)
    elif suffix == "xlsx":
        _xlsx(result, data)
    elif suffix == "pptx":
        _pptx(result, data)
    elif suffix == "odt":
        _odt(result, data)
    elif suffix == "epub":
        _epub(result, data)
    else:
        _tags(result, path)
        result.notes.append("Only this file's embedded metadata is checked; text in the image or recording itself isn't read.")
    return result
