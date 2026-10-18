"""Corrections the helper applies to the pinned engine's output (Helper/upstream_fixes.py)."""
from __future__ import annotations

import io
import tempfile
import unittest
import zipfile
from pathlib import Path

from test_provenance_helper import CONSERVATIVE_OPTIONS, FIXTURES, HelperProcess

ROOT = Path(__file__).resolve().parents[2]
VENDOR_FIXTURES = ROOT / "Vendor" / "watermarks-remover" / "tests" / "fixtures"
THUMBNAIL_REL = "http://schemas.openxmlformats.org/package/2006/relationships/metadata/thumbnail"
OUT_OF_SCOPE_KEYS = ("stylometry", "text_detectors", "synthid", "synthid_before", "synthid_after", "pixel_removal")


def with_preview(package: bytes, name: str, image: bytes, content_type: str) -> bytes:
    """Add a preview part the way Office does: a package relationship plus a content type."""

    output = io.BytesIO()
    with zipfile.ZipFile(io.BytesIO(package)) as source, zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as target:
        for info in source.infolist():
            data = source.read(info)
            if info.filename == "[Content_Types].xml":
                data = data.replace(
                    b"</Types>",
                    f'<Override PartName="/{name}" ContentType="{content_type}"/></Types>'.encode(),
                )
            elif info.filename == "_rels/.rels":
                data = data.replace(
                    b"</Relationships>",
                    f'<Relationship Id="rIdPreview" Type="{THUMBNAIL_REL}" Target="{name}"/></Relationships>'.encode(),
                )
            target.writestr(info, data)
        target.writestr(name, image)
    return output.getvalue()


def clean(helper: HelperProcess, source: Path, output: Path, request_id: str) -> dict:
    return helper.exchange({
        "requestID": request_id,
        "operation": "clean",
        "inputPath": str(source),
        "outputPath": str(output),
        "options": CONSERVATIVE_OPTIONS,
    })


class OfficePreviewImageTests(unittest.TestCase):
    def test_signed_preview_image_is_stripped_not_corrupted_in_every_office_format(self) -> None:
        signed_jpeg = (FIXTURES / "signed-c2pa.jpg").read_bytes()
        packages = {
            "docx": (FIXTURES / "editing-traces.docx").read_bytes(),
            "xlsx": (VENDOR_FIXTURES / "sample_ai.xlsx").read_bytes(),
            "pptx": (VENDOR_FIXTURES / "sample_ai.pptx").read_bytes(),
        }
        with tempfile.TemporaryDirectory() as temp, HelperProcess() as helper:
            for suffix, package in packages.items():
                with self.subTest(format=suffix):
                    source = Path(temp) / f"preview.{suffix}"
                    output = Path(temp) / f"preview.cleaned.{suffix}"
                    source.write_bytes(with_preview(package, "docProps/thumbnail.jpeg", signed_jpeg, "image/jpeg"))

                    response = clean(helper, source, output, f"preview-{suffix}")

                    self.assertIs(response["ok"], True, response.get("error"))
                    with zipfile.ZipFile(output) as archive:
                        self.assertIsNone(archive.testzip())
                        preview = archive.read("docProps/thumbnail.jpeg")
                        rels = archive.read("_rels/.rels")
                    # A real JPEG again (start and end markers), with its credential removed.
                    self.assertTrue(preview.startswith(b"\xff\xd8\xff"))
                    self.assertTrue(preview.endswith(b"\xff\xd9"))
                    self.assertNotIn(b"\xef\xbf\xbd", preview)
                    self.assertLess(len(preview), len(signed_jpeg))
                    for marker in (b"c2pa", b"jumb", b"contentauth"):
                        self.assertNotIn(marker, preview.lower())
                    self.assertIn(b'Target="docProps/thumbnail.jpeg"', rels)
                    report = response["report"]
                    self.assertIn(
                        "Preview image docProps/thumbnail.jpeg kept; its metadata was removed.",
                        report["actions"],
                    )
                    self.assertFalse(any("thumbnail" in item for item in report.get("post_findings", [])))

    def test_preview_that_cannot_be_stripped_is_dropped_with_its_references(self) -> None:
        package = with_preview(
            (FIXTURES / "editing-traces.docx").read_bytes(),
            "docProps/thumbnail.wmf",
            b"\xd7\xcd\xc6\x9a" + bytes(range(256)) * 4,
            "image/x-wmf",
        )
        with tempfile.TemporaryDirectory() as temp, HelperProcess() as helper:
            source = Path(temp) / "metafile.docx"
            output = Path(temp) / "metafile.cleaned.docx"
            source.write_bytes(package)

            response = clean(helper, source, output, "preview-wmf")

            self.assertIs(response["ok"], True, response.get("error"))
            with zipfile.ZipFile(output) as archive:
                self.assertIsNone(archive.testzip())
                names = set(archive.namelist())
                rels = archive.read("_rels/.rels")
                content_types = archive.read("[Content_Types].xml")
            with zipfile.ZipFile(source) as original:
                self.assertEqual(names, set(original.namelist()) - {"docProps/thumbnail.wmf"})
            self.assertNotIn(b"thumbnail.wmf", rels)
            self.assertNotIn(b"thumbnail.wmf", content_types)
            self.assertIn(
                "Preview image docProps/thumbnail.wmf removed: its metadata couldn't be cleaned.",
                response["report"]["actions"],
            )

    def test_packages_without_a_preview_are_unchanged_by_the_repair(self) -> None:
        with tempfile.TemporaryDirectory() as temp, HelperProcess() as helper:
            source = Path(temp) / "plain.docx"
            output = Path(temp) / "plain.cleaned.docx"
            source.write_bytes((FIXTURES / "editing-traces.docx").read_bytes())

            response = clean(helper, source, output, "no-preview")

            self.assertIs(response["ok"], True, response.get("error"))
            self.assertFalse(any(action.startswith("Preview image") for action in response["report"]["actions"]))


class OutOfScopeReportContentTests(unittest.TestCase):
    def test_text_reports_carry_no_authorship_score_or_rewrite_advice(self) -> None:
        with tempfile.TemporaryDirectory() as temp, HelperProcess() as helper:
            prose = Path(temp) / "prose.txt"
            prose.write_bytes((VENDOR_FIXTURES / "stylometry_ai_sample.txt").read_bytes())
            plain = helper.exchange({"requestID": "prose", "operation": "inspect", "inputPath": str(prose)})
            marked = helper.exchange({
                "requestID": "marked", "operation": "inspect", "inputPath": str(FIXTURES / "watermarked.txt"),
            })

        for response in (plain, marked):
            report = response["report"]
            for key in OUT_OF_SCOPE_KEYS:
                self.assertNotIn(key, report)
            notes = " ".join(report.get("notes", []))
            for phrase in ("Layer B", "strip flags", "Inspect kinds", "Layer A"):
                self.assertNotIn(phrase, notes)
            self.assertIn("Statistical watermarks carried by word choice can't be detected or removed by this app.", report["notes"])
        # Only deterministic signals make a file suspicious: AI-sounding prose
        # alone does not, invisible characters still do.
        self.assertEqual(plain["report"]["suspicious_total"], 0)
        self.assertIs(plain["report"]["suspicious"], False)
        self.assertIs(marked["report"]["suspicious"], True)

    def test_image_reports_carry_no_synthid_or_pixel_keys(self) -> None:
        with tempfile.TemporaryDirectory() as temp, HelperProcess() as helper:
            inspected = helper.exchange({
                "requestID": "image", "operation": "inspect", "inputPath": str(FIXTURES / "signed-c2pa.jpg"),
            })
            cleaned = clean(helper, FIXTURES / "signed-c2pa.jpg", Path(temp) / "signed.cleaned.jpg", "image-clean")

        self.assertIs(cleaned["ok"], True, cleaned.get("error"))
        for report in (inspected["report"], cleaned["report"]):
            for key in OUT_OF_SCOPE_KEYS:
                self.assertNotIn(key, report)
                self.assertNotIn(key, report.get("meta") or {})


if __name__ == "__main__":
    unittest.main()
