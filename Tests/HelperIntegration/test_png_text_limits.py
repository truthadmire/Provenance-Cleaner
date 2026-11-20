"""PNG text chunks are inflated within a per-image budget (see Helper/png_text_limits.py)."""
from __future__ import annotations

import base64
import io
import struct
import sys
import tempfile
import time
import tracemalloc
import unittest
import zipfile
import zlib
from pathlib import Path

from test_provenance_helper import CONSERVATIVE_OPTIONS, HelperProcess, _png_chunk, _zip_write

ROOT = Path(__file__).resolve().parents[2]
UPSTREAM = ROOT / "Vendor" / "watermarks-remover" / "service" / "scripts"
sys.path.insert(0, str(ROOT / "Helper"))
sys.path.insert(0, str(UPSTREAM))

import container_meta  # noqa: E402
import image_meta  # noqa: E402

import generator_fields  # noqa: E402
import png_text_limits  # noqa: E402

png_text_limits.install(image_meta, container_meta)
UPSTREAM_ENTRIES = png_text_limits._upstream_png_text_entries
LIMIT = png_text_limits.MAX_PNG_TEXT_BYTES
FINDING = png_text_limits.LIMIT_FINDING
REQUEST_FINDING = png_text_limits.REQUEST_LIMIT_FINDING
REQUEST_LIMIT = png_text_limits.MAX_REQUEST_PNG_TEXT_BYTES
SIG = b"\x89PNG\r\n\x1a\n"


def _deflate_repeated(byte: bytes, size: int) -> bytes:
    """zlib stream of *size* copies of *byte*, built without holding them all."""
    block = byte * (1 << 20)
    compressor = zlib.compressobj(9)
    out = bytearray()
    for _ in range(size >> 20):
        out += compressor.compress(block)
    out += compressor.compress(byte * (size & ((1 << 20) - 1)))
    out += compressor.flush()
    return bytes(out)


def _ztxt(key: bytes, stream: bytes) -> bytes:
    return _png_chunk(b"zTXt", key + b"\x00\x00" + stream)


def _itxt(key: bytes, stream: bytes, compressed: bool = True) -> bytes:
    return _png_chunk(b"iTXt", key + b"\x00" + (b"\x01" if compressed else b"\x00") + b"\x00en\x00\x00" + stream)


def _png(*chunks: bytes) -> bytes:
    header = struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)
    return (SIG + _png_chunk(b"IHDR", header) + b"".join(chunks)
            + _png_chunk(b"IDAT", zlib.compress(b"\x00\x00\x00\x00")) + _png_chunk(b"IEND", b""))


def _chunk_types(data: bytes) -> list[bytes]:
    types, pos = [], 8
    while pos + 8 <= len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        chunk_type = data[pos + 4:pos + 8]
        payload = data[pos + 8:pos + 8 + length]
        crc = struct.unpack(">I", data[pos + 8 + length:pos + 12 + length])[0]
        assert zlib.crc32(chunk_type + payload) & 0xFFFFFFFF == crc
        types.append(chunk_type)
        pos += 12 + length
    return types


BOMB = _deflate_repeated(b"a", 64 << 20)
BOMB_PNG = _png(_ztxt(b"Comment", BOMB))


def _measure(function, *args, **kwargs):
    tracemalloc.start()
    started = time.monotonic()
    try:
        result = function(*args, **kwargs)
        _, peak = tracemalloc.get_traced_memory()
    finally:
        tracemalloc.stop()
    return result, peak, time.monotonic() - started


class Installation(unittest.TestCase):
    def test_upstream_names_point_at_the_bounded_functions(self):
        self.assertIs(image_meta._png_text_entries, png_text_limits.bounded_png_text_entries)
        self.assertIs(image_meta._text_chunk_is_ai, png_text_limits.bounded_text_chunk_is_ai)
        self.assertIs(image_meta.inspect_png, png_text_limits.bounded_inspect_png)
        self.assertIs(container_meta.inspect_png, png_text_limits.bounded_inspect_png)
        self.assertIs(image_meta.strip_png, png_text_limits.bounded_strip_png)
        self.assertIs(container_meta.strip_png, png_text_limits.bounded_strip_png)

    def test_install_twice_keeps_the_original_upstream_functions(self):
        upstream = png_text_limits._upstream_inspect_png
        png_text_limits.install(image_meta, container_meta)
        self.assertIs(png_text_limits._upstream_inspect_png, upstream)
        self.assertFalse(getattr(upstream, "_png_text_limits", False))

    def test_the_shipped_helper_installs_it(self):
        source = (ROOT / "Helper" / "provenance_helper.py").read_text("utf-8")
        self.assertIn("png_text_limits.install(image_meta, container_meta)", source)


class SameAsUpstreamOnOrdinaryInput(unittest.TestCase):
    def test_entries_match_upstream(self):
        text = "Steps: 30, Sampler: Euler a, Model: SDXL".encode()
        cases = [
            (b"tEXt", b"Software\x00ChatGPT"),
            (b"tEXt", b"no separator"),
            (b"zTXt", b"parameters\x00\x00" + zlib.compress(text)),
            (b"zTXt", b"k\x00\x00" + zlib.compress(b"")),
            (b"zTXt", b"k\x00\x00" + zlib.compress(text)[:-3]),  # truncated
            (b"zTXt", b"k\x00\x00" + zlib.compress(text) + b"trailing"),
            (b"zTXt", b"k\x00\x00not zlib"),
            (b"zTXt", b"k\x00\x00"),
            (b"zTXt", b"k\x00\x00\x00"),
            (b"iTXt", b"XML:com.adobe.xmp\x00\x01\x00en\x00\x00" + zlib.compress("c2pa é".encode())),
            (b"iTXt", b"Comment\x00\x00\x00\x00\x00plain \xc3\xa9"),
            (b"iTXt", b"k\x00\x01\x00\x00\x00" + zlib.compress(text)[:-1]),
            (b"iTXt", b"k\x00\x01\x00"),
            (b"iTXt", b"k\x00\x01\x00en"),
            (b"eXIf", b"whatever"),
        ]
        for ctype, payload in cases:
            with self.subTest(ctype=ctype, payload=payload[:20]):
                self.assertEqual(png_text_limits.bounded_png_text_entries(payload, ctype),
                                 UPSTREAM_ENTRIES(payload, ctype))

    def test_ordinary_markers_are_still_detected(self):
        png = _png(_ztxt(b"parameters", zlib.compress(b"Steps: 30, Model: SDXL")),
                   _ztxt(b"Software", zlib.compress(b"ChatGPT")),
                   _itxt(b"XML:com.adobe.xmp", zlib.compress(b"<x:c2pa/> trainedAlgorithmicMedia")))
        has_c2pa, has_ai, findings = image_meta.inspect_png(png)
        self.assertTrue(has_ai)
        self.assertTrue(has_c2pa)
        self.assertNotIn(FINDING, findings)
        self.assertTrue(any("Software=ChatGPT" in finding for finding in findings), findings)
        self.assertEqual((has_c2pa, has_ai, findings), png_text_limits._upstream_inspect_png(png))

    def test_benign_text_is_not_flagged_and_is_kept(self):
        png = _png(_ztxt(b"Comment", zlib.compress(b"Family trip, Singapore, 2026")))
        self.assertEqual(image_meta.inspect_png(png), (False, False, []))
        cleaned, _ = image_meta.strip_png(png, strip_all_text=False)
        self.assertEqual(cleaned, png)

    def test_text_just_under_the_limit_is_read_in_full(self):
        png = _png(_ztxt(b"Comment", _deflate_repeated(b"b", LIMIT - 10)),
                   _ztxt(b"Software", zlib.compress(b"Midjourney")))
        has_c2pa, has_ai, findings = image_meta.inspect_png(png)
        self.assertNotIn(FINDING, findings)
        self.assertTrue(any("Midjourney" in finding for finding in findings), findings)


class Bombs(unittest.TestCase):
    def assert_bounded_inspection(self, png: bytes) -> list[str]:
        (has_c2pa, has_ai, findings), peak, elapsed = _measure(image_meta.inspect_png, png)
        self.assertIn(FINDING, findings)
        self.assertTrue(has_ai)
        self.assertLess(peak, 100 << 20)
        self.assertLess(elapsed, 30)
        return findings

    def test_one_ztxt_bomb(self):
        self.assert_bounded_inspection(BOMB_PNG)

    def test_one_compressed_itxt_bomb(self):
        self.assert_bounded_inspection(_png(_itxt(b"Description", BOMB)))

    def test_the_budget_is_shared_by_all_chunks_of_an_image(self):
        chunk = _ztxt(b"Comment", _deflate_repeated(b"c", 1 << 20))
        findings = self.assert_bounded_inspection(_png(*([chunk] * 20)))
        self.assertEqual(findings.count(FINDING), 1)

    def test_each_image_gets_its_own_budget(self):
        self.assertIn(FINDING, image_meta.inspect_png(BOMB_PNG)[2])
        self.assertEqual(image_meta.inspect_png(_png(_ztxt(b"Comment", zlib.compress(b"hi")))), (False, False, []))

    def test_a_marker_in_the_examined_prefix_is_still_named(self):
        stream = zlib.compress(b"Midjourney " + b"x" * (LIMIT + 10))
        has_c2pa, has_ai, findings = image_meta.inspect_png(_png(_ztxt(b"Software", stream)))
        self.assertIn(FINDING, findings)
        self.assertTrue(any("Software=Midjourney" in finding for finding in findings), findings)

    def test_clean_drops_the_unreadable_chunk_and_keeps_the_image(self):
        (cleaned, actions), peak, _ = _measure(image_meta.strip_png, BOMB_PNG, strip_all_text=False)
        self.assertLess(peak, 100 << 20)
        self.assertIn("drop chunk zTXt", actions)
        self.assertEqual(_chunk_types(cleaned), [b"IHDR", b"IDAT", b"IEND"])

    def test_text_chunk_is_ai_outside_a_scope(self):
        payload = b"Comment\x00\x00" + BOMB
        self.assertTrue(image_meta._text_chunk_is_ai(payload, b"zTXt"))
        self.assertFalse(image_meta._text_chunk_is_ai(b"Comment\x00\x00" + zlib.compress(b"hi"), b"zTXt"))

    def test_office_media_png_goes_through_the_bounded_inspector(self):
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, "w") as docx:
            _zip_write(docx, "[Content_Types].xml",
                       '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
                       '<Default Extension="png" ContentType="image/png"/></Types>')
            _zip_write(docx, "word/document.xml", '<?xml version="1.0"?><w:document '
                       'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body/></w:document>')
            entry = zipfile.ZipInfo("word/media/bomb.png", date_time=(2000, 1, 1, 0, 0, 0))
            docx.writestr(entry, BOMB_PNG, compress_type=zipfile.ZIP_STORED)
        (_c2pa, has_ai, findings, _details), peak, _ = _measure(container_meta.inspect_docx, archive.getvalue())
        self.assertTrue(has_ai)
        self.assertIn(f"word/media/bomb.png: {FINDING}", findings)
        self.assertLess(peak, 200 << 20)


class GeneratorFieldsBudget(unittest.TestCase):
    def test_total_inflation_across_chunks_is_bounded(self):
        chunk = _ztxt(b"Comment", _deflate_repeated(b"d", 1 << 20))
        png = _png(*([chunk] * 40), _ztxt(b"parameters", zlib.compress(b"Steps: 30")))
        calls = []
        original = generator_fields._inflate

        def counting(data, limit=generator_fields.MAX_TEXT):
            out = original(data, limit)
            calls.append(len(out))
            return out

        generator_fields._inflate = counting
        try:
            generator_fields._png_hits(png)
        finally:
            generator_fields._inflate = original
        self.assertLessEqual(sum(calls), generator_fields.MAX_PNG_TEXT)

    def test_ordinary_settings_are_still_found(self):
        png = _png(_ztxt(b"parameters", zlib.compress(b"Steps: 30")),
                   _itxt(b"prompt", zlib.compress(b"{\"1\": {}}")))
        tags = [hit["tag"] for hit in generator_fields._png_hits(png)]
        self.assertEqual(tags, ["parameters", "prompt"])


def _docx_with_media(pngs: list[bytes]) -> bytes:
    archive = io.BytesIO()
    with zipfile.ZipFile(archive, "w") as docx:
        _zip_write(docx, "[Content_Types].xml",
                   '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
                   '<Default Extension="png" ContentType="image/png"/></Types>')
        _zip_write(docx, "word/document.xml", '<?xml version="1.0"?><w:document '
                   'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body/></w:document>')
        for index, png in enumerate(pngs):
            entry = zipfile.ZipInfo(f"word/media/b{index}.png", date_time=(2000, 1, 1, 0, 0, 0))
            docx.writestr(entry, png, compress_type=zipfile.ZIP_STORED)
    return archive.getvalue()


class _CountInflation:
    """Count the bytes the bounded inflater hands back."""

    def __enter__(self):
        self.total = 0
        self.original = png_text_limits._inflate

        def counting(data):
            out = self.original(data)
            self.total += len(out or b"")
            return out

        png_text_limits._inflate = counting
        return self

    def __exit__(self, *_exc):
        png_text_limits._inflate = self.original


class RequestBudget(unittest.TestCase):
    """One helper request shares MAX_REQUEST_PNG_TEXT_BYTES across all its PNGs."""

    def test_many_bomb_images_in_one_container_stop_at_the_request_limit(self):
        docx = _docx_with_media([BOMB_PNG] * 40)
        with png_text_limits.request_budget() as request, _CountInflation() as counted:
            (_c2pa, has_ai, findings, _details), peak, elapsed = _measure(container_meta.inspect_docx, docx)
        self.assertTrue(has_ai)
        self.assertEqual(request.remaining, 0)
        self.assertLessEqual(counted.total, REQUEST_LIMIT)
        # Four images use their own 16 MiB each; the rest are not inflated.
        self.assertEqual(sum(f.endswith(FINDING) for f in findings), REQUEST_LIMIT // LIMIT)
        # The fifth image meets the spent request budget: said once for the file.
        self.assertEqual(sum(f.endswith(REQUEST_FINDING) for f in findings), 1)
        self.assertLess(peak, 200 << 20)
        self.assertLess(elapsed, 30)

    def test_the_request_finding_is_said_once_and_every_later_image_is_flagged(self):
        half = _png(_ztxt(b"Comment", _deflate_repeated(b"a", LIMIT - 1)))  # fully read, no per-image finding
        pngs = [half] * 4 + [BOMB_PNG] * 3
        with png_text_limits.request_budget():
            results = [image_meta.inspect_png(png) for png in pngs]
        flat = [finding for _c, _a, findings in results for finding in findings]
        self.assertEqual(flat.count(REQUEST_FINDING), 1)
        self.assertNotIn(FINDING, flat)
        self.assertEqual([has_ai for _c, has_ai, _f in results], [False] * 4 + [True] * 3)

    def test_html_data_uris_share_the_request_budget(self):
        uri = "data:image/png;base64," + base64.b64encode(BOMB_PNG).decode()
        html = "<html><body>" + "".join(f'<img src="{uri}">' for _ in range(30)) + "</body></html>"
        with png_text_limits.request_budget() as request, _CountInflation() as counted:
            (_c2pa, has_ai, findings, _details), _peak, elapsed = _measure(container_meta.inspect_html, html)
        self.assertTrue(has_ai)
        self.assertEqual(request.remaining, 0)
        self.assertLessEqual(counted.total, REQUEST_LIMIT)
        self.assertLess(elapsed, 30)

    def test_ordinary_text_in_many_images_is_unaffected(self):
        marked = _png(_ztxt(b"Software", zlib.compress(b"ChatGPT")))
        benign = _png(_ztxt(b"Comment", zlib.compress(b"Family trip")))
        with png_text_limits.request_budget():
            results = [image_meta.inspect_png(marked if i % 2 else benign) for i in range(500)]
            kept, _ = image_meta.strip_png(benign, strip_all_text=False)
        for index, result in enumerate(results):
            expected = png_text_limits._upstream_inspect_png(marked if index % 2 else benign)
            self.assertEqual(result, expected)
        self.assertEqual(kept, benign)

    def test_clean_after_the_request_is_spent_drops_compressed_text(self):
        benign = _png(_ztxt(b"Comment", zlib.compress(b"Family trip")))
        with png_text_limits.request_budget():
            for _ in range(REQUEST_LIMIT // LIMIT):
                image_meta.inspect_png(BOMB_PNG)
            cleaned, actions = image_meta.strip_png(benign, strip_all_text=False)
        self.assertIn("drop chunk zTXt", actions)
        self.assertEqual(_chunk_types(cleaned), [b"IHDR", b"IDAT", b"IEND"])

    def test_nested_blocks_keep_the_outer_budget(self):
        with png_text_limits.request_budget() as outer:
            image_meta.inspect_png(BOMB_PNG)
            with png_text_limits.request_budget() as inner:
                self.assertIs(inner, outer)
            self.assertEqual(outer.remaining, REQUEST_LIMIT - LIMIT)
        self.assertIsNone(png_text_limits._request.get())

    def test_the_shipped_helper_opens_a_request_budget(self):
        source = (ROOT / "Helper" / "provenance_helper.py").read_text("utf-8")
        for name in ("_inspect_response", "_scan_response", "_clean_response"):
            self.assertIn(f"@png_text_limits.per_request  # one PNG text inflation budget per request\ndef {name}(",
                          source)


class WorstCaseMemory(unittest.TestCase):
    def test_itxt_of_invalid_utf8_stays_bounded(self):
        # Each 0xFF byte decodes to U+FFFD and re-encodes to three bytes in
        # _png_text_hits, the largest expansion on the patched path.
        png = _png(_itxt(b"Description", _deflate_repeated(b"\xff", LIMIT + (1 << 20))))
        (_c2pa, has_ai, findings), peak, _ = _measure(image_meta.inspect_png, png)
        self.assertTrue(has_ai)
        self.assertIn(FINDING, findings)
        self.assertLess(peak, 256 << 20)


class ThroughTheHelper(unittest.TestCase):
    def setUp(self):
        self.helper = HelperProcess()
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)

    def tearDown(self):
        self.helper.close()
        self.directory.cleanup()

    def test_inspect_reports_the_limit_and_clean_drops_the_chunk(self):
        path = self.root / "bomb.png"
        path.write_bytes(_png(_ztxt(b"Comment", BOMB), _ztxt(b"Title", zlib.compress(b"Holiday"))))
        inspected = self.helper.exchange({"requestID": "i", "operation": "inspect", "inputPath": str(path)}, timeout=120)
        self.assertTrue(inspected["ok"], inspected)
        report = inspected["report"]
        self.assertIn(FINDING, report["findings"])
        self.assertIs(report["has_ai_metadata"], True)

        output = self.root / "out.png"
        cleaned = self.helper.exchange({"requestID": "c", "operation": "clean", "inputPath": str(path),
                                        "outputPath": str(output), "options": CONSERVATIVE_OPTIONS}, timeout=120)
        self.assertTrue(cleaned["ok"], cleaned)
        result = output.read_bytes()
        self.assertNotIn(b"zTXt", result)
        self.assertIn(b"IDAT", result)
        self.assertEqual(_chunk_types(result)[0], b"IHDR")

    def test_one_request_shares_the_budget_across_embedded_images(self):
        path = self.root / "many.html"
        uri = "data:image/png;base64," + base64.b64encode(BOMB_PNG).decode()
        path.write_text("<html><body>" + "".join(f'<img src="{uri}">' for _ in range(12)) + "</body></html>")
        started = time.monotonic()
        inspected = self.helper.exchange({"requestID": "h", "operation": "inspect", "inputPath": str(path)}, timeout=120)
        self.assertTrue(inspected["ok"], inspected)
        self.assertLess(time.monotonic() - started, 60)
        self.assertIs(inspected["report"]["has_ai_metadata"], True)
        # The next request starts with a full budget again.
        single = self.root / "one.png"
        single.write_bytes(_png(_ztxt(b"Comment", _deflate_repeated(b"a", LIMIT - 10)), _ztxt(b"Software", zlib.compress(b"Midjourney"))))
        again = self.helper.exchange({"requestID": "o", "operation": "inspect", "inputPath": str(single)}, timeout=120)
        self.assertTrue(again["ok"], again)
        self.assertNotIn(FINDING, again["report"]["findings"])
        self.assertNotIn(REQUEST_FINDING, again["report"]["findings"])


if __name__ == "__main__":
    unittest.main()
