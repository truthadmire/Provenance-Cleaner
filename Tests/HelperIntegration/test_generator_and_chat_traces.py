"""Generator fields and chat leftovers: found, removed from the copy, and nothing else touched."""
from __future__ import annotations

import base64
import io
import os
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile
import zlib
from pathlib import Path

from test_localization_catalogs import _covered
from test_provenance_helper import CONSERVATIVE_OPTIONS, HelperProcess, _assemble_pdf

ROOT = Path(__file__).resolve().parents[2]
STAGED = ROOT / "Vendor/Artifacts/staged"
EXIFTOOL = STAGED / "exiftool/exiftool"
os.environ["PATH"] = os.pathsep.join([str(STAGED / "qpdf"), str(STAGED / "exiftool"), os.environ.get("PATH", "")])
sys.path.insert(0, str(ROOT / "Helper"))
import chat_artifacts  # noqa: E402
import generator_fields  # noqa: E402
import pdf_traces  # noqa: E402

# An 8x8 JPEG with no metadata.
JPEG = base64.b64decode("/9j/wAARCAAIAAgDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9sAQwAPDw8PDw8aDw8aJBoaGiQxJCQkJDE+MTExMTE+Sz4+Pj4+PktLS0tLS0tLWlpaWlpaaWlpaWl2dnZ2dnZ2dnZ2/9sAQwESExMeHB40HBw0e1RFVHt7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7/90ABAAB/9oADAMBAAIRAxEAPwClaaV04rR/sr2rQtO1aFcVTETvuVhMVU9mtT//2Q==")


def _chunk(kind: bytes, payload: bytes) -> bytes:
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)


def _png(*text: tuple[str, str]) -> bytes:
    rows = b"".join(b"\x00" + bytes((x * 30, y * 30, 90)) * 1 for y in range(4) for x in range(1))
    chunks = b"".join(_chunk(b"tEXt", key.encode() + b"\0" + value.encode()) for key, value in text)
    return (b"\x89PNG\r\n\x1a\n" + _chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 4, 8, 2, 0, 0, 0)) + chunks
            + _chunk(b"IDAT", zlib.compress(rows)) + _chunk(b"IEND", b""))


def _tagged(data: bytes, suffix: str, *arguments: str) -> bytes:
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / ("file" + suffix)
        path.write_bytes(data)
        subprocess.run([str(EXIFTOOL), "-overwrite_original", "-q", *arguments, str(path)], check=True)
        return path.read_bytes()


def _tags(data: bytes, suffix: str) -> str:
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / ("file" + suffix)
        path.write_bytes(data)
        return subprocess.run([str(EXIFTOOL), "-a", "-G1", "-s", str(path)], capture_output=True, text=True, check=True).stdout


def _mp3(*frames: tuple[bytes, str]) -> bytes:
    body = b"".join(tag + _synchsafe(len(text) + 1) + b"\0\0" + b"\x03" + text.encode() for tag, text in frames)
    audio = (b"\xff\xfb\x90\x00" + b"\0" * 413) * 4
    return b"ID3\x04\0\0" + _synchsafe(len(body)) + body + audio


def _synchsafe(n: int) -> bytes:
    return bytes(((n >> shift) & 0x7F) for shift in (21, 14, 7, 0))


def _docx(document: str, link: str) -> bytes:
    relationships = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId9" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink"'
        f' Target="{link}" TargetMode="External"/></Relationships>')
    parts = {
        "[Content_Types].xml": '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
                               '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
                               '<Default Extension="xml" ContentType="application/xml"/>'
                               '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>',
        "_rels/.rels": '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
                       '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>',
        "word/document.xml": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
                             '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>'
                             f'<w:p><w:r><w:t>{document}</w:t></w:r></w:p><w:sectPr/></w:body></w:document>',
        "word/_rels/document.xml.rels": relationships,
        "word/embeddings/object.bin": bytes(range(256)) * 8,
    }
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, value in parts.items():
            archive.writestr(name, value)
    return output.getvalue()


class Rules(unittest.TestCase):
    def test_software_fields_count_any_ai_product_but_captions_need_generator_wording(self):
        classify = generator_fields._classify
        self.assertEqual(classify("IFD0:Software", "Midjourney 6.1"), "software")
        self.assertEqual(classify("XMP-xmp:CreatorTool", "Sora"), "software")
        self.assertEqual(classify("IPTC:Credit", "Made with Google AI"), "software")
        self.assertEqual(classify("ID3v2_4:Comment", "Made with Suno"), "wording")
        self.assertEqual(classify("ExifIFD:UserComment", "a cat\nSteps: 20, Sampler: Euler a"), "wording")
        self.assertEqual(classify("XMP-dc:Description", "castle at dusk --ar 16:9 --v 6"), "wording")
        self.assertIsNone(classify("IFD0:Software", "Adobe Photoshop 25.0 (Macintosh)"))
        self.assertIsNone(classify("XMP-dc:Description", "A photo of the Gemini capsule, taken in Sora, Japan"))
        self.assertIsNone(classify("IFD0:Artist", "Claude Monet"))
        self.assertIsNone(classify("XMP-dc:Description", "Created by Claude Monet"))
        self.assertIsNone(classify("XMP-dc:Description", "made with pikachu stickers and lumber"))
        self.assertIsNone(classify("IFD0:Make", "Veo"), "a real camera maker")
        self.assertEqual(classify("IFD0:Model", "Imagen 3"), "software")

    def test_link_tracking_is_cut_out_without_breaking_the_address(self):
        cases = {
            "https://a.example/p?utm_source=chatgpt.com": "https://a.example/p",
            "https://a.example/p?utm_source=chatgpt.com&x=1": "https://a.example/p?x=1",
            "https://a.example/p?x=1&utm_source=chatgpt.com#top": "https://a.example/p?x=1#top",
            "https://a.example/p?x=1&amp;utm_source=openai&amp;y=2": "https://a.example/p?x=1&amp;y=2",
            "https://a.example/p?utm_source=chatgpt.community": "https://a.example/p?utm_source=chatgpt.community",
            "https://a.example/p?utm_source=newsletter": "https://a.example/p?utm_source=newsletter",
        }
        for url, expected in cases.items():
            self.assertEqual(chat_artifacts.strip_link_tracking(url)[0], expected)

    def test_citation_markers_go_and_the_sentence_still_reads(self):
        text = ("Fact one \ue200cite\ue202turn0search0\ue201 and two 【4†source】. Three citeturn0search0turn1news2 done."
                " Four :contentReference[oaicite:0]{index=0}\n")
        cleaned, counts = chat_artifacts.clean_text(text)
        self.assertEqual(cleaned, "Fact one and two. Three done. Four\n")
        self.assertEqual(counts, {"links": 0, "citations": 4, "attributes": 0})
        self.assertEqual(chat_artifacts.clean_text("We cite turn 3 of the 【game】 here.")[0], "We cite turn 3 of the 【game】 here.")

    def test_page_attributes_are_removed_only_from_html(self):
        html = '<p data-start="10" data-end="42" class="x">a</p><div data-message-id="abc" data-custom="keep">b</div>'
        cleaned, counts = chat_artifacts.clean_text(html, html=True)
        self.assertEqual(cleaned, '<p class="x">a</p><div data-custom="keep">b</div>')
        self.assertEqual(counts["attributes"], 3)
        self.assertEqual(chat_artifacts.clean_text(html)[0], html)

    def test_every_sentence_is_in_the_catalog(self):
        counts = {"links": 2, "citations": 1, "attributes": 3}
        sentences = chat_artifacts.findings(counts) + chat_artifacts.actions(counts)
        sentences += chat_artifacts.findings({"links": 1}) + chat_artifacts.actions({"links": 1, "citations": 2, "attributes": 1})
        sentences += [generator_fields._sentence({"kind": kind, "tag": "IFD0:Software", "value": "Midjourney"})
                      for kind in ("settings", "trailing", "software", "wording")]
        sentences += [generator_fields.UNAVAILABLE, "Removed PNG text chunk prompt", "Removed generator field IFD0:Software",
                      "Removed all metadata: a generator field couldn't be removed on its own."]
        for sentence in sentences:
            self.assertTrue(_covered(sentence), sentence)


class ThroughTheHelper(unittest.TestCase):
    def setUp(self):
        self.helper = HelperProcess()
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)

    def tearDown(self):
        self.helper.close()
        self.directory.cleanup()

    def inspect(self, name: str, data: bytes) -> dict:
        path = self.root / name
        path.write_bytes(data)
        response = self.helper.exchange({"requestID": "i", "operation": "inspect", "inputPath": str(path)}, timeout=120)
        self.assertTrue(response["ok"], response)
        return response["report"]

    def clean(self, name: str, options: dict | None = None) -> tuple[bytes, dict]:
        output = self.root / ("out-" + name)
        response = self.helper.exchange({
            "requestID": "c", "operation": "clean", "inputPath": str(self.root / name), "outputPath": str(output),
            "options": CONSERVATIVE_OPTIONS if options is None else options,
        }, timeout=120)
        self.assertTrue(response["ok"], response)
        return output.read_bytes(), response["report"]

    def test_a_generator_in_exif_is_reported_and_removed_while_ordinary_fields_stay(self):
        data = _tagged(JPEG, ".jpg", "-Software=Midjourney 6.1", "-Artist=Jane Doe", "-IPTC:Credit=Made with Google AI")
        report = self.inspect("photo.jpg", data)
        self.assertTrue(report["has_ai_metadata"])
        self.assertIn("Generator field IFD0:Software names an AI tool: Midjourney 6.1", report["findings"])
        self.assertEqual(len(report["findings"]), len(report["findings_confidence"]))

        cleaned, clean_report = self.clean("photo.jpg")
        self.assertNotIn(b"Midjourney", cleaned)
        self.assertNotIn(b"Google AI", cleaned)
        self.assertNotIn(b"ExifTool", cleaned, "the tool that removed the field must not sign the copy")
        self.assertIn("Jane Doe", _tags(cleaned, ".jpg"))
        self.assertIn("Removed generator field IFD0:Software", clean_report["actions"])
        self.assertEqual(clean_report["post_findings"], [])
        self.assertEqual(cleaned[cleaned.index(b"\xff\xda"):], data[data.index(b"\xff\xda"):], "image data is untouched")
        self.assertFalse(self.inspect("again.jpg", cleaned)["has_ai_metadata"])

    def test_ordinary_text_that_mentions_a_product_is_left_alone(self):
        data = _tagged(JPEG, ".jpg", "-Artist=Sora Tanaka", "-ImageDescription=The Gemini capsule, photographed in Luma")
        report = self.inspect("museum.jpg", data)
        self.assertFalse(report["has_ai_metadata"])
        cleaned, _ = self.clean("museum.jpg")
        self.assertEqual(cleaned, data)

    def test_generation_settings_in_png_text_chunks_are_removed_and_the_rest_kept(self):
        data = _png(("prompt", '{"3": {"class_type": "KSampler"}}'), ("workflow", '{"nodes": []}'),
                    ("parameters", "a cat\nSteps: 20, Sampler: Euler a"), ("Author", "Jane Doe"))
        report = self.inspect("render.png", data)
        self.assertIn("Generation metadata in PNG text chunk workflow", report["findings"])
        cleaned, clean_report = self.clean("render.png")
        self.assertEqual(cleaned, _png(("Author", "Jane Doe")))
        self.assertIn("Removed PNG text chunk prompt", clean_report["actions"])

    def test_a_field_that_cannot_be_edited_alone_takes_all_metadata_with_it(self):
        data = _mp3((b"TENC", "ElevenLabs"), (b"TIT2", "My song"))
        report = self.inspect("voice.mp3", data)
        self.assertTrue(report["has_ai_metadata"], report)
        cleaned, clean_report = self.clean("voice.mp3")
        self.assertNotIn(b"ElevenLabs", cleaned)
        self.assertIn("Removed all metadata: a generator field couldn't be removed on its own.", clean_report["actions"])
        self.assertTrue(data.endswith(cleaned), "the audio frames are untouched")

    def test_chat_leftovers_in_markdown_are_reported_and_removed(self):
        text = ("See [source](https://a.example/p?utm_source=chatgpt.com).\n\n"
                "A fact \ue200cite\ue202turn0search0\ue201 and another 【4†source】.\n")
        report = self.inspect("notes.md", text.encode())
        self.assertIn("AI chat link tracking (utm_source) in 1 link", report["findings"])
        self.assertIn("AI chat citation markers: 2", report["findings"])
        cleaned, clean_report = self.clean("notes.md")
        self.assertEqual(cleaned.decode(), "See [source](https://a.example/p).\n\nA fact and another.\n")
        self.assertIn("Removed 2 AI chat citation markers", clean_report["actions"])
        self.assertEqual(clean_report["post_findings"], [])

    def test_plain_text_keeps_its_character_counts_beside_the_chat_actions(self):
        (self.root / "a.txt").write_text("One\u200b 【1†source】 two.\n", "utf-8")
        cleaned, report = self.clean("a.txt")
        self.assertEqual(cleaned.decode(), "One two.\n")
        self.assertEqual(report["stats"]["removed_count"], 1)
        self.assertEqual(report["actions"], ["Removed 1 AI chat citation marker"])
        self.assertTrue(report["changed"])

    def test_a_word_hyperlink_loses_its_tracking_and_other_parts_keep_their_bytes(self):
        data = _docx("Text 【4†source】 here.", "https://a.example/p?x=1&amp;utm_source=chatgpt.com")
        report = self.inspect("essay.docx", data)
        self.assertIn("AI chat link tracking (utm_source) in 1 link", report["findings"])
        cleaned, _ = self.clean("essay.docx")
        with zipfile.ZipFile(io.BytesIO(cleaned)) as archive:
            self.assertIn('Target="https://a.example/p?x=1"', archive.read("word/_rels/document.xml.rels").decode())
            self.assertIn("<w:t>Text here.</w:t>", archive.read("word/document.xml").decode())
            self.assertEqual(archive.read("word/embeddings/object.bin"), bytes(range(256)) * 8)
            self.assertIsNone(archive.testzip())

    def test_a_pdf_link_loses_its_tracking(self):
        content = b"BT /F1 12 Tf 24 80 Td (Linked) Tj ET"
        data = _assemble_pdf([
            b"<< /Type /Catalog /Pages 2 0 R >>",
            b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 160] /Annots [6 0 R]"
            b" /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
            b"<< /Length %d >>\nstream\n" % len(content) + content + b"\nendstream",
            b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            b"<< /Type /Annot /Subtype /Link /Rect [24 20 180 40]"
            b" /A << /S /URI /URI (https://a.example/p?utm_source=chatgpt.com&x=1) >> >>",
        ])
        report = self.inspect("linked.pdf", data)
        self.assertIn("AI chat link tracking (utm_source) in 1 link", report["findings"])
        cleaned, clean_report = self.clean("linked.pdf")
        expanded = pdf_traces.expand_object_streams(cleaned)
        self.assertIn(b"https://a.example/p?x=1", expanded)
        self.assertNotIn(b"utm_source", expanded)
        self.assertEqual(clean_report["post_findings"], [])

    def test_a_property_edit_does_not_sign_the_file_with_the_editing_tool(self):
        for name, data in (("photo.jpg", JPEG), ("render.png", _png())):
            (self.root / name).write_bytes(data)
            cleaned, _ = self.clean(name, {"metadataEdits": {"author": "Jane Doe", "title": "My file"}})
            self.assertNotIn(b"ExifTool", cleaned, name)
            self.assertIn("Jane Doe", _tags(cleaned, Path(name).suffix))


if __name__ == "__main__":
    unittest.main()
