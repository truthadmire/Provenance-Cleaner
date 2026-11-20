"""Bound how much text the upstream PNG inspector inflates.

Upstream image_meta._png_text_entries inflates zTXt and compressed iTXt
chunks with zlib.decompress and no output limit, from both inspect_png (the
Inspect path, and PNGs inside Office packages, HTML, SVG and Markdown) and
strip_png (via _text_chunk_is_ai when ordinary text is kept). zlib expands
about 1000 to 1, so a small crafted PNG could make the long-lived helper
allocate gigabytes.

Vendor/ is a checksum-locked snapshot, so the fix is applied here after
import: the same parser, inflating at most MAX_PNG_TEXT_BYTES per image
across all of its text chunks. Real PNG text (generation settings, workflow
JSON, XMP) stays far below that, so ordinary results are unchanged. When the
limit is reached the inspection fails closed: the report says the rest was
not examined and marks the file for review, and a clean drops the text chunk
it could not read in full.

Containers inspect many PNGs for one file (every OOXML media part, every
data: URI in HTML, SVG and Markdown), so the inflated bytes are also charged
to the whole helper request: ``per_request`` opens a budget of
MAX_REQUEST_PNG_TEXT_BYTES that every image inspected or cleaned while
handling one request draws from.  Once it is spent, a later image's
compressed text is not inflated at all; that image is marked for review, and
the report says once that the file's PNG text went over the limit.  Outside
a request only the per-image limit applies.
"""
from __future__ import annotations

import contextlib
import contextvars
import functools
import sys
import zlib
from typing import Any

MAX_PNG_TEXT_BYTES = 16 << 20
MAX_REQUEST_PNG_TEXT_BYTES = 64 << 20
LIMIT_FINDING = "PNG text chunks expand beyond the 16 MiB inspection limit; the rest was not examined"
REQUEST_LIMIT_FINDING = (
    "PNG text in this file's images expands beyond the 64 MiB inspection limit in all; "
    "the rest was not examined, treat this file as unverified"
)


class _Request:
    __slots__ = ("remaining", "notified")

    def __init__(self) -> None:
        self.remaining = MAX_REQUEST_PNG_TEXT_BYTES
        self.notified = False


class _Budget:
    __slots__ = ("remaining", "overflows", "request", "request_capped")

    def __init__(self) -> None:
        self.request = _request.get()
        self.remaining = MAX_PNG_TEXT_BYTES
        self.request_capped = False
        if self.request is not None and self.request.remaining < self.remaining:
            self.remaining = self.request.remaining
            self.request_capped = True
        self.overflows = 0

    def charge(self, size: int) -> None:
        self.remaining -= size
        if self.request is not None:
            self.request.remaining = max(0, self.request.remaining - size)


_request: contextvars.ContextVar[_Request | None] = contextvars.ContextVar("png_text_request", default=None)
_budget: contextvars.ContextVar[_Budget | None] = contextvars.ContextVar("png_text_budget", default=None)

_upstream_inspect_png: Any = None
_upstream_strip_png: Any = None
_upstream_text_chunk_is_ai: Any = None
_upstream_png_text_entries: Any = None  # kept for comparison in tests


@contextlib.contextmanager
def request_budget():
    """Share one inflation budget between every PNG handled inside the block.

    A nested block keeps the outer budget, so a request is never reset halfway.
    """
    request = _request.get()
    if request is not None:
        yield request
        return
    token = _request.set(_Request())
    try:
        yield _request.get()
    finally:
        _request.reset(token)


def per_request(function):
    """Decorator: run *function* inside ``request_budget``."""

    @functools.wraps(function)
    def wrapper(*args: Any, **kwargs: Any) -> Any:
        with request_budget():
            return function(*args, **kwargs)

    return wrapper


class _Scope:
    """Use the active budget, or a fresh one (*fresh*, or when none is active)."""

    def __init__(self, fresh: bool = False) -> None:
        self.fresh = fresh
        self.token: contextvars.Token | None = None

    def __enter__(self) -> _Budget:
        budget = _budget.get()
        if self.fresh or budget is None:
            budget = _Budget()
            self.token = _budget.set(budget)
        return budget

    def __exit__(self, *_exc: object) -> None:
        if self.token is not None:
            _budget.reset(self.token)


def _inflate(data: bytes) -> bytes | None:
    """Inflate *data* within the active budget; None where zlib.decompress would raise."""
    budget = _budget.get()
    assert budget is not None
    inflater = zlib.decompressobj()
    try:
        out = inflater.decompress(data, budget.remaining + 1)
    except zlib.error:
        return None
    if len(out) > budget.remaining:
        budget.overflows += 1
        out = out[: budget.remaining]
        budget.charge(budget.remaining)
        return out
    if not inflater.eof:
        return None  # truncated stream: zlib.decompress raises here
    budget.charge(len(out))
    return out


def bounded_png_text_entries(payload: bytes, ctype: bytes) -> list[tuple[str, str]]:
    """image_meta._png_text_entries, inflating within the per-image budget."""
    with _Scope():
        entries: list[tuple[str, str]] = []
        if ctype == b"tEXt":
            key, sep, text = payload.partition(b"\x00")
            if sep:
                entries.append(
                    (
                        key.decode("latin-1", errors="replace"),
                        text.decode("latin-1", errors="replace"),
                    )
                )
        elif ctype == b"zTXt":
            key, sep, rest = payload.partition(b"\x00")
            if not sep or len(rest) < 2:
                return entries
            text = _inflate(rest[1:])
            if text is None:
                return entries
            entries.append(
                (
                    key.decode("latin-1", errors="replace"),
                    text.decode("latin-1", errors="replace"),
                )
            )
        elif ctype == b"iTXt":
            key, sep, rest = payload.partition(b"\x00")
            if not sep or len(rest) < 4:
                return entries
            comp_flag = rest[0]
            rest = rest[2:]  # skip compression flag + method
            _lang, sep2, rest = rest.partition(b"\x00")
            if not sep2:
                return entries
            _tkey, sep3, text = rest.partition(b"\x00")
            if not sep3:
                return entries
            if comp_flag == 1:
                inflated = _inflate(text)
                if inflated is None:
                    return entries
                text = inflated
            entries.append(
                (
                    key.decode("latin-1", errors="replace"),
                    text.decode("utf-8", errors="replace"),
                )
            )
        return entries


def bounded_text_chunk_is_ai(payload: bytes, ctype: bytes) -> bool:
    """True also when the chunk could not be read in full, so a clean drops it."""
    with _Scope() as budget:
        before = budget.overflows
        result = _upstream_text_chunk_is_ai(payload, ctype)
        return bool(result) or budget.overflows > before


def bounded_inspect_png(data: bytes) -> tuple[bool, bool, list[str]]:
    with _Scope(fresh=True) as budget:
        has_c2pa, has_ai, findings = _upstream_inspect_png(data)
        if budget.overflows:
            has_ai = True
            if not budget.request_capped:
                findings = list(findings) + [LIMIT_FINDING]
            elif budget.request is not None and not budget.request.notified:
                # Said once per request: a container of thousands of such
                # images gets one sentence, and each image is still flagged.
                budget.request.notified = True
                findings = list(findings) + [REQUEST_LIMIT_FINDING]
        return has_c2pa, has_ai, findings


def bounded_strip_png(data: bytes, *, strip_all_text: bool = True) -> tuple[bytes, list[str]]:
    with _Scope(fresh=True):
        return _upstream_strip_png(data, strip_all_text=strip_all_text)


def install(image_meta: Any, container_meta: Any | None = None) -> None:
    """Patch *image_meta* and every loaded module that bound inspect_png or
    strip_png by name at import (container_meta, ...)."""
    global _upstream_inspect_png, _upstream_strip_png, _upstream_text_chunk_is_ai, _upstream_png_text_entries
    if getattr(image_meta.inspect_png, "_png_text_limits", False):
        return
    _upstream_inspect_png = image_meta.inspect_png
    _upstream_strip_png = image_meta.strip_png
    _upstream_text_chunk_is_ai = image_meta._text_chunk_is_ai
    _upstream_png_text_entries = image_meta._png_text_entries
    for function in (bounded_inspect_png, bounded_strip_png, bounded_text_chunk_is_ai, bounded_png_text_entries):
        function._png_text_limits = True  # type: ignore[attr-defined]

    # _png_text_hits and _text_chunk_is_ai look these up in image_meta's
    # globals at call time; inspect_image and clean_image do the same for
    # inspect_png and strip_png.
    image_meta._png_text_entries = bounded_png_text_entries
    image_meta._text_chunk_is_ai = bounded_text_chunk_is_ai
    modules = list(sys.modules.values())
    if container_meta is not None and container_meta not in modules:
        modules.append(container_meta)
    for module in modules:
        namespace = getattr(module, "__dict__", None)
        if not isinstance(namespace, dict):
            continue
        if namespace.get("inspect_png") is _upstream_inspect_png:
            module.inspect_png = bounded_inspect_png
        if namespace.get("strip_png") is _upstream_strip_png:
            module.strip_png = bounded_strip_png
