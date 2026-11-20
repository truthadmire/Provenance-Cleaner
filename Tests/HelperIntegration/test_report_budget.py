from __future__ import annotations

import base64
import io
import json
import struct
import subprocess
import sys
import tempfile
import time
import tracemalloc
import unittest
import zipfile
from pathlib import Path

from test_provenance_helper import HelperProcess, _JPEG_1X1, _jpeg_segment

ROOT = Path(__file__).resolve().parents[2]
UPSTREAM = ROOT / "Vendor" / "watermarks-remover" / "service" / "scripts"
sys.path.insert(0, str(ROOT / "Helper"))
sys.path.insert(0, str(UPSTREAM))

import image_meta  # noqa: E402
import text_unicode  # noqa: E402

import report_budget  # noqa: E402

report_budget.install(text_unicode, image_meta)
UPSTREAM_INSPECT_TEXT = report_budget._upstream_inspect_text
UPSTREAM_INSPECT_JPEG = report_budget._upstream_inspect_jpeg

APP_RESPONSE_LIMIT = 16 << 20


def _jpeg(*segments: bytes) -> bytes:
    # SOI, then header segments, then the rest of a real 1x1 JPEG.
    return _JPEG_1X1[:2] + b"".join(segments) + _JPEG_1X1[2:]


def _pua_text(count: int, start: int = 0) -> str:
    return "".join(chr(0xF0000 + start + index) for index in range(count))


# A JPEG right at the per-call cap: 4096 four-byte APP11 "c2pa" segments,
# two findings each, so upstream lists 8192 findings for it.
CAP_JPEG = b"\xff\xd8" + b"\xff\xeb\x00\x06c2pa" * report_budget.MAX_JPEG_SEGMENTS + b"\xff\xd9"
# A benign JPEG right at the cap: comments without hints give no findings.
BENIGN_CAP_JPEG = b"\xff\xd8" + b"\xff\xfe\x00\x03x" * report_budget.MAX_JPEG_SEGMENTS + b"\xff\xd9"


def _docx(media: list[bytes]) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("[Content_Types].xml", "<Types/>")
        archive.writestr("word/document.xml", "<w:document/>")
        for index, image in enumerate(media):
            archive.writestr(f"word/media/image{index}.jpeg", image)
    return buffer.getvalue()


def _html_with_data_uris(images: list[bytes]) -> bytes:
    tags = "".join(
        f'<img src="data:image/jpeg;base64,{base64.b64encode(image).decode()}">' for image in images
    )
    return f"<html><body><p>hi</p>{tags}</body></html>".encode()


def _epub(pages: list[str]) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip")
        archive.writestr(
            "META-INF/container.xml",
            '<?xml version="1.0"?><container version="1.0" '
            'xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'
            '<rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>'
            "</rootfiles></container>",
        )
        archive.writestr("OEBPS/content.opf", '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf"/>')
        for index, page in enumerate(pages):
            archive.writestr(f"OEBPS/page{index}.xhtml", f"<html><body><p>{page}</p></body></html>")
    return buffer.getvalue()


CORPUS = [
    "",
    "plain text with nothing hidden",
    "a\u200bb\u200cc\u200dd\u2060e\ufeff",
    "abc \u202eevil\u202c \u202aok\u202c \u2066iso\u2069",
    "flag \U0001F3F4\U000E0067\U000E0062\U000E0073\U000E0063\U000E0074\U000E007F and stray \U000E0041",
    "vs \ufe0f\ufe0e x\ufe0f \U000E0100",
    "pua \ue000\ue001\U000F0000",
    "spaces\u00a0\u2009\u202f\u3000here",
    "confusables \u0430\u0435\u043e and Latin",
    "emoji \U0001F468\u200d\U0001F469\u200d\U0001F467 glue",
    "\u200b" * 37 + "x" + "\u2062" * 5,
]


class TextBudgetTests(unittest.TestCase):
    def test_matches_upstream_on_ordinary_inputs(self) -> None:
        for text in CORPUS:
            for aggressive in (False, True):
                for glue in (False, True):
                    with self.subTest(text=text, aggressive=aggressive, glue=glue):
                        expected = UPSTREAM_INSPECT_TEXT(text, aggressive=aggressive, strip_emoji_glue=glue)
                        actual = report_budget.bounded_inspect_text(text, aggressive=aggressive, strip_emoji_glue=glue)
                        self.assertEqual(actual.to_dict(), expected.to_dict())
                        self.assertEqual(actual.hits, expected.hits)
                        self.assertEqual(actual.length, expected.length)

    def test_many_occurrences_keep_exact_counts_without_storing_offsets(self) -> None:
        text = "\u200b" * 1_000_000
        tracemalloc.start()
        try:
            report = report_budget.bounded_inspect_text(text)
            _, peak = tracemalloc.get_traced_memory()
        finally:
            tracemalloc.stop()
        self.assertEqual(report.suspicious_total, 1_000_000)
        self.assertEqual(len(report.hits), 1)
        self.assertEqual(report.hits[0].count, 1_000_000)
        self.assertEqual(report.hits[0].samples, list(range(10)))
        self.assertLess(peak, 5 << 20)

    def test_many_distinct_kinds_are_listed_within_a_budget(self) -> None:
        text = _pua_text(65_534)
        report = report_budget.bounded_inspect_text(text)
        self.assertEqual(len(report.hits), 65_534)
        payload = report.to_dict()
        self.assertTrue(payload["hits_truncated"])
        self.assertEqual(payload["hits_total"], 65_534)
        self.assertEqual(payload["suspicious_total"], 65_534)
        self.assertLessEqual(len(payload["hits"]), report_budget.MAX_TEXT_HITS + 1)
        self.assertEqual(payload["hits_omitted_occurrences"], 65_534 - report_budget.MAX_TEXT_HITS)
        summary = payload["hits"][-1]
        self.assertEqual(summary["count"], 65_534 - report_budget.MAX_TEXT_HITS)
        self.assertIn("not listed", summary["label"])
        self.assertIn("codepoint", summary)
        self.assertLess(len(json.dumps(payload)), 1 << 20)

    def test_truncation_prefers_stronger_confidence(self) -> None:
        # The space homoglyph is informational and far more frequent than any
        # single private-use character, yet the probable kinds are listed
        # first and the omitted remainder still reports "probable".
        text = _pua_text(300) + chr(0xA0) * 5000
        payload = report_budget.bounded_inspect_text(text).to_dict()
        self.assertTrue(payload["hits_truncated"])
        self.assertEqual(payload["suspicious_total"], 5300)
        listed = payload["hits"][:-1]
        self.assertEqual(len(listed), report_budget.MAX_TEXT_HITS)
        self.assertTrue(all(hit["confidence"] == "probable" for hit in listed))
        self.assertEqual(payload["hits"][-1]["confidence"], "probable")
        self.assertEqual(payload["hits_omitted_occurrences"], 5100)

    def test_upstream_references_are_the_locked_functions(self) -> None:
        self.assertIsNot(UPSTREAM_INSPECT_TEXT, report_budget.bounded_inspect_text)
        self.assertIsNot(UPSTREAM_INSPECT_JPEG, report_budget.bounded_inspect_jpeg)
        self.assertEqual(UPSTREAM_INSPECT_TEXT.__module__, "text_unicode")
        self.assertEqual(UPSTREAM_INSPECT_JPEG.__module__, "image_meta")


class JpegBudgetTests(unittest.TestCase):
    def test_ordinary_jpeg_matches_upstream(self) -> None:
        xmp = b"http://ns.adobe.com/xap/1.0/\x00<x:xmpmeta>DigitalSourceType trainedAlgorithmicMedia</x:xmpmeta>"
        samples = [
            _JPEG_1X1,
            _jpeg(_jpeg_segment(0xE1, xmp)),
            _jpeg(_jpeg_segment(0xE1, xmp), _jpeg_segment(0xEB, b"JP\x00\x01jumbc2pa")),
            _jpeg(_jpeg_segment(0xFE, b"made with midjourney")),
            _jpeg(*[_jpeg_segment(0xE0, b"x") for _ in range(report_budget.MAX_JPEG_SEGMENTS - 20)]),
            b"\xff\xd8\xff\xe1\x00",
            b"not a jpeg",
        ]
        for data in samples:
            with self.subTest(size=len(data)):
                self.assertEqual(report_budget.bounded_inspect_jpeg(data), UPSTREAM_INSPECT_JPEG(data))

    def test_segment_flood_is_bounded_and_fails_closed(self) -> None:
        data = _jpeg(*[_jpeg_segment(0xEB, b"c2pa") for _ in range(50_000)])
        started = time.monotonic()
        has_c2pa, has_ai, findings = report_budget.bounded_inspect_jpeg(data)
        self.assertLess(time.monotonic() - started, 10)
        self.assertTrue(has_c2pa)
        self.assertTrue(has_ai)
        self.assertLessEqual(len(findings), 2 * report_budget.MAX_JPEG_SEGMENTS + 2)
        self.assertEqual(findings[-1], report_budget.JPEG_SEGMENT_LIMIT_FINDING)

    def test_marker_after_the_cap_is_still_found_by_the_byte_scan(self) -> None:
        benign = [_jpeg_segment(0xE0, b"x") for _ in range(5_000)]
        data = _jpeg(*benign, _jpeg_segment(0xE0, b"c2pa manifest jumb"))
        has_c2pa, has_ai, findings = report_budget.bounded_inspect_jpeg(data)
        self.assertTrue(has_c2pa)
        self.assertTrue(has_ai)
        self.assertTrue(any(f.startswith("byte-scan C2PA markers") for f in findings))
        self.assertIn(report_budget.JPEG_SEGMENT_LIMIT_FINDING, findings)

    def test_benign_flood_is_still_reported_as_unverified(self) -> None:
        data = _jpeg(*[_jpeg_segment(0xE0, b"x") for _ in range(5_000)])
        has_c2pa, has_ai, findings = report_budget.bounded_inspect_jpeg(data)
        self.assertFalse(has_c2pa)
        self.assertTrue(has_ai)
        self.assertEqual(findings, [report_budget.JPEG_SEGMENT_LIMIT_FINDING])


class RequestBudgetTests(unittest.TestCase):
    """Many inspector calls for one file share one budget."""

    def test_one_image_in_a_request_matches_upstream(self) -> None:
        with report_budget.request_budget():
            self.assertEqual(report_budget.bounded_inspect_jpeg(CAP_JPEG), UPSTREAM_INSPECT_JPEG(CAP_JPEG))
            text = _pua_text(report_budget.MAX_TEXT_HITS + 50)
            bounded = report_budget.bounded_inspect_text(text).to_dict()
        self.assertEqual(len(bounded["hits"]), report_budget.MAX_TEXT_HITS + 1)
        self.assertEqual(bounded, report_budget.bounded_inspect_text(text).to_dict())

    def test_findings_of_many_images_are_bounded_per_request(self) -> None:
        results = []
        with report_budget.request_budget():
            for _ in range(50):
                results.append(report_budget.bounded_inspect_jpeg(CAP_JPEG))
        findings = [finding for _, _, image_findings in results for finding in image_findings]
        self.assertLessEqual(len(findings), report_budget.MAX_REPORT_JPEG_FINDINGS + 1)
        self.assertEqual(findings.count(report_budget.JPEG_REPORT_FINDING_LIMIT), 1)
        # Every image is still flagged, listed or not.
        self.assertTrue(all(has_c2pa and has_ai for has_c2pa, has_ai, _ in results))
        # The first image is listed in full, exactly as upstream lists it.
        self.assertEqual(results[0], UPSTREAM_INSPECT_JPEG(CAP_JPEG))

    def test_segments_of_many_images_are_bounded_per_request(self) -> None:
        per_request = report_budget.MAX_REPORT_JPEG_SEGMENTS // report_budget.MAX_JPEG_SEGMENTS
        late_c2pa = _jpeg(_jpeg_segment(0xFE, b"x"), _jpeg_segment(0xE0, b"contentcredentials"))
        started = time.monotonic()
        with report_budget.request_budget():
            benign = [report_budget.bounded_inspect_jpeg(BENIGN_CAP_JPEG) for _ in range(per_request + 200)]
            late = report_budget.bounded_inspect_jpeg(late_c2pa)
            empty = report_budget.bounded_inspect_jpeg(_JPEG_1X1[:2] + b"\xff\xd9")
        self.assertLess(time.monotonic() - started, 10)
        # Within the request budget: exactly upstream (clean, no findings).
        for result in benign[:per_request]:
            self.assertEqual(result, UPSTREAM_INSPECT_JPEG(BENIGN_CAP_JPEG))
        # Past it: not walked, so unverified and suspicious.
        for has_c2pa, has_ai, findings in benign[per_request:]:
            self.assertFalse(has_c2pa)
            self.assertTrue(has_ai)
            self.assertEqual(findings, [report_budget.JPEG_REPORT_SEGMENT_FINDING])
        # The whole-image byte scan still finds C2PA after the budget is spent.
        self.assertTrue(late[0])
        self.assertTrue(late[1])
        # An image with no header segments needs no budget.
        self.assertEqual(empty, UPSTREAM_INSPECT_JPEG(_JPEG_1X1[:2] + b"\xff\xd9"))

    def test_text_hits_of_many_pages_are_bounded_per_request(self) -> None:
        pages = [_pua_text(300, start=300 * index) for index in range(40)]
        with report_budget.request_budget():
            reports = [report_budget.bounded_inspect_text(page) for page in pages]
            payloads = [report.to_dict() for report in reports]
            again = reports[-1].to_dict()
        listed = [hit for payload in payloads for hit in payload["hits"] if hit["codepoint"] != "various"]
        self.assertEqual(len(listed), report_budget.MAX_REPORT_TEXT_HITS)
        self.assertEqual(sum(payload["suspicious_total"] for payload in payloads), 300 * 40)
        for payload in payloads:
            self.assertTrue(payload["hits_truncated"])
            self.assertEqual(payload["hits_total"], 300)
            summary = payload["hits"][-1]
            self.assertEqual(summary["codepoint"], "various")
            self.assertEqual(summary["count"], payload["hits_omitted_occurrences"])
        # Late pages list nothing but still carry the summary entry.
        self.assertEqual(len(payloads[-1]["hits"]), 1)
        self.assertEqual(payloads[-1]["hits"][0]["count"], 300)
        # Serializing a report again neither lists it differently nor charges again.
        self.assertEqual(again, payloads[-1])

    def test_without_a_request_only_per_call_limits_apply(self) -> None:
        for _ in range(5):
            self.assertEqual(report_budget.bounded_inspect_jpeg(CAP_JPEG), UPSTREAM_INSPECT_JPEG(CAP_JPEG))
        self.assertIsNone(report_budget._request)

    def test_nested_request_keeps_the_outer_budget(self) -> None:
        with report_budget.request_budget() as outer:
            report_budget.bounded_inspect_jpeg(CAP_JPEG)
            with report_budget.request_budget() as inner:
                self.assertIs(inner, outer)
            self.assertIs(report_budget._request, outer)
        self.assertIsNone(report_budget._request)


class HelperBudgetTests(unittest.TestCase):
    def test_helper_installs_the_bounded_inspectors(self) -> None:
        script = (
            "import sys; sys.argv=['x']; sys.path.insert(0, 'Helper');"
            "import provenance_helper, report_budget, server, container_meta, image_meta, text_unicode, injection_scan;"
            "ok = all(["
            "server.inspect_text is report_budget.bounded_inspect_text,"
            "text_unicode.inspect_text is report_budget.bounded_inspect_text,"
            "injection_scan.inspect_text is report_budget.bounded_inspect_text,"
            "container_meta.inspect_jpeg is report_budget.bounded_inspect_jpeg,"
            "image_meta.inspect_jpeg is report_budget.bounded_inspect_jpeg]);"
            "print(ok)"
        )
        result = subprocess.run(
            [sys.executable, "-c", script], cwd=ROOT, capture_output=True, text=True, timeout=120
        )
        self.assertEqual(result.stdout.strip(), "True", result.stderr)

    def test_oversized_response_becomes_a_clear_error(self) -> None:
        script = (
            "import sys; sys.argv=['x']; sys.path.insert(0, 'Helper');"
            "import provenance_helper as h;"
            "h._emit({'requestID': 'big', 'ok': True, 'kind': 'text',"
            " 'report': {'blob': 'x' * (h.MAX_RESPONSE_BYTES + 10)}})"
        )
        result = subprocess.run(
            [sys.executable, "-c", script], cwd=ROOT, capture_output=True, text=True, timeout=120
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(len(result.stdout), 4096)
        response = json.loads(result.stdout)
        self.assertEqual(response["requestID"], "big")
        self.assertFalse(response["ok"])
        self.assertEqual(response["kind"], "report_too_large")
        self.assertEqual(response["report"]["details"]["maxBytes"], 15 << 20)

    def _inspect(self, name: str, data: bytes) -> tuple[dict, int]:
        with tempfile.TemporaryDirectory() as directory, HelperProcess() as helper:
            path = Path(directory) / name
            path.write_bytes(data)
            response = helper.exchange(
                {"requestID": "budget", "operation": "inspect", "inputPath": str(path)}, timeout=120
            )
            return response, len(json.dumps(response, ensure_ascii=False).encode("utf-8"))


    def _assert_bounded_container(self, name: str, data: bytes) -> dict:
        started = time.monotonic()
        response, size = self._inspect(name, data)
        self.assertLess(time.monotonic() - started, 60)
        self.assertTrue(response["ok"], response)
        self.assertLess(size, 2 << 20)
        self.assertTrue(response["report"]["suspicious"])
        return response["report"]

    def test_many_embedded_jpegs_in_a_docx_share_one_budget(self) -> None:
        report = self._assert_bounded_container("many.docx", _docx([CAP_JPEG] * 100))
        self.assertTrue(report["has_c2pa"])
        self.assertTrue(any(report_budget.JPEG_REPORT_FINDING_LIMIT in finding for finding in report["findings"]))

    def test_many_data_uri_jpegs_in_html_share_one_budget(self) -> None:
        report = self._assert_bounded_container("many.html", _html_with_data_uris([CAP_JPEG] * 100))
        self.assertTrue(report["has_c2pa"])
        self.assertTrue(any(report_budget.JPEG_REPORT_FINDING_LIMIT in finding for finding in report["findings"]))

    def test_many_benign_embedded_jpegs_are_reported_as_unverified(self) -> None:
        report = self._assert_bounded_container("benign.docx", _docx([BENIGN_CAP_JPEG] * 50))
        self.assertTrue(any(report_budget.JPEG_REPORT_SEGMENT_FINDING in finding for finding in report["findings"]))

    def test_many_epub_pages_share_one_text_budget(self) -> None:
        pages = [_pua_text(300, start=300 * index) for index in range(100)]
        report = self._assert_bounded_container("many.epub", _epub(pages))
        layer_a = [finding for finding in report["findings"] if finding.startswith("layer-a")]
        listed = [finding for finding in layer_a if ": various " not in finding]
        self.assertEqual(len(listed), report_budget.MAX_REPORT_TEXT_HITS)
        self.assertEqual(len(layer_a) - len(listed), len(pages))
        self.assertEqual(report["suspicious_total"], 300 * len(pages))

    def test_jpeg_segment_flood_inspects_within_the_response_limit(self) -> None:
        data = _jpeg(*[_jpeg_segment(0xEB, b"c2pa") for _ in range(400_000)])
        response, size = self._inspect("flood.jpg", data)
        self.assertTrue(response["ok"], response)
        self.assertLess(size, APP_RESPONSE_LIMIT)
        self.assertTrue(response["report"]["suspicious"])
        self.assertIn(report_budget.JPEG_SEGMENT_LIMIT_FINDING, response["report"]["findings"])

    def test_many_private_use_characters_inspect_within_the_response_limit(self) -> None:
        text = "".join(chr(cp) for cp in range(0xF0000, 0xFFFFE)) + "".join(
            chr(cp) for cp in range(0x100000, 0x10FFFE)
        )
        response, size = self._inspect("pua.txt", text.encode("utf-8"))
        self.assertTrue(response["ok"], response)
        self.assertLess(size, APP_RESPONSE_LIMIT)
        self.assertTrue(response["report"]["suspicious"])
        self.assertTrue(response["report"]["hits_truncated"])
        self.assertEqual(response["report"]["suspicious_total"], len(text))


if __name__ == "__main__":
    unittest.main()
