import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import warnings
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Helper"))
import credential_inspection as credentials
import office_credentials as office
from test_provenance_helper import HelperProcess, FIXTURES, _JPEG_1X1
from test_word_editing_traces import specimen


def document(parts=None):
    """Unsigned, compressed Word package with optional embedded assets."""
    buffer = io.BytesIO()
    with zipfile.ZipFile(io.BytesIO(specimen())) as source, zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as out:
        for info in source.infolist():
            if not info.filename.startswith("word/media/"):
                out.writestr(info.filename, source.read(info))
        for name, raw in (parts or {}).items():
            out.writestr(name, raw)
    return buffer.getvalue()


def tampered_image():
    raw = bytearray((FIXTURES / "signed-c2pa.jpg").read_bytes())
    start = raw.index(b"\xff\xda")
    raw[start + 2 + int.from_bytes(raw[start+2:start+4], "big") + 8] ^= 1
    return raw


class OfficeCredentialsTests(unittest.TestCase):
    def inspect_bytes(self, raw):
        with tempfile.TemporaryDirectory() as directory, HelperProcess() as helper:
            path = Path(directory) / "owned.docx"
            path.write_bytes(raw)
            result = helper.exchange({"requestID": "office-c2pa", "operation": "inspect", "inputPath": str(path)}, timeout=120)
            self.assertTrue(result["ok"], result)
            self.assertEqual(path.read_bytes(), raw)
            return result["report"]

    def test_unsigned_compressed_word_and_unsigned_image_are_absent(self):
        report = self.inspect_bytes(document({"word/media/plain.jpg": _JPEG_1X1}))
        c2pa = report["c2pa"]
        self.assertEqual(c2pa["state"], "absent")
        self.assertEqual(c2pa["document"]["state"], "absent")
        self.assertEqual(c2pa["embeddedAssets"][0]["state"], "absent")
        self.assertFalse(c2pa["inspectionIncomplete"])
        self.assertFalse(report["has_c2pa"])

    def test_signed_word_signature_collection_binding_and_certificate_chain(self):
        c2pa = self.inspect_bytes((FIXTURES / "signed-c2pa.docx").read_bytes())["c2pa"]
        self.assertEqual(c2pa["state"], "present")
        self.assertFalse(c2pa["inspectionIncomplete"])
        doc = c2pa["document"]
        self.assertEqual(doc["signature"], "valid")
        self.assertEqual(doc["contentBinding"], "valid")
        self.assertEqual(doc["trust"], "untrusted")
        self.assertTrue(doc["certificates"][0]["sha256"])
        self.assertFalse(doc["validationFailed"])

    def test_modified_word_package_fails_content_binding(self):
        buffer = io.BytesIO()
        with zipfile.ZipFile(FIXTURES / "signed-c2pa.docx") as source, zipfile.ZipFile(buffer, "w") as out:
            for info in source.infolist():
                raw = source.read(info)
                if info.filename == "word/document.xml":
                    raw = raw.replace(b"Editing traces specimen", b"Modified signed content")
                out.writestr(info, raw)
        c2pa = self.inspect_bytes(buffer.getvalue())["c2pa"]
        self.assertEqual(c2pa["document"]["signature"], "valid")
        self.assertEqual(c2pa["document"]["contentBinding"], "invalid")
        self.assertTrue(c2pa["validationFailed"])

    def test_embedded_signed_image_does_not_authenticate_word(self):
        c2pa = self.inspect_bytes(document({"word/media/photo.bin": (FIXTURES / "signed-c2pa.jpg").read_bytes()}))["c2pa"]
        self.assertEqual(c2pa["state"], "present")
        self.assertEqual(c2pa["document"]["state"], "absent")
        self.assertEqual(c2pa["document"]["signature"], "unknown")
        self.assertFalse(c2pa["inspectionIncomplete"])
        image = c2pa["embeddedAssets"][0]
        self.assertEqual(image["path"], "word/media/photo.bin")
        self.assertEqual(image["signature"], "valid")
        self.assertEqual(image["contentBinding"], "valid")
        self.assertEqual(len(image["certificates"]), 2)

    def test_tampered_embedded_image_fails_validation(self):
        c2pa = self.inspect_bytes(document({"word/media/modified.jpg": tampered_image()}))["c2pa"]
        self.assertTrue(c2pa["validationFailed"])
        self.assertEqual(c2pa["embeddedAssets"][0]["contentBinding"], "invalid")
        self.assertEqual(c2pa["document"]["state"], "absent")

    def test_malformed_manifest_is_detected_but_not_verified(self):
        c2pa = self.inspect_bytes(document({office.MANIFEST_PATH: b"not a valid manifest"}))["c2pa"]
        self.assertEqual(c2pa["state"], "present")
        self.assertEqual(c2pa["document"]["state"], "present_unverified")
        self.assertTrue(c2pa["inspectionIncomplete"])

    def test_partial_results_survive_unsupported_embedded_media(self):
        report = self.inspect_bytes(document({"word/media/signed.jpg": (FIXTURES / "signed-c2pa.jpg").read_bytes(), "word/media/unknown.emf": b"unknown image format"}))
        c2pa = report["c2pa"]
        self.assertTrue(report["has_c2pa"])
        self.assertEqual(c2pa["state"], "present")
        self.assertTrue(c2pa["inspectionIncomplete"])
        self.assertEqual(c2pa["embeddedAssets"][0]["signature"], "valid")
        self.assertNotEqual(c2pa["embeddedAssets"][1]["state"], "absent")
        self.assertEqual(c2pa["inspectedEmbeddedCount"], 2)

    def test_unsupported_image_without_credentials_is_not_absence(self):
        c2pa = self.inspect_bytes(document({"word/media/unknown.emf": b"unknown format"}))["c2pa"]
        self.assertEqual(c2pa["state"], "inconclusive")
        self.assertTrue(c2pa["inspectionIncomplete"])

    def test_content_types_find_image_outside_media_folder(self):
        buffer = io.BytesIO()
        with zipfile.ZipFile(io.BytesIO(document())) as source, zipfile.ZipFile(buffer, "w") as out:
            for info in source.infolist():
                raw = source.read(info)
                if info.filename == "[Content_Types].xml":
                    raw = raw.replace(b"</Types>", b'<Override PartName="/assets/art.bin" ContentType="image/jpeg"/></Types>')
                out.writestr(info, raw)
            out.writestr("assets/art.bin", (FIXTURES / "signed-c2pa.jpg").read_bytes())
        c2pa = self.inspect_bytes(buffer.getvalue())["c2pa"]
        self.assertEqual(c2pa["embeddedAssets"][0]["path"], "assets/art.bin")
        self.assertEqual(c2pa["embeddedAssets"][0]["signature"], "valid")

    def test_zip_errors_and_limits_cannot_be_reported_as_absence(self):
        duplicate = io.BytesIO(document())
        with warnings.catch_warnings(), zipfile.ZipFile(duplicate, "a") as archive:
            warnings.simplefilter("ignore")
            archive.writestr("word/document.xml", "duplicate")
        empty = io.BytesIO()
        with zipfile.ZipFile(empty, "w"):
            pass
        for raw in (b"PK broken archive", duplicate.getvalue(), empty.getvalue()):
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory)/"bad.docx"; path.write_bytes(raw)
                c2pa = office.inspect_office(path, credentials.inspect_asset)["details"]
                self.assertTrue(c2pa["inspectionIncomplete"])
                self.assertEqual(c2pa["state"], "inconclusive")
                self.assertTrue(c2pa["coverageErrors"])
        with tempfile.TemporaryDirectory() as directory, patch.object(office, "MAX_ASSETS", 0):
            path = Path(directory)/"large.docx"; path.write_bytes(document({"word/media/a.jpg": _JPEG_1X1}))
            result = office.inspect_office(path, lambda *a, **k: {"available": True, "details": {"state": "absent", "inspectionIncomplete": False}})
            self.assertFalse(result["ok"])
            self.assertEqual(result["details"]["embeddedCount"], 1)
            self.assertEqual(result["details"]["inspectedEmbeddedCount"], 0)

    def test_size_and_time_limits_are_incomplete_not_absent(self):
        for name, limit in (("MAX_ASSET_BYTES", 1), ("MAX_SECONDS", 0)):
            with self.subTest(limit=name), tempfile.TemporaryDirectory() as directory, patch.object(office, name, limit):
                path = Path(directory)/"limited.docx"
                path.write_bytes(document({"word/media/a.jpg": _JPEG_1X1}))
                result = office.inspect_office(path, lambda *a, **k: {"available": True, "details": {"state": "absent", "inspectionIncomplete": False}})
                self.assertFalse(result["ok"])
                self.assertEqual(result["details"]["state"], "inconclusive")

    def test_bad_content_types_preserve_independent_image_results(self):
        buffer = io.BytesIO()
        with zipfile.ZipFile(io.BytesIO(document({"word/media/a.jpg": _JPEG_1X1}))) as source, zipfile.ZipFile(buffer, "w") as out:
            for info in source.infolist():
                out.writestr(info, b"<bad xml" if info.filename == "[Content_Types].xml" else source.read(info))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/"partial.docx"; path.write_bytes(buffer.getvalue())
            result = office.inspect_office(path, lambda *a, **k: {"available": True, "details": {"state": "absent", "inspectionIncomplete": False}})
            self.assertFalse(result["ok"])
            self.assertEqual(result["details"]["document"]["state"], "absent")
            self.assertEqual(result["details"]["embeddedAssets"][0]["state"], "absent")
            self.assertTrue(result["details"]["coverageErrors"])

    def test_missing_verifier_and_timeout_are_not_absence(self):
        with patch.object(credentials.shutil, "which", return_value=None):
            self.assertTrue(credentials.inspect_asset("file.jpg")["details"]["inspectionIncomplete"])
        with patch.object(credentials.shutil, "which", return_value="/tool"), patch.dict(os.environ, {"C2PATOOL_SETTINGS": "/offline"}), patch.object(credentials, "_run", side_effect=subprocess.TimeoutExpired("c2patool", 15)):
            result = credentials.inspect_asset("file.jpg")
            self.assertEqual(result["details"]["state"], "inconclusive")
            self.assertTrue(result["details"]["inspectionIncomplete"])


if __name__ == "__main__":
    unittest.main()
