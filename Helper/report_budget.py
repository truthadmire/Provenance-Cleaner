"""Keep inspection memory and report size bounded for hostile inputs.

The locked upstream inspectors grow without limit on two shapes of input:

* ``text_unicode.inspect_text`` stores every offset of every suspicious
  character although only the first ten are reported, and serializes one hit
  per distinct (codepoint, kind), so a text of many distinct private-use
  characters makes a report larger than the app accepts.
* ``image_meta.inspect_jpeg`` walks every header segment before SOS and adds
  up to two findings per segment, so a JPEG of millions of tiny APP11
  segments builds millions of findings.

``install`` replaces both functions with bounded versions.  Counts stay exact,
ordinary files give exactly the upstream result, and a file that goes over a
limit is reported as such (and as suspicious) rather than quietly trimmed.

Containers call both inspectors many times for one file (every data: URI in
HTML/Markdown/SVG, every OOXML media part, every EPUB page), so the limits
also apply to a whole request: ``per_request`` opens a budget that every call
made while handling one helper request draws from.  Outside a request only
the per-call limits apply.
"""
from __future__ import annotations

import contextlib
import functools
import struct
import sys
from typing import Any

MAX_TEXT_HITS = 200
SAMPLE_OFFSETS = 10
MAX_JPEG_SEGMENTS = 4096
# Whole-request budgets.  One JPEG at the per-call cap (up to two findings per
# segment plus the byte-scan and cap findings) always fits, so a single image
# is reported exactly as before.
MAX_REPORT_JPEG_SEGMENTS = 4 * MAX_JPEG_SEGMENTS
MAX_REPORT_JPEG_FINDINGS = 2 * MAX_JPEG_SEGMENTS + 2
MAX_REPORT_TEXT_HITS = 5 * MAX_TEXT_HITS

JPEG_SEGMENT_LIMIT_FINDING = (
    f"JPEG has more than {MAX_JPEG_SEGMENTS} metadata segments; inspection stopped "
    "early, treat this file as unverified"
)
JPEG_REPORT_SEGMENT_FINDING = (
    f"JPEG metadata not fully inspected: this file's images have more than "
    f"{MAX_REPORT_JPEG_SEGMENTS} metadata segments in all; treat this file as unverified"
)
JPEG_REPORT_FINDING_LIMIT = (
    f"More JPEG findings were not listed: this file's images have more than "
    f"{MAX_REPORT_JPEG_FINDINGS} in all; treat this file as unverified"
)

_CONFIDENCE_RANK = {"confirmed": 0, "probable": 1, "informational": 2}

_text_unicode: Any = None
_image_meta: Any = None
_upstream_inspect_jpeg: Any = None
_upstream_inspect_text: Any = None
_BoundedReport: Any = None


class _RequestBudget:
    __slots__ = ("jpeg_segments", "jpeg_findings", "jpeg_findings_notice", "text_hits")

    def __init__(self) -> None:
        self.jpeg_segments = MAX_REPORT_JPEG_SEGMENTS
        self.jpeg_findings = MAX_REPORT_JPEG_FINDINGS
        self.jpeg_findings_notice = False
        self.text_hits = MAX_REPORT_TEXT_HITS


_request: _RequestBudget | None = None


@contextlib.contextmanager
def request_budget():
    """Share one budget between every inspector call inside the block.

    A nested block keeps the outer budget, so a request is never reset halfway.
    """
    global _request
    if _request is not None:
        yield _request
        return
    _request = _RequestBudget()
    try:
        yield _request
    finally:
        _request = None


def per_request(function):
    """Decorator: run *function* inside ``request_budget``."""

    @functools.wraps(function)
    def wrapper(*args: Any, **kwargs: Any) -> Any:
        with request_budget():
            return function(*args, **kwargs)

    return wrapper


def _report_class(text_unicode: Any) -> type:
    base = text_unicode.TextInspectReport

    class BoundedTextInspectReport(base):  # type: ignore[misc, valid-type]
        """Upstream report whose serialized hit list has a budget."""

        def to_dict(self) -> dict:
            result = base.to_dict(self)
            limit = getattr(self, "_listed_limit", None)
            if limit is None:
                # Decided once per report, so serializing it twice neither
                # charges the request twice nor lists it differently.
                limit = MAX_TEXT_HITS
                if _request is not None:
                    limit = min(limit, _request.text_hits)
                    _request.text_hits -= min(limit, len(self.hits))
                self._listed_limit = limit
            if len(self.hits) <= limit:
                return result
            confidence = text_unicode._hit_confidence
            order = sorted(
                range(len(self.hits)),
                key=lambda index: (
                    _CONFIDENCE_RANK.get(confidence(self.hits[index].kind), 3),
                    -self.hits[index].count,
                    self.hits[index].codepoint,
                ),
            )
            kept = sorted(order[:limit])
            omitted = [self.hits[index] for index in order[limit:]]
            omitted_occurrences = sum(hit.count for hit in omitted)
            strongest = min(
                (confidence(hit.kind) for hit in omitted),
                key=lambda value: _CONFIDENCE_RANK.get(value, 3),
            )
            hits = [result["hits"][index] for index in kept]
            hits.append(
                {
                    "codepoint": "various",
                    "label": f"{len(omitted)} more invisible-character kinds not listed",
                    "count": omitted_occurrences,
                    "kind": "other_cf",
                    "confidence": strongest,
                    "sample_offsets": [],
                }
            )
            result["hits"] = hits
            result["hits_truncated"] = True
            result["hits_total"] = len(self.hits)
            result["hits_omitted_occurrences"] = omitted_occurrences
            result["notes"] = list(result["notes"]) + [
                f"Only {limit} of {len(self.hits)} distinct suspicious character "
                f"kinds are listed; {omitted_occurrences} occurrences of the other kinds "
                "are counted in suspicious_total."
            ]
            return result

    BoundedTextInspectReport.__name__ = "TextInspectReport"
    BoundedTextInspectReport.__qualname__ = "TextInspectReport"
    return BoundedTextInspectReport


def bounded_inspect_text(
    text: str,
    *,
    aggressive: bool = False,
    strip_emoji_glue: bool = False,
):
    """``text_unicode.inspect_text`` keeping only the first offsets per hit.

    The loop mirrors upstream exactly; each bucket holds a running count and
    the first ``SAMPLE_OFFSETS`` offsets instead of every offset.
    """
    tu = _text_unicode
    buckets: dict[tuple[int, str], list[Any]] = {}
    prev_kept: str | None = None
    valid_flag_tags = tu._valid_flag_tag_indices(text)
    valid_bidi_embeddings = tu._valid_bidi_embedding_indices(text)
    decide = tu._decide
    is_glue = tu._is_glue
    length = len(text)
    for i, ch in enumerate(text):
        action, out_char, kind = decide(
            ch,
            prev_kept,
            text[i - 1] if i > 0 else None,
            text[i + 1] if i + 1 < length else None,
            valid_flag_tag=i in valid_flag_tags,
            valid_bidi_embedding=i in valid_bidi_embeddings,
            normalize_spaces=True,
            treat_confusables=aggressive,
            strip_emoji_glue=strip_emoji_glue,
            strip_bidi=True,
        )
        if kind is None:
            if not is_glue(ord(ch)):
                prev_kept = out_char
            continue
        key = (ord(ch), kind)
        bucket = buckets.get(key)
        if bucket is None:
            buckets[key] = [1, [i]]
        else:
            bucket[0] += 1
            if len(bucket[1]) < SAMPLE_OFFSETS:
                bucket[1].append(i)
        if action == "replace":
            prev_kept = out_char

    hits = []
    total = 0
    for (cp, kind), (count, samples) in sorted(buckets.items(), key=lambda x: (-x[1][0], x[0][0])):
        ch = chr(cp)
        hits.append(
            tu.CharHit(
                codepoint=cp,
                char=ch,
                label=tu._char_label(ch),
                count=count,
                kind=kind,
                samples=samples,
            )
        )
        total += count

    # Upstream notes depend only on whether there are hits; install() takes
    # both variants from upstream itself.
    notes = list(_UPSTREAM_NOTES_WITH_HITS if hits else _UPSTREAM_NOTES_WITHOUT_HITS)
    return _BoundedReport(length=length, suspicious_total=total, hits=hits, notes=notes)


_UPSTREAM_NOTES_WITH_HITS: list[str] = []
_UPSTREAM_NOTES_WITHOUT_HITS: list[str] = []


def _jpeg_segment_limit_end(data: bytes, limit: int = MAX_JPEG_SEGMENTS) -> tuple[int, int | None]:
    """Count header segments, stopping once there are more than *limit*.

    Returns ``(segments, cap_end)``: *cap_end* is the offset just past segment
    *limit* (2, just past SOI, when *limit* is 0) when the file has more than
    *limit* segments, else ``None``.  Mirrors the marker walk of upstream
    ``inspect_jpeg`` (fill bytes, SOI/EOI, RSTn, stop at SOS or a bad length).
    """
    if not data.startswith(b"\xff\xd8"):
        return 0, None
    i = 2
    n = len(data)
    segments = 0
    cap_end = 2
    while i + 4 <= n:
        if data[i] != 0xFF:
            found = data.find(b"\xff", i)
            i = found if found >= 0 else n
            continue
        while i < n and data[i] == 0xFF:
            i += 1
        if i >= n:
            break
        marker = data[i]
        i += 1
        if marker in (0xD8, 0xD9):
            continue
        if marker == 0xDA:
            break
        if 0xD0 <= marker <= 0xD7:
            continue
        if i + 2 > n:
            break
        seglen = struct.unpack(">H", data[i : i + 2])[0]
        if seglen < 2 or i + seglen > n:
            break
        i += seglen
        segments += 1
        if segments == limit:
            cap_end = i
        elif segments > limit:
            return segments, cap_end
    return segments, None


def _single_inspect_jpeg(data: bytes, limit: int, limit_finding: str) -> tuple[bool, bool, list[str], int]:
    segments, cap_end = _jpeg_segment_limit_end(data, limit)
    if cap_end is None:
        has_c2pa, has_ai, findings = _upstream_inspect_jpeg(data)
        return has_c2pa, has_ai, findings, segments
    if limit > 0:
        has_c2pa, has_ai, findings = _upstream_inspect_jpeg(data[:cap_end] + b"\xff\xd9")
        findings = list(findings)
    else:
        has_c2pa, findings = False, []
    if not has_c2pa:
        whole = _image_meta._contains_any(data, _image_meta.JPEG_C2PA_MARKERS)
        if whole:
            has_c2pa = True
            findings.append(f"byte-scan C2PA markers: {', '.join(whole[:6])}")
    findings.append(limit_finding)
    return has_c2pa, True, findings, limit


def bounded_inspect_jpeg(data: bytes) -> tuple[bool, bool, list[str]]:
    """``image_meta.inspect_jpeg`` with a cap on header segments.

    Files within the cap get the upstream result unchanged.  Past the cap the
    first ``MAX_JPEG_SEGMENTS`` segments are inspected by upstream, the
    whole-file C2PA byte scan still covers every byte, and the file is marked
    as suspicious with a finding that says inspection stopped early.

    Inside ``request_budget`` all calls share ``MAX_REPORT_JPEG_SEGMENTS``
    inspected segments and ``MAX_REPORT_JPEG_FINDINGS`` listed findings.  An
    image past the segment budget is only byte-scanned and is suspicious; past
    the findings budget, one notice replaces the rest of the list and every
    image whose findings were dropped is suspicious.
    """
    budget = _request
    if budget is None:
        has_c2pa, has_ai, findings, _ = _single_inspect_jpeg(data, MAX_JPEG_SEGMENTS, JPEG_SEGMENT_LIMIT_FINDING)
        return has_c2pa, has_ai, findings
    if budget.jpeg_segments >= MAX_JPEG_SEGMENTS:
        limit, limit_finding = MAX_JPEG_SEGMENTS, JPEG_SEGMENT_LIMIT_FINDING
    else:
        limit, limit_finding = budget.jpeg_segments, JPEG_REPORT_SEGMENT_FINDING
    has_c2pa, has_ai, findings, used = _single_inspect_jpeg(data, limit, limit_finding)
    budget.jpeg_segments -= used
    if len(findings) <= budget.jpeg_findings:
        budget.jpeg_findings -= len(findings)
        return has_c2pa, has_ai, findings
    findings = list(findings[: budget.jpeg_findings])
    budget.jpeg_findings = 0
    if not budget.jpeg_findings_notice:
        budget.jpeg_findings_notice = True
        findings.append(JPEG_REPORT_FINDING_LIMIT)
    return has_c2pa, True, findings


def install(text_unicode: Any, image_meta: Any) -> None:
    """Replace the upstream inspectors in *text_unicode*, *image_meta* and in
    every loaded module that bound them by name at import (server,
    container_meta, ...).  Modules imported later pick up the patched
    attributes from text_unicode / image_meta."""
    global _text_unicode, _image_meta, _upstream_inspect_jpeg, _upstream_inspect_text, _BoundedReport
    global _UPSTREAM_NOTES_WITH_HITS, _UPSTREAM_NOTES_WITHOUT_HITS
    if getattr(text_unicode.inspect_text, "_report_budget", False):
        return
    _text_unicode = text_unicode
    _image_meta = image_meta
    _upstream_inspect_jpeg = image_meta.inspect_jpeg
    _upstream_inspect_text = text_unicode.inspect_text
    _BoundedReport = _report_class(text_unicode)
    _UPSTREAM_NOTES_WITHOUT_HITS = list(text_unicode.inspect_text("").notes)
    _UPSTREAM_NOTES_WITH_HITS = list(text_unicode.inspect_text(chr(0x200B)).notes)

    bounded_inspect_text._report_budget = True  # type: ignore[attr-defined]
    bounded_inspect_jpeg._report_budget = True  # type: ignore[attr-defined]
    upstream_text = text_unicode.inspect_text
    upstream_jpeg = image_meta.inspect_jpeg
    for module in list(sys.modules.values()):
        namespace = getattr(module, "__dict__", None)
        if not isinstance(namespace, dict):
            continue
        if namespace.get("inspect_text") is upstream_text:
            module.inspect_text = bounded_inspect_text
        if namespace.get("inspect_jpeg") is upstream_jpeg:
            module.inspect_jpeg = bounded_inspect_jpeg
