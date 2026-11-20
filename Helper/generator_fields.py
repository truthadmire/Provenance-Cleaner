"""Metadata fields that name an AI generator, which the pinned engine misses.

The engine decides what is "AI metadata" from a short keyword list, so a JPEG
whose EXIF Software is "Midjourney", a ComfyUI PNG or an MP4 commented "Made
with Sora" passes as ordinary and is left alone when ordinary metadata is
kept. This module reads the fields with the bundled ExifTool (and PNG text
chunks directly), reports the ones that name a generator, and removes them
from the copy.

A field is reported in three cases:
- a field that names the software (Software, CreatorTool, Encoder, Credit...)
  holds an AI product's name;
- any field holds wording or settings only a generator writes ("Made with
  Google AI", "Steps: 20, Sampler: ...", "--v 6 ... Job ID: ...");
- a PNG text chunk has a key generators use for their settings (prompt,
  workflow, parameters...).

A product name alone in a caption, comment or author field isn't reported: "a
photo of the Gemini capsule" is ordinary text.
"""
from __future__ import annotations

import json
import re
import shutil
import struct
import subprocess
import tempfile
import zlib
from pathlib import Path
from typing import Any, Callable

EXIFTOOL_TIMEOUT = 30
MAX_TEXT = 1 << 20
# Inflated text read across all of one PNG's chunks; matches
# png_text_limits.MAX_PNG_TEXT_BYTES, whose inspection finding already marks a
# file that reaches it for review.
MAX_PNG_TEXT = 16 << 20
MAX_TAIL = 64 << 10
UNAVAILABLE = "Generator fields were not fully inspected: the bundled metadata reader could not read this file."

_PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"

# Named only by generators, wherever they appear in a software field.
_DISTINCT = (
    r"midjourney", r"dall[-·. ]?e", r"chatgpt", r"openai", r"gpt-?image", r"gpt-?4o", r"stable ?diffusion",
    r"sdxl", r"sd_xl", r"stability ?ai", r"dreamstudio", r"comfyui", r"automatic1111", r"invokeai",
    r"novelai", r"adobe firefly", r"google ai", r"elevenlabs", r"craiyon", r"nightcafe",
    r"bing image creator", r"leonardo\.?ai", r"tensorart", r"clipdrop", r"deepai", r"seedream",
    r"dreamina", r"hunyuan", r"runway gen-?\d", r"nano banana", r"meta ai", r"suno ai", r"synthid",
)
# Ordinary words too, so they count only in a field that names the software.
_AMBIGUOUS = (
    r"sora", r"firefly", r"imagen", r"gemini", r"veo", r"grok", r"flux", r"ideogram", r"recraft",
    r"runway", r"kling", r"luma", r"pika", r"hailuo", r"suno", r"udio", r"claude", r"anthropic", r"qwen",
)


def _words(names: tuple[str, ...]) -> str:
    return r"(?<![A-Za-z0-9])(?:" + "|".join(names) + r")(?![A-Za-z])"


_DISTINCT_NAME = re.compile(_words(_DISTINCT), re.I)
_ANY_NAME = re.compile(_words(_DISTINCT + _AMBIGUOUS), re.I)
_GENERATION_WORDING = re.compile(
    # "by" also introduces a person, so after it only a distinct name counts.
    r"(?:\b(?:made|generated|created|produced|composed|rendered|edited)\s+(?:with|using)\s+"
    r"(?:an?\s+)?(?:ai|artificial intelligence|" + "|".join(_DISTINCT + _AMBIGUOUS) + r")(?![A-Za-z]))"
    r"|(?:\b(?:made|generated|created|produced|composed|rendered)\s+by\s+"
    r"(?:an?\s+)?(?:ai|artificial intelligence|" + "|".join(_DISTINCT) + r")(?![A-Za-z]))"
    r"|\bAI[- ]generated\b|\bAIGC\b|trainedAlgorithmicMedia"
    r"|\bSteps: \d+, Sampler: |\bNegative prompt: |\bCFG scale: [\d.]+"
    r"|(?:^|\s)--(?:ar|niji|stylize|chaos|sref|cref)\s+[\w:.]+|(?:^|\s)--v\s+\d"
    r"|\bJob ID: [0-9a-f]{8}-[0-9a-f]{4}-",
    re.I,
)

# ExifTool tag names (lower case) that say which software or service made the file.
_SOFTWARE_TAGS = frozenset({
    "software", "creatortool", "encoder", "encodedby", "encodersettings", "encodingsettings", "credit",
    "hostcomputer", "processingsoftware", "producer", "application", "softwareagent",
    "historysoftwareagent", "tool", "generator", "source", "vendor", "writingapp", "muxingapp",
    "softwareversion", "creatingapplication",
})
# Camera fields: real cameras are called Veo, Luma or Gemini, so only distinct names count.
_DEVICE_TAGS = frozenset({"make", "model", "lensmake", "lensmodel"})
_DEVICE_NAME = re.compile(_words(_DISTINCT + (r"imagen",)), re.I)
# Keys generators use for their settings in PNG text chunks.
_PNG_SETTINGS_KEYS = frozenset({
    "prompt", "workflow", "parameters", "invokeai_metadata", "invokeai_graph", "sd-metadata", "dream",
    "generation time", "generation_data",
})
_SKIPPED_GROUPS = frozenset({"System", "Composite", "ExifTool", "PNG"})
_CONTROL = re.compile(r"[\x00-\x1f\x7f]+")


def _shown(value: str) -> str:
    value = _CONTROL.sub(" ", value).strip()
    return value if len(value) <= 80 else value[:79] + "…"


def _classify(tag: str, value: str) -> str | None:
    """'software' or 'wording' when *value* in field *tag* points at a generator."""
    name = tag.rsplit(":", 1)[-1].lower()
    if name in _DEVICE_TAGS:
        return "software" if _DEVICE_NAME.search(value) else None
    if name in _SOFTWARE_TAGS and _ANY_NAME.search(value):
        return "software"
    return "wording" if _GENERATION_WORDING.search(value) else None


def _sentence(hit: dict[str, Any]) -> str:
    if hit["kind"] == "settings":
        return f"Generation metadata in PNG text chunk {hit['tag']}"
    if hit["kind"] == "trailing":
        return f"Data after the end of the image describes AI generation: {hit['value']}"
    if hit["kind"] == "software":
        return f"Generator field {hit['tag']} names an AI tool: {hit['value']}"
    return f"Metadata field {hit['tag']} describes AI generation: {hit['value']}"


# --- PNG text chunks ------------------------------------------------------------

def _png_chunks(data: bytes):
    """(type, payload, start, end) for each complete chunk."""
    position = len(_PNG_SIGNATURE)
    while position + 8 <= len(data):
        length = struct.unpack(">I", data[position:position + 4])[0]
        end = position + 12 + length
        if end > len(data):
            return
        yield data[position + 4:position + 8], data[position + 8:position + 8 + length], position, end
        position = end


def _inflate(data: bytes, limit: int = MAX_TEXT) -> bytes:
    if limit <= 0:
        return b""
    try:
        return zlib.decompressobj().decompress(data, min(limit, MAX_TEXT))
    except zlib.error:
        return b""


def _png_text(ctype: bytes, payload: bytes, budget: list[int] | None = None) -> tuple[str, str] | None:
    """(key, text) of a text chunk. *budget* holds the bytes still allowed to be
    inflated for this image and is reduced by what this chunk inflates."""
    limit = MAX_TEXT if budget is None else budget[0]
    key, separator, rest = payload.partition(b"\0")
    if not separator:
        return None
    if ctype == b"zTXt":
        rest = _inflate(rest[1:], limit)
        if budget is not None:
            budget[0] -= len(rest)
    elif ctype == b"iTXt":
        if len(rest) < 2:
            return None
        compressed = rest[0] == 1
        parts = rest[2:].split(b"\0", 2)
        if len(parts) < 3:
            return None
        rest = _inflate(parts[2], limit) if compressed else parts[2]
        if compressed and budget is not None:
            budget[0] -= len(rest)
    return key.decode("latin-1"), rest[:MAX_TEXT].decode("utf-8", "replace")


def _png_hits(data: bytes) -> list[dict[str, Any]]:
    hits = []
    budget = [MAX_PNG_TEXT]
    for ctype, payload, _, _ in _png_chunks(data):
        if ctype not in (b"tEXt", b"zTXt", b"iTXt"):
            continue
        entry = _png_text(ctype, payload, budget)
        if entry is None or entry[0].startswith("XML:"):
            continue  # XMP is read by ExifTool below
        key, value = entry
        if key.strip().lower() in _PNG_SETTINGS_KEYS:
            kind = "settings"
        else:
            kind = _classify(key.replace(" ", ""), value)
        if kind:
            hits.append({"kind": kind, "tag": key, "value": _shown(value), "pngKey": key})
    return hits


def _without_png_keys(data: bytes, keys: set[str]) -> bytes:
    output = bytearray(_PNG_SIGNATURE)
    last = len(_PNG_SIGNATURE)
    for ctype, payload, start, end in _png_chunks(data):
        if ctype in (b"tEXt", b"zTXt", b"iTXt") and payload.partition(b"\0")[0].decode("latin-1") in keys:
            output += data[last:start]
            last = end
    output += data[last:]
    return bytes(output)


# --- Data after the image -------------------------------------------------------

def _trailing_hits(data: bytes) -> list[dict[str, Any]]:
    tail = b""
    if data[:2] == b"\xff\xd8":
        end = data.rfind(b"\xff\xd9")
        tail = data[end + 2:] if end >= 0 else b""
    elif data[:2] == b"BM":
        try:
            import image_meta
            tail = image_meta._bmp_trailing(data)
        except Exception:
            tail = b""
    text = tail[:MAX_TAIL].decode("latin-1")
    match = _GENERATION_WORDING.search(text)
    if not match:
        return []
    start = max(0, match.start() - 20)
    return [{"kind": "trailing", "tag": "", "value": _shown(text[start:match.end() + 40])}]


# --- ExifTool -------------------------------------------------------------------

def _exiftool() -> str | None:
    return shutil.which("exiftool")


def _read(path: Path) -> dict[str, Any] | None:
    tool = _exiftool()
    if not tool:
        return None
    try:
        result = subprocess.run(
            [tool, "-j", "-G1", "-a", "-s", "-charset", "filename=UTF8", str(path)],
            capture_output=True, text=True, timeout=EXIFTOOL_TIMEOUT, check=False,
        )
        values = json.loads(result.stdout)[0]
    except (OSError, subprocess.TimeoutExpired, ValueError, IndexError, TypeError):
        return None
    if not isinstance(values, dict) or "ExifTool:Error" in values:
        return None
    return values


def _field_hits(values: dict[str, Any]) -> list[dict[str, Any]]:
    hits = []
    for tag, value in values.items():
        group = tag.split(":", 1)[0]
        if group in _SKIPPED_GROUPS or (group == "File" and tag != "File:Comment"):
            continue
        if isinstance(value, list):
            value = "; ".join(str(item) for item in value)
        if not isinstance(value, str):
            continue
        kind = _classify(tag, value)
        if kind:
            hits.append({"kind": kind, "tag": tag, "value": _shown(value)})
    return hits


def detect(path: Path, data: bytes, *, readable: bool = True) -> tuple[list[dict[str, Any]], bool]:
    """Generator hits in the file at *path*, and whether every check could run.

    *readable* is False when ExifTool has already failed on this file, so it
    isn't made to fail (slowly) a second time.
    """
    hits = _png_hits(data) if data.startswith(_PNG_SIGNATURE) else []
    hits += _trailing_hits(data)
    values = _read(path) if readable else None
    if values is not None:
        hits += _field_hits(values)
    return hits, values is not None


def detect_bytes(data: bytes, suffix: str) -> tuple[list[dict[str, Any]], bool]:
    with tempfile.TemporaryDirectory(prefix="generator-fields-") as directory:
        path = Path(directory) / ("file" + suffix)
        path.write_bytes(data)
        return detect(path, data)


def _remove(data: bytes, suffix: str, hits: list[dict[str, Any]]) -> bytes:
    """*data* without the fields in *hits*, as far as they can be removed one by one."""
    png_keys = {hit["pngKey"] for hit in hits if "pngKey" in hit}
    if png_keys:
        data = _without_png_keys(data, png_keys)
    tags = [hit["tag"] for hit in hits if "pngKey" not in hit and hit["kind"] != "trailing"]
    tool = _exiftool()
    if not tags or not tool:
        return data
    with tempfile.TemporaryDirectory(prefix="generator-fields-") as directory:
        path = Path(directory) / ("file" + suffix)
        path.write_bytes(data)
        # File:Comment is the JPEG or GIF comment, which ExifTool writes as Comment.
        arguments = [f"-{'Comment' if tag == 'File:Comment' else tag}=" for tag in dict.fromkeys(tags)]
        try:
            # ExifTool stamps its name into any XMP it rewrites unless told not to.
            result = subprocess.run(
                [tool, "-overwrite_original", "-charset", "filename=UTF8", *arguments, "-XMP-x:XMPToolkit=", str(path)],
                capture_output=True, text=True, timeout=EXIFTOOL_TIMEOUT, check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            return data
        return path.read_bytes() if result.returncode == 0 else data


def _label(hit: dict[str, Any]) -> str:
    return hit["tag"] or "after the image"


def present(report: dict[str, Any], path: Path, data: bytes, *, readable: bool = True) -> None:
    """Add generator findings to an inspection report."""
    hits, complete = detect(path, data, readable=readable)
    if hits:
        findings = report.setdefault("findings", [])
        confidences = report.setdefault("findings_confidence", ["probable"] * len(findings))
        for hit in hits:
            findings.append(_sentence(hit))
            confidences.append("probable")
        report["has_ai_metadata"] = True
        report["suspicious"] = True
    if not complete:
        report.setdefault("notes", []).append(UNAVAILABLE)


def clean(
    cleaned: bytes, suffix: str, *, keep_ordinary: bool, strip_all: Callable[[], bytes],
) -> tuple[bytes, list[str], list[str], bool]:
    """Remove generator fields the engine left in *cleaned*.

    Returns the new bytes, what was done, what is still there, and whether the
    whole file's metadata had to go (*strip_all* was used).
    """
    hits, complete = detect_bytes(cleaned, suffix)
    actions: list[str] = []
    stripped_all = False
    if hits and keep_ordinary:
        candidate = _remove(cleaned, suffix, hits)
        remaining, _ = detect_bytes(candidate, suffix)
        left = {(_label(hit), hit["kind"]) for hit in remaining}
        removed = [hit for hit in hits if (_label(hit), hit["kind"]) not in left]
        if candidate != cleaned and removed:
            cleaned = candidate
            actions += [
                f"Removed PNG text chunk {hit['tag']}" if "pngKey" in hit else f"Removed generator field {hit['tag']}"
                for hit in removed
            ]
        hits = remaining
        if hits:
            # ID3, RIFF and trailing data can't be edited field by field.
            candidate = strip_all()
            remaining, complete = detect_bytes(candidate, suffix)
            if len(remaining) < len(hits):
                cleaned, hits, stripped_all = candidate, remaining, True
                actions.append("Removed all metadata: a generator field couldn't be removed on its own.")
    residual = [_sentence(hit) for hit in hits]
    if not complete:
        residual.append(UNAVAILABLE)
    return cleaned, actions, residual, stripped_all
