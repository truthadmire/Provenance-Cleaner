"""Regression tests: ZIP central directories are counted before zipfile builds them."""
from __future__ import annotations

import io
import struct
import sys
import tempfile
import unittest
import zipfile
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Helper"))

import chat_artifacts  # noqa: E402
import office_credentials  # noqa: E402
import zip_guard  # noqa: E402
from test_provenance_helper import CONSERVATIVE_OPTIONS, FIXTURES, HELPER, HelperProcess  # noqa: E402


def _flat_zip(entries: int, *, prefix: bytes = b"", zip64: bool = False, name_width: int = 6) -> bytes:
    """*entries* minimal central-directory records that all point at one empty stored member."""
    local = struct.pack("<4s5H3L2H", b"PK\x03\x04", 20, 0, 0, 0, 0, 0, 0, 0, 1, 0) + b"a"
    records = b"".join(
        struct.pack(zipfile.structCentralDir, zipfile.stringCentralDir, 20, 0, 20, 0, 0, 0, 0, 0, 0, 0, 0,
                    name_width, 0, 0, 0, 0, 0, 0)
        + str(index).zfill(name_width).encode()
        for index in range(entries)
    )
    cd_offset = len(local)
    body = local + records
    if not zip64:
        eocd = struct.pack(zipfile.structEndArchive, zipfile.stringEndArchive, 0, 0,
                           min(entries, 0xFFFF), min(entries, 0xFFFF), len(records), cd_offset, 0)
        return prefix + body + eocd
    end64_offset = len(body)
    end64 = struct.pack(zipfile.structEndArchive64, zipfile.stringEndArchive64, 44, 45, 45, 0, 0,
                        entries, entries, len(records), cd_offset)
    locator = struct.pack(zipfile.structEndArchive64Locator, zipfile.stringEndArchive64Locator, 0, end64_offset, 1)
    eocd = struct.pack(zipfile.structEndArchive, zipfile.stringEndArchive, 0, 0,
                       0xFFFF, 0xFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0)
    return prefix + body + end64 + locator + eocd


def _entry_count(data: bytes) -> int:
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        return len(archive.infolist())


class ZipGuardUnitTests(unittest.TestCase):
    def test_private_zipfile_helpers_are_present(self) -> None:
        for name in ("_EndRecData", "_handle_prepended_data", "_ECD_SIZE", "_CD_SIGNATURE",
                     "_CD_FILENAME_LENGTH", "_CD_EXTRA_FIELD_LENGTH", "_CD_COMMENT_LENGTH",
                     "structCentralDir", "sizeCentralDir", "stringCentralDir"):
            self.assertTrue(hasattr(zipfile, name), name)

    def test_entry_limit_is_exact(self) -> None:
        at_limit = _flat_zip(zip_guard.MAX_ZIP_ENTRIES)
        zip_guard.check(at_limit)
        self.assertEqual(_entry_count(at_limit), zip_guard.MAX_ZIP_ENTRIES)
        with self.assertRaises(zip_guard.ZipTooComplex):
            zip_guard.check(_flat_zip(zip_guard.MAX_ZIP_ENTRIES + 1))

    def test_prepended_data_and_zip64_are_counted_like_zipfile(self) -> None:
        for kwargs in ({"prefix": b"\x89PNG not really" * 10}, {"zip64": True}, {"zip64": True, "prefix": b"x" * 77}):
            with self.subTest(**{k: bool(v) for k, v in kwargs.items()}):
                accepted = _flat_zip(25, **kwargs)
                zip_guard.check(accepted)
                self.assertEqual(_entry_count(accepted), 25)
                with self.assertRaises(zip_guard.ZipTooComplex):
                    zip_guard.check(_flat_zip(zip_guard.MAX_ZIP_ENTRIES + 1, **kwargs))

    def test_file_object_position_is_restored(self) -> None:
        stream = io.BytesIO(_flat_zip(3))
        stream.seek(5)
        zip_guard.check(stream)
        self.assertEqual(stream.tell(), 5)

    def test_inputs_zipfile_rejects_are_left_to_zipfile(self) -> None:
        valid = _flat_zip(3)
        truncated_eocd = valid[:-10]
        bad_signature = valid.replace(zipfile.stringCentralDir, b"PK\x09\x09", 1)
        truncated_directory = valid[:31] + valid[31 + 20:]
        for label, data in (("not zip", b"plain text " * 100), ("empty", b""),
                            ("truncated eocd", truncated_eocd), ("bad signature", bad_signature),
                            ("truncated directory", truncated_directory)):
            with self.subTest(label):
                zip_guard.check(data)
                if label != "truncated eocd":
                    with self.assertRaises(zipfile.BadZipFile):
                        zipfile.ZipFile(io.BytesIO(data))

    def test_oversized_declared_directory_is_refused_without_reading_it(self) -> None:
        size = zip_guard.MAX_CENTRAL_DIRECTORY_BYTES + 1

        class Spy(io.BytesIO):
            largest = 0

            def read(self, n: int = -1) -> bytes:  # type: ignore[override]
                Spy.largest = max(Spy.largest, n)
                return super().read(n)

        local = struct.pack("<4s5H3L2H", b"PK\x03\x04", 20, 0, 0, 0, 0, 0, 0, 0, 1, 0) + b"a"
        record = struct.pack(zipfile.structCentralDir, zipfile.stringCentralDir, 20, 0, 20, 0, 0, 0, 0, 0, 0, 0, 0,
                             1, 0, 0, 0, 0, 0, 0) + b"a"
        # The directory is said to be large; only its first record is present
        # and the declared offset puts its start right after the local header.
        directory = record + b"\x00" * (size - len(record))
        eocd = struct.pack(zipfile.structEndArchive, zipfile.stringEndArchive, 0, 0, 1, 1, size, len(local), 0)
        stream = Spy(local + directory + eocd)
        with self.assertRaises(zip_guard.ZipTooComplex):
            zip_guard.check(stream)
        self.assertLess(Spy.largest, 1 << 20)

    def test_real_fixtures_pass(self) -> None:
        for fixture in sorted(FIXTURES.glob("*.docx")):
            with self.subTest(fixture.name):
                zip_guard.check(fixture.read_bytes())
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
            for index in range(300):
                archive.writestr(f"OEBPS/chapter{index}.xhtml", "<html/>" * 50)
        zip_guard.check(buffer.getvalue())


class OfficeCredentialGuardTests(unittest.TestCase):
    def test_too_many_entries_is_an_incomplete_inspection(self) -> None:
        with tempfile.TemporaryDirectory(prefix="zip-guard-") as temp:
            path = Path(temp) / "many.docx"
            path.write_bytes(_flat_zip(zip_guard.MAX_ZIP_ENTRIES + 1))
            calls = []
            result = office_credentials.inspect_office(path, lambda *a, **k: calls.append(a) or {})
        self.assertEqual(calls, [])
        self.assertIs(result["ok"], False)
        self.assertTrue(result["details"]["inspectionIncomplete"])
        self.assertEqual(result["details"]["state"], "inconclusive")
        self.assertTrue(any("entries" in error for error in result["details"]["coverageErrors"]))


class ChatArtifactBudgetTests(unittest.TestCase):
    def test_highly_compressed_binary_member_is_not_fully_expanded(self) -> None:
        member_size = chat_artifacts.MAX_EXPANDED_BYTES + (1 << 20)
        compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
        chunk = b"\x00" * (8 << 20)
        compressed = b"".join(compressor.compress(chunk) for _ in range(member_size // len(chunk)))
        compressed += compressor.compress(b"\x00" * (member_size % len(chunk))) + compressor.flush()
        crc = 0
        for _ in range(member_size // len(chunk)):
            crc = zlib.crc32(chunk, crc)
        crc = zlib.crc32(b"\x00" * (member_size % len(chunk)), crc)
        data = _raw_deflated_zip(
            [("word/document.xml", b"<w:t>see https://x.test/?utm_source=chatgpt.com</w:t>"),],
            ("word/media/blob.bin", compressed, crc, member_size),
        )

        reads = []
        original_open = zipfile.ZipFile.open

        def spying_open(self, name, mode="r", *args, **kwargs):  # type: ignore[no-untyped-def]
            stream = original_open(self, name, mode, *args, **kwargs)
            original_read = stream.read

            def read(n=-1):  # type: ignore[no-untyped-def]
                reads.append(n)
                return original_read(n)

            stream.read = read  # type: ignore[method-assign]
            return stream

        zipfile.ZipFile.open = spying_open  # type: ignore[method-assign]
        try:
            cleaned, counts = chat_artifacts.clean(data, ".docx")
        finally:
            zipfile.ZipFile.open = original_open  # type: ignore[method-assign]
        self.assertIs(cleaned, data)
        self.assertEqual(counts.get("unchecked"), 1)
        self.assertTrue(all(0 <= n <= chat_artifacts.MAX_EXPANDED_BYTES + 1 for n in reads), reads)
        self.assertIn(chat_artifacts.UNCHECKED_FINDING, chat_artifacts.findings(counts))
        self.assertEqual(chat_artifacts.actions(counts), [])
        report: dict = {"suspicious": False}
        chat_artifacts.present(report, counts)
        self.assertFalse(report["suspicious"])

    def test_normal_archive_is_still_cleaned(self) -> None:
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("word/document.xml", "<w:t>see https://x.test/?utm_source=chatgpt.com</w:t>")
            archive.writestr("word/media/image1.png", b"\x89PNG" + b"\x00" * 5000)
        cleaned, counts = chat_artifacts.clean(buffer.getvalue(), ".docx")
        self.assertEqual(counts, {"links": 1, "citations": 0, "attributes": 0})
        with zipfile.ZipFile(io.BytesIO(cleaned)) as archive:
            self.assertNotIn(b"utm_source", archive.read("word/document.xml"))
            self.assertEqual(len(archive.read("word/media/image1.png")), 5004)


def _raw_deflated_zip(stored: list[tuple[str, bytes]], deflated: tuple[str, bytes, int, int]) -> bytes:
    """A ZIP with stored members plus one member whose deflate stream is given pre-compressed."""
    body = io.BytesIO()
    directory = []
    members = [(name, raw, zlib.crc32(raw), len(raw), 0, len(raw)) for name, raw in stored]
    name, compressed, crc, size = deflated
    members.append((name, compressed, crc, len(compressed), 8, size))
    for name, payload, crc, csize, method, usize in members:
        offset = body.tell()
        encoded = name.encode()
        body.write(struct.pack("<4s5H3L2H", b"PK\x03\x04", 20, 0, method, 0, 0x21, crc, csize, usize, len(encoded), 0))
        body.write(encoded)
        body.write(payload)
        directory.append(
            struct.pack(zipfile.structCentralDir, zipfile.stringCentralDir, 20, 0, 20, 0, 0, method, 0, 0x21,
                        crc, csize, usize, len(encoded), 0, 0, 0, 0, 0, offset) + encoded
        )
    start = body.tell()
    records = b"".join(directory)
    body.write(records)
    body.write(struct.pack(zipfile.structEndArchive, zipfile.stringEndArchive, 0, 0,
                           len(directory), len(directory), len(records), start, 0))
    return body.getvalue()


_COUNTING_WRAPPER = '''
import runpy, sys, zipfile
sys.path.insert(0, {helper_dir!r})
_original = zipfile.ZipFile.__init__
def _counting(self, file, mode="r", *args, **kwargs):
    if mode == "r":
        with open({log!r}, "a") as log:
            log.write("open\\n")
    return _original(self, file, mode, *args, **kwargs)
zipfile.ZipFile.__init__ = _counting
sys.argv[0] = {helper!r}
runpy.run_path({helper!r}, run_name="__main__")
'''


class HelperProtocolGuardTests(unittest.TestCase):
    def test_inspect_scan_and_clean_refuse_before_any_zip_parse(self) -> None:
        with tempfile.TemporaryDirectory(prefix="zip-guard-") as temp:
            folder = Path(temp)
            log = folder / "opens.log"
            wrapper = folder / "counting_helper.py"
            wrapper.write_text(_COUNTING_WRAPPER.format(helper_dir=str(HELPER.parent), log=str(log), helper=str(HELPER)))
            source = folder / "many.docx"
            source.write_bytes(_flat_zip(zip_guard.MAX_ZIP_ENTRIES + 1))
            control = folder / "control.docx"
            control.write_bytes((FIXTURES / "editing-traces.docx").read_bytes())
            with HelperProcess(helper_path=wrapper) as helper:
                responses = [
                    helper.exchange({"requestID": "inspect", "operation": "inspect", "inputPath": str(source)}, timeout=60),
                    helper.exchange({"requestID": "scan", "operation": "scan", "inputPath": str(source)}, timeout=60),
                    helper.exchange({"requestID": "clean", "operation": "clean", "inputPath": str(source),
                                     "outputPath": str(folder / "out.docx"), "options": CONSERVATIVE_OPTIONS}, timeout=60),
                ]
                opens_before_control = log.read_text().count("open") if log.exists() else 0
                ok = helper.exchange({"requestID": "control", "operation": "inspect", "inputPath": str(control)}, timeout=60)
            opens_after_control = log.read_text().count("open") if log.exists() else 0
            self.assertFalse((folder / "out.docx").exists())
        for response in responses:
            with self.subTest(response["requestID"]):
                self.assertIs(response["ok"], False)
                self.assertEqual(response["kind"], "input_too_complex")
                self.assertEqual(response["report"]["details"]["maxEntries"], zip_guard.MAX_ZIP_ENTRIES)
        self.assertEqual(opens_before_control, 0)
        # The wrapper does count real opens: a normal document still reaches zipfile.
        self.assertIs(ok["ok"], True)
        self.assertGreater(opens_after_control, 0)


if __name__ == "__main__":
    unittest.main()
