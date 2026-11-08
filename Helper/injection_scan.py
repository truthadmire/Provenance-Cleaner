"""Report signs of prompt injection in a file: instructions hidden from a person
but readable by an AI assistant that later processes it.

Every check here is deterministic and offline, and the report describes what was
found rather than judging intent: a security article can quote these phrases too.
"""
from __future__ import annotations

import base64
import binascii
import re
import unicodedata
from pathlib import Path

from text_unicode import inspect_text

import injection_extract
from injection_extract import HIDDEN, SIDE, VISIBLE, Piece

HIGH, MEDIUM, INFO = "high", "medium", "info"
MAX_REVIEW_CHARS = 400_000
MAX_SCANNED_CHARS = 16_000_000
MAX_FINDINGS = 200
EXCERPT_RADIUS = 70
_RANK = {HIGH: 0, MEDIUM: 1, INFO: 2}
_MAX_MATCHES_PER_PATTERN = 3
_MAX_BLOBS_PER_PIECE = 20

# (summary, strong, pattern). Strong phrases are rarely innocent; weak ones are
# ordinary in some documents, so they only matter where a reader can't see them.
_FLAGS = re.IGNORECASE | re.MULTILINE
_PHRASES = [(summary, strong, re.compile(pattern, _FLAGS)) for summary, strong, pattern in (
    ("Tells the reader to ignore earlier instructions", True,
     r"\b(?:ignore|disregard|forget|override|bypass)\s+(?:(?:all|any|every|the|your|my|these|those)\s+)*"
     r"(?:(?:previous|prior|above|earlier|preceding|foregoing|original|system|initial)\s+)*(?:\w+\s+)?"
     r"(?:instructions?|prompts?|directions?|guidelines?|system messages?)\b"),
    ("Tells the reader to keep something from the user", True,
     r"\b(?:do not|don't|never)\s+(?:tell|inform|reveal|mention|disclose|show|alert)\b.{0,40}?\b(?:users?|humans?|readers?|reviewers?|operators?)\b"),
    ("Addresses an AI model directly", True,
     r"\b(?:if you are|you are|attention|note to|dear|hey)\s+(?:an?\s+)?(?:ai|llm|language model|large language model|chatbot|ai assistant|ai model|ai reviewer)\b"
     r"(?!\s+(?:researcher|engineer|expert|developer|scientist|company|startup|enthusiast|practitioner|user)s?\b)"),
    ("Asks for a favourable review or rating", True,
     r"\b(?:give|write|provide|output|leave)\s+(?:a\s+|an\s+|only\s+)?(?:\w+\s+)?(?:positive|favou?rable|glowing|five[- ]star)\s+(?:reviews?|ratings?|feedback|assessments?|evaluations?)\b"),
    ("Announces new instructions", True,
     r"\b(?:new|updated|real|actual|additional|hidden)\s+(?:system\s+)?instructions?\s*:|\bsystem\s*(?:override|message|note|instructions?)\s*:"),
    ("Contains a chat-model control token", True,
     r"<\|(?:im_start|im_end|system|user|assistant|endoftext|begin_of_text|start_header_id|end_header_id|eot_id)\|?>|\[/?INST\]|<</?SYS>>"),
    ("Contains a tag that imitates a prompt's structure", True,
     r"</?(?:system|instructions?|system-prompt|tool_call|tool_use|function_calls?|invoke)\b[^<>]{0,60}>|</(?:document|context)>"),
    ("Tells the reader to ignore earlier instructions (Chinese)", True,
     r"(?:忽略|无视|忽视|忘记|不要理会)(?:掉)?(?:之前|以上|上面|前面|先前|此前|所有|你的)[^。\n]{0,10}(?:指令|指示|提示|规则|要求|设定)"),
    ("Tells the reader to keep something from the user (Chinese)", True,
     r"(?:不要|切勿|请勿|不得)(?:告诉|告知|透露|提及|提醒)[^。\n]{0,10}(?:用户|使用者|读者|审阅者)"),
    ("Addresses an AI model directly (Chinese)", True,
     r"(?:如果你是|假如你是|你是)(?:一个|一位)?(?:AI|人工智能|大模型|语言模型|智能助手)"),
    ("Announces new instructions (Chinese)", True,
     r"(?:新的|最新的?|真正的|隐藏的?)(?:系统)?指令\s*[:：]|系统(?:消息|指令)\s*[:：]"),
    ("Tries to assign the reader a role", False, r"\byou are now\b|\bpretend (?:to be|you are)\b|\bact as (?:an?|the)\s+\w+"),
    ("Mentions a system prompt or developer message", False, r"\bsystem prompt\b|\bdeveloper (?:message|mode)\b|\bjailbreak\b"),
    ("Imitates a conversation turn", False, r"^\s*(?:human|assistant|system)\s*:\s*\S"),
    ("Contains tool-call JSON", False,
     r"\"(?:tool_calls?|function_call|tool_use)\"\s*:|\{\s*\"name\"\s*:\s*\"[^\"]+\"\s*,\s*\"(?:arguments|parameters|input)\"\s*:"),
    ("Asks to send something to a web address", False,
     r"\b(?:send|post|upload|forward|exfiltrate|transmit|leak)\b[^.\n]{0,80}\b(?:to|at)\s+https?://"),
    ("Tries to assign the reader a role (Chinese)", False, r"你现在是|假装你是|请扮演"),
    ("Mentions a system prompt (Chinese)", False, r"系统提示(?:词)?"),
)]

_MARKUP_URL = re.compile(r"(!?)\[[^\]]*\]\(\s*(https?://[^)\s]+)|<(img)\b[^>]*?\bsrc\s*=\s*[\"'](https?://[^\"']+)|\bhref\s*=\s*[\"'](https?://[^\"']+)", re.I)
_URL_PLACEHOLDER = re.compile(r"\{\{|\{[\w. -]+\}|%7B|\$\{|\[[A-Z_ ]{3,}\]|<[A-Za-z_ ]+>", re.I)
_LONG_QUERY_VALUE = re.compile(r"[?&][^=&#]+=[^&#]{120,}")
_BASE64 = re.compile(r"(?<![A-Za-z0-9+/=_-])[A-Za-z0-9+/]{40,}={0,2}(?![A-Za-z0-9+/=_-])")
_HEX = re.compile(r"(?<![0-9A-Fa-f])(?:[0-9A-Fa-f]{2}){24,}(?![0-9A-Fa-f])")
_WORD = re.compile(r"[^\W\d_]{3,}")
_BLACK_FLAG = "\U0001F3F4"
_ZERO_WIDTH = "​‌‍⁠⁢⁣⁤﻿"
_ZERO_WIDTH_RUN = re.compile(f"[{_ZERO_WIDTH}]{{8,}}")
_TAG_RUN = re.compile("[\U000E0020-\U000E007E]{2,}")
_SELECTOR_RUN = re.compile("[︀-️\U000E0100-\U000E01EF]{4,}")

_HIT_SEVERITY = {"tag_chars": HIGH, "bidi": MEDIUM, "variation_selector": MEDIUM, "strip": MEDIUM, "zwj_family": MEDIUM,
                 "other_cf": MEDIUM, "private_use": INFO, "noncharacter": INFO, "reserved_ignorable": INFO}
_WEAK_CODEPOINTS = {0x00AD}  # A soft hyphen is ordinary in typeset text.


def _invisible(character: str) -> bool:
    code = ord(character)
    return (unicodedata.category(character) in ("Cf", "Co", "Cn")
            or 0xFE00 <= code <= 0xFE0F or 0xE0100 <= code <= 0xE01EF)


def render_visible(text: str) -> str:
    """*text* with invisible characters written out, as ⟦U+200B⟧ or ⟦U+E0049 … U+E002E, 50 characters⟧."""
    output: list[str] = []
    index, length = 0, len(text)
    while index < length:
        character = text[index]
        # An emoji's own presentation selector isn't worth marking.
        if not _invisible(character) or (ord(character) in (0xFE0E, 0xFE0F) and index and not _invisible(text[index - 1])):
            output.append(character)
            index += 1
            continue
        run = index + 1
        while run < length and _invisible(text[run]):
            run += 1
        chunk = text[index:run]
        if len(set(chunk)) == 1:
            count = f" ×{len(chunk)}" if len(chunk) > 1 else ""
            output.append(f"⟦U+{ord(character):04X}{count}⟧")
        elif len(chunk) <= 3:
            output.append("".join(f"⟦U+{ord(item):04X}⟧" for item in chunk))
        else:
            output.append(f"⟦U+{ord(chunk[0]):04X} … U+{ord(chunk[-1]):04X}, {len(chunk)} characters⟧")
        index = run
    return "".join(output)


def _normalized(text: str) -> str:
    """The text a phrase check should read, past invisible characters and lookalike forms."""
    folded = unicodedata.normalize("NFKC", "".join(ch for ch in text if not _invisible(ch)))
    return re.sub(r"[^\S\n]+", " ", folded)


def _excerpt(text: str, start: int, end: int) -> str:
    first, last = max(0, start - EXCERPT_RADIUS), min(len(text), end + EXCERPT_RADIUS)
    body = " ".join(render_visible(text[first:last]).split())
    return f"{'…' if first else ''}{body}{'…' if last < len(text) else ''}"


def _readable(raw: bytes) -> str | None:
    """*raw* as text, if it's mostly printable."""
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return None
    if len(text) < 3:
        return None
    printable = sum(1 for ch in text if ch.isprintable() or ch in "\n\r\t")
    return text if printable / len(text) >= 0.9 else None


def _finding(technique: str, severity: str, piece: Piece, summary: str, excerpt: str = "", decoded: str | None = None, same_as: str = "") -> dict:
    finding = {"technique": technique, "severity": severity, "location": piece.location, "summary": summary, "excerpt": excerpt,
               "_same_as": same_as or excerpt}
    if decoded is not None:
        finding["decoded"] = " ".join(render_visible(decoded).split())[:600]
    return finding


def _phrase_severity(piece: Piece, strong: bool) -> str:
    if piece.channel == HIDDEN and not piece.ocr:
        return HIGH
    if piece.channel == SIDE:
        return HIGH if strong else MEDIUM
    return MEDIUM if strong else INFO


def _phrases(piece: Piece, text: str) -> list[dict]:
    found = []
    for summary, strong, pattern in _PHRASES:
        for number, match in enumerate(pattern.finditer(text)):
            if number == _MAX_MATCHES_PER_PATTERN:
                break
            found.append(_finding("instruction_phrase", _phrase_severity(piece, strong), piece, summary,
                                  _excerpt(text, match.start(), match.end()), same_as=" ".join(match[0].lower().split())))
    return found


def _decoded_phrase_severity(decoded: str, base: str) -> str:
    text = _normalized(decoded)
    return HIGH if any(strong and pattern.search(text) for _, strong, pattern in _PHRASES) else base


def _smuggled(piece: Piece) -> list[dict]:
    """Messages hidden in invisible characters, decoded."""
    found = []
    text = piece.text
    for match in _TAG_RUN.finditer(text):
        if match.start() and text[match.start() - 1] == _BLACK_FLAG:
            continue  # subdivision flags, such as England's, are built from tag characters
        decoded = "".join(chr(ord(ch) - 0xE0000) for ch in match[0])
        found.append(_finding("smuggled_text", HIGH, piece, "Text hidden in Unicode tag characters",
                              _excerpt(text, match.start(), match.end()), decoded))
    for match in _SELECTOR_RUN.finditer(text):
        values = bytes(ord(ch) - 0xFE00 if ord(ch) <= 0xFE0F else ord(ch) - 0xE0100 + 16 for ch in match[0])
        decoded = _readable(values)
        if decoded:
            found.append(_finding("smuggled_text", HIGH, piece, "Text hidden in variation selectors",
                                  _excerpt(text, match.start(), match.end()), decoded))
    for match in _ZERO_WIDTH_RUN.finditer(text):
        symbols = sorted(set(match[0]))
        if len(symbols) != 2 or len(match[0]) < 24:
            continue
        for zero in symbols:
            bits = "".join("0" if ch == zero else "1" for ch in match[0])
            raw = bytes(int(bits[index:index + 8], 2) for index in range(0, len(bits) - len(bits) % 8, 8))
            decoded = _readable(raw)
            if decoded and all(ch.isprintable() or ch.isspace() for ch in decoded):
                found.append(_finding("smuggled_text", HIGH, piece, "Text hidden in zero-width characters",
                                      _excerpt(text, match.start(), match.end()), decoded))
                break
    return found


def _invisible_characters(piece: Piece) -> list[dict]:
    report = inspect_text(piece.text)
    hits = [hit for hit in report.hits if hit.kind in _HIT_SEVERITY]
    if not hits:
        return []
    severity = INFO
    for hit in hits:
        level = INFO if hit.codepoint in _WEAK_CODEPOINTS else _HIT_SEVERITY[hit.kind]
        if _RANK[level] < _RANK[severity]:
            severity = level
    total = sum(hit.count for hit in hits)
    # Tag characters and selectors spell out a message, so listing each one says nothing.
    grouped = {"tag_chars": "Unicode tag characters", "variation_selector": "variation selectors"}
    labels = [f"{name} ×{sum(hit.count for hit in hits if hit.kind == kind)}" for kind, name in grouped.items() if any(hit.kind == kind for hit in hits)]
    labels += [f"U+{hit.codepoint:04X} ×{hit.count}" for hit in hits if hit.kind not in grouped]
    described = ", ".join(labels[:6])
    if len(labels) > 6:
        described += f" and {len(labels) - 6} more kinds"
    first = next((hit.samples[0] for hit in hits if hit.samples), 0)
    technique = "bidi_control" if all(hit.kind == "bidi" for hit in hits) else "invisible_characters"
    noun = "text-direction control" if technique == "bidi_control" else "invisible character"
    return [_finding(technique, severity, piece, f"{total} {noun}{'' if total == 1 else 's'}: {described}",
                     _excerpt(piece.text, first, first + 1))]


def _links(piece: Piece, source: str) -> list[dict]:
    found = []
    for match in _MARKUP_URL.finditer(source):
        url = match[2] or match[4] or match[5]
        image = bool(match[1] or match[3])
        placeholder = bool(_URL_PLACEHOLDER.search(url))
        if placeholder or _LONG_QUERY_VALUE.search(url):
            severity = HIGH if image and placeholder else MEDIUM
            kind = "An image that loads" if image else "A link to"
            why = "a template placeholder" if placeholder else "a very long query value"
            found.append(_finding("exfiltration_url", severity, piece, f"{kind} a web address containing {why}",
                                  _excerpt(source, match.start(), match.end())))
    return found


def _plain_link(piece: Piece) -> list[dict]:
    if not (_URL_PLACEHOLDER.search(piece.text) or _LONG_QUERY_VALUE.search(piece.text)):
        return []
    return [_finding("exfiltration_url", MEDIUM, piece, "A link whose address carries a placeholder or a very long value",
                     _excerpt(piece.text, 0, min(len(piece.text), 120)))]


def _blobs(piece: Piece) -> list[dict]:
    found = []
    candidates = []
    for match in _BASE64.finditer(piece.text):
        padded = match[0] + "=" * (-len(match[0]) % 4)
        try:
            candidates.append((match, base64.b64decode(padded, validate=True), "base64"))
        except (binascii.Error, ValueError):
            continue
    candidates += [(match, bytes.fromhex(match[0]), "hex") for match in _HEX.finditer(piece.text)]
    for match, raw, name in candidates[:_MAX_BLOBS_PER_PIECE]:
        decoded = _readable(raw)
        if decoded:
            severity = _decoded_phrase_severity(decoded, MEDIUM)
            found.append(_finding("encoded_text", severity, piece, f"Readable text encoded as {name}",
                                  _excerpt(piece.text, match.start(), match.start() + 40), decoded))
    return found


def _confusables(piece: Piece, text: str) -> list[dict]:
    mixed = []
    for match in _WORD.finditer(text):
        scripts = set()
        for character in match[0]:
            name = unicodedata.name(character, "")
            if name.startswith("LATIN "):
                scripts.add("latin")
            elif name.startswith(("CYRILLIC ", "GREEK ")):
                scripts.add("lookalike")
        if len(scripts) == 2:
            mixed.append(match[0])
    if not mixed:
        return []
    samples = ", ".join(dict.fromkeys(mixed[:5]))
    return [_finding("mixed_script", INFO, piece, f"{len(mixed)} word{'' if len(mixed) == 1 else 's'} mixing Latin with lookalike letters", samples)]


def _hidden_text(piece: Piece, raised: bool) -> dict:
    if piece.ocr:
        return _finding("hidden_text", INFO, piece, "An invisible text layer, as scanned PDFs normally have", _excerpt(piece.text, 0, 0))
    characters = len(piece.text)
    summary = f"{characters:,} character{'' if characters == 1 else 's'} of hidden text: {piece.reason}"
    return _finding("hidden_text", HIGH if raised else MEDIUM, piece, summary, _excerpt(piece.text, 0, 0))


def _check(piece: Piece) -> list[dict]:
    text = _normalized(piece.text)
    phrases = _phrases(piece, text)
    findings = phrases + _smuggled(piece) + _invisible_characters(piece) + _blobs(piece) + _confusables(piece, text)
    if piece.location == "Link":
        findings += _plain_link(piece)
    if piece.channel == HIDDEN:
        findings.append(_hidden_text(piece, any(item["severity"] == HIGH for item in phrases)))
    return findings


def _deduplicated(findings: list[dict]) -> list[dict]:
    """One finding per thing found, keeping its most severe sighting.

    A PDF's hidden text also appears in its extracted page text, so the same
    phrase can arrive through two channels.
    """
    kept: dict[tuple, dict] = {}
    for finding in findings:
        key = (finding["technique"], finding["summary"], finding.pop("_same_as"))
        current = kept.get(key)
        if current is None or _RANK[finding["severity"]] < _RANK[current["severity"]]:
            kept[key] = finding
    return sorted(kept.values(), key=lambda item: _RANK[item["severity"]])


def _review_text(pieces: list[Piece]) -> tuple[str, bool]:
    """The text an AI reviewer would need, hidden channels first so a cap can't drop them."""
    order = {HIDDEN: 0, SIDE: 1, VISIBLE: 2}
    parts = []
    for piece in sorted(pieces, key=lambda item: order[item.channel]):
        label = {HIDDEN: "hidden", SIDE: "not on the page", VISIBLE: "visible"}[piece.channel]
        reason = f", {piece.reason}" if piece.reason else ""
        parts.append(f"[{piece.location} ({label}{reason})]\n{render_visible(piece.text)}")
    joined = "\n\n".join(parts)
    return joined[:MAX_REVIEW_CHARS], len(joined) > MAX_REVIEW_CHARS


def scan(path: Path, data: bytes) -> dict:
    """The prompt-injection report for the file at *path*, whose bytes are *data*."""
    try:
        extraction = injection_extract.extract(path, data)
    except injection_extract.ExtractError as exc:
        return {"available": False, "reason": str(exc), "verdict": "none", "findings": [], "notes": []}
    pieces, notes, remaining, cut = [], list(dict.fromkeys(extraction.notes)), MAX_SCANNED_CHARS, False
    for piece in extraction.pieces:
        if remaining <= 0:
            cut = True
            break
        if len(piece.text) > remaining:
            piece.text, cut = piece.text[:remaining], True
        remaining -= len(piece.text)
        pieces.append(piece)
    if cut:
        notes.append(f"Only the first {MAX_SCANNED_CHARS:,} characters were checked.")
    findings: list[dict] = []
    for piece in pieces:
        findings += _check(piece)
    for source in extraction.sources:
        findings += _links(Piece(VISIBLE, "Links in the document", ""), source)
    findings = _deduplicated(findings)
    total = len(findings)
    verdict = "likely" if any(item["severity"] == HIGH for item in findings) else (
        "suspicious" if any(item["severity"] == MEDIUM for item in findings) else "none")
    review, review_cut = _review_text(pieces)
    return {
        "available": True,
        "verdict": verdict,
        "findings": findings[:MAX_FINDINGS],
        "findingsTotal": total,
        "notes": notes,
        "extracted": {"chars": sum(len(piece.text) for piece in pieces), "truncated": cut or review_cut, "parts": len(pieces)},
        "review_text": review,
    }
