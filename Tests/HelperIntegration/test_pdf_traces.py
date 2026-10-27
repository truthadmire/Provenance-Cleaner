from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

from test_provenance_helper import CONSERVATIVE_OPTIONS, HelperProcess, _assemble_pdf, _rendered_pdf_pixels

ROOT = Path(__file__).resolve().parents[2]
STAGED = ROOT / "Vendor/Artifacts/staged"
QPDF = STAGED / "qpdf/qpdf"
os.environ["PATH"] = os.pathsep.join([str(STAGED / "qpdf"), str(STAGED / "exiftool"), os.environ.get("PATH", "")])
sys.path.insert(0, str(ROOT / "Helper"))
import pdf_traces  # noqa: E402

MANIFEST = b"\x00\x00\x00\x20jumbjumdc2pa\x00contentauth-test-manifest"


def _stream(dictionary: bytes, data: bytes) -> bytes:
    return dictionary[:-2] + b" /Length %d >>\nstream\n" % len(data) + data + b"\nendstream"


def pymupdf_style_pdf() -> bytes:
    """A Word-like page that PyMuPDF wrapped and wrote over, then a C2PA attachment."""
    original = b"BT /F1 12 Tf 24 120 Td (Question 1) Tj ET"
    overlay = b"q 1 0 0 RG 2 w 20 60 120 30 re S Q BT /helv 11 Tf 24 70 Td (Answer: 42 Hz) Tj ET"
    pdf = _assemble_pdf([
        b"<< /Type /Catalog /Pages 2 0 R /AF [9 0 R] /Names << /EmbeddedFiles << /Names [(Content Credentials) 9 0 R] >> >> >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 160] /Annots [11 0 R]"
        b" /Resources << /Font << /F1 7 0 R /helv 8 0 R >> >> /Contents [4 0 R 5 0 R 6 0 R 12 0 R] >>",
        _stream(b"<< >>", b"q\n"),
        _stream(b"<< >>", original),
        _stream(b"<< >>", b"\nQ\n"),
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Times-Roman >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        b"<< /Type /Filespec /AFRelationship /C2PA_Manifest /F (Content Credentials) /UF (Content Credentials)"
        b" /Subtype (application/c2pa) /EF << /F 10 0 R >> >>",
        _stream(b"<< /Type /EmbeddedFile /Subtype /application#2Fc2pa >>", MANIFEST),
        b"<< /Type /Annot /Subtype /Link /Rect [24 20 180 40] /Border [0 0 0]"
        b" /A << /S /URI /URI (https://openai.com/index/a\\(b\\)) >> >>",
        _stream(b"<< /Filter /FlateDecode >>", zlib.compress(overlay)),
        b"<< /Producer (Microsoft\xae Word 2010) /Author (Teacher) >>",
    ], b" /Info 13 0 R /ID [<5710f96f74377549a441d2b45f0ecaee><5710f96f74377549a441d2b45f0ecaee>]",
        header=b"%PDF-1.7\n%\xc2\xb5\xc2\xb6\n")
    return pdf


def reportlab_style_pdf() -> bytes:
    content = b"BT /F2+0 14 Tf 24 120 Td (Report) Tj ET /gRLs0 gs 0 0 1 rg 20 20 80 40 re f"
    cmap = b"/CIDInit /ProcSet findresource begin\n/CIDSystemInfo << /Registry (AAAAAA+Lato-Bold) /Ordering (AAAAAA+Lato-Bold) /Supplement 0 >> def\n/CMapName /AAAAAA+Lato-Bold def\nend"
    pdf = _assemble_pdf([
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 160]"
        b" /Resources << /Font << /F2+0 5 0 R >> /ExtGState << /gRLs0 6 0 R >> >> /Contents 4 0 R >>",
        _stream(b"<< >>", content),
        b"<< /Type /Font /Subtype /Type1 /Name /F2+0 /BaseFont /AAAAAA+Lato-Bold /ToUnicode 7 0 R >>",
        b"<< /Type /ExtGState /ca 0.5 >>",
        _stream(b"<< >>", cmap),
        b"<< /Producer (ReportLab PDF Library - www.reportlab.com) /Creator (anonymous) >>",
    ], b" /Info 8 0 R", header=b"%PDF-1.4\n%\x93\x8c\x8b\x9e ReportLab Generated PDF document http://www.reportlab.com\n")
    return pdf


def expanded(path: Path) -> bytes:
    target = path.with_suffix(".expanded.pdf")
    subprocess.run([str(QPDF), "--qdf", "--object-streams=disable", str(path), str(target)], check=True, capture_output=True)
    return target.read_bytes()


def page_contents(path: Path) -> list[int]:
    result = subprocess.run([str(QPDF), "--json", "--json-key=pages", str(path)], check=True, capture_output=True)
    return [len(page["contents"]) for page in json.loads(result.stdout)["pages"]]


class PdfTraceUnitTests(unittest.TestCase):
    def test_link_targets_are_emptied_with_nested_and_escaped_parentheses(self):
        blob = b"<< /URI (https://openai.com/a(b)\\)c) /Title (OpenAI) >> << /URI <68747470> >>"
        self.assertEqual(pdf_traces.without_link_targets(blob), b"<< /URI () /Title (OpenAI) >> << /URI () >>")

    def test_resource_references_skip_strings_arrays_and_inline_image_data(self):
        data = (b"BT /F1 12 Tf [(/F9 1 Tf) -20 (x)] TJ ET /P0 cs /Pat1 scn /GS0 gs"
                b" /Span <</MCID 0>> BDC EMC /OC /MC0 BDC EMC"
                b" BI /W 1 /H 1 /CS /CS0 /BPC 8 ID \x00/Fake Do\xff EI /Im0 Do (/X Do) Tj")
        found = [(category, name) for category, _, _, name in pdf_traces.resource_references(data)]
        self.assertEqual(found, [("/Font", "/F1"), ("/ColorSpace", "/P0"), ("/Pattern", "/Pat1"),
                                 ("/ExtGState", "/GS0"), ("/Properties", "/MC0"), ("/ColorSpace", "/CS0"),
                                 ("/XObject", "/Im0")])

    def test_form_field_fonts_named_by_appearance_strings_are_kept(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "form.pdf"
            content = b"BT /Helv 10 Tf 10 10 Td (x) Tj /F1 9 Tf ET"
            path.write_bytes(_assemble_pdf([
                b"<< /Type /Catalog /Pages 2 0 R /AcroForm << /DR << /Font << /Helv 5 0 R >> >> /DA (/Helv 0 Tf 0 g) >> >>",
                b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << /Font << /Helv 5 0 R /F1 5 0 R >> >> /Contents 4 0 R >>",
                _stream(b"<< >>", content),
                b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            ]))
            pdf_traces.normalize(path)
            raw = expanded(path)
            self.assertIn(b"/Helv 10 Tf", raw)
            self.assertIn(b"/Helv 0 Tf 0 g", raw)
            self.assertNotIn(b"/F1 9 Tf", raw)


class PdfTraceProtocolTests(unittest.TestCase):
    def test_pymupdf_edit_and_attached_credential_are_reported_then_removed_without_ghostscript(self):
        with tempfile.TemporaryDirectory() as temp, HelperProcess() as helper:
            source, output = Path(temp) / "edited.pdf", Path(temp) / "auto.pdf"
            source.write_bytes(pymupdf_style_pdf())
            report = helper.exchange({"requestID": "i", "operation": "inspect", "inputPath": str(source)})["report"]
            traces = report["pdf_traces"]
            self.assertEqual(traces["generators"], [{"name": "PyMuPDF", "evidence": [
                "MuPDF file header", "resources named /helv", "page content wrapped in extra q/Q streams"]}])
            self.assertEqual(traces["c2paAttachments"], 1)
            self.assertIn({"label": "Producer", "value": "Microsoft® Word 2010"}, traces["properties"])
            # The openai.com link is page content, not a marker.
            self.assertFalse(any("OpenAI" in finding for finding in report["findings"]), report["findings"])

            result = helper.exchange({"requestID": "c", "operation": "clean", "inputPath": str(source), "outputPath": str(output),
                                      "options": {**CONSERVATIVE_OPTIONS, "deepImages": "auto"}}, timeout=90)
            self.assertIs(result["ok"], True, result)
            self.assertIs(result["report"]["meta"]["deep_image_pass"], False)
            raw = expanded(output)
            self.assertIsNone(re.search(rb"/helv\b", raw))
            for trace in (b"c2pa", b"contentauth", b"EmbeddedFile", b"Teacher", b"5710f96f", b"\xc2\xb5\xc2\xb6"):
                self.assertNotIn(trace, raw)
            self.assertIn(b"https://openai.com/index/a\\(b\\)", raw)
            self.assertEqual(page_contents(output), [1])
            self.assertEqual(_rendered_pdf_pixels(output), _rendered_pdf_pixels(source))
            after = helper.exchange({"requestID": "a", "operation": "inspect", "inputPath": str(output)})["report"]["pdf_traces"]
            self.assertEqual((after["generators"], after["properties"], after["c2paAttachments"]), ([], [], 0))

    def test_reportlab_names_subset_tags_and_cmap_names_are_replaced(self):
        with tempfile.TemporaryDirectory() as temp, HelperProcess() as helper:
            source, output = Path(temp) / "report.pdf", Path(temp) / "never.pdf"
            source.write_bytes(reportlab_style_pdf())
            traces = helper.exchange({"requestID": "i", "operation": "inspect", "inputPath": str(source)})["report"]["pdf_traces"]
            self.assertEqual([g["name"] for g in traces["generators"]], ["ReportLab"])
            result = helper.exchange({"requestID": "c", "operation": "clean", "inputPath": str(source), "outputPath": str(output),
                                      "options": CONSERVATIVE_OPTIONS}, timeout=90)
            self.assertIs(result["ok"], True, result)
            raw = expanded(output)
            for trace in (b"ReportLab", b"F2+0", b"gRLs", b"AAAAAA", b"anonymous"):
                self.assertNotIn(trace, raw)
            tag = raw.split(b"/BaseFont /", 1)[1][:6]
            self.assertIn(b"/Registry (" + tag + b"+Lato-Bold)", raw)
            self.assertEqual(_rendered_pdf_pixels(output), _rendered_pdf_pixels(source))

    def test_ai_marker_inside_a_compressed_info_dictionary_is_found(self):
        with tempfile.TemporaryDirectory() as temp, HelperProcess() as helper:
            plain, packed = Path(temp) / "plain.pdf", Path(temp) / "packed.pdf"
            plain.write_bytes(_assemble_pdf([
                b"<< /Type /Catalog /Pages 2 0 R >>",
                b"<< /Type /Pages /Kids [] /Count 0 >>",
                b"<< /Producer (OpenAI image export) >>",
            ], b" /Info 3 0 R"))
            subprocess.run([str(QPDF), "--object-streams=generate", str(plain), str(packed)], check=True, capture_output=True)
            self.assertNotIn(b"OpenAI", packed.read_bytes())
            findings = helper.exchange({"requestID": "i", "operation": "inspect", "inputPath": str(packed)})["report"]["findings"]
            self.assertTrue(any("OpenAI" in finding for finding in findings), findings)

    def test_always_mode_skips_ghostscript_for_a_pdf_without_images(self):
        with tempfile.TemporaryDirectory() as temp, HelperProcess() as helper:
            source, output = Path(temp) / "report.pdf", Path(temp) / "always.pdf"
            source.write_bytes(reportlab_style_pdf())
            result = helper.exchange({"requestID": "c", "operation": "clean", "inputPath": str(source), "outputPath": str(output),
                                      "options": {**CONSERVATIVE_OPTIONS, "deepImages": "always"}}, timeout=90)
            report = result["report"]
            self.assertIs(report["meta"]["deep_image_pass"], False)
            self.assertIs(report["pdf_deep_clean_incomplete"], False)
            self.assertIn(pdf_traces.NO_IMAGES_ACTION, report["actions"])


if __name__ == "__main__":
    unittest.main()
