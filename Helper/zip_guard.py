"""Count a ZIP archive's central-directory records before zipfile parses them.

zipfile.ZipFile() walks the whole central directory while it is constructed and
allocates a ZipInfo, a decoded name and extra/comment strings for every record.
Minimal records are 46 bytes, so a few MB of input can hold millions of them and
cost seconds and gigabytes per open, before any per-member budget runs. Every
archive handler (upstream and ours) opens the same input several times.

check() reads the same end-of-central-directory record zipfile reads (through
zipfile's own locator, so the two always agree on where the directory is) and
walks the record headers without building anything. Inputs zipfile would
reject anyway are left for zipfile to reject: check() only refuses archives
that zipfile would accept but that exceed MAX_ZIP_ENTRIES records or
MAX_CENTRAL_DIRECTORY_BYTES of directory.

The private zipfile helpers used here exist in the bundled CPython 3.14.x
(release builds pin 3.14.7); Tests/HelperIntegration/test_zip_guard.py asserts
they are present so an interpreter change cannot silently disable the guard.
"""
from __future__ import annotations

import io
import struct
import zipfile
from typing import BinaryIO

# Same limit as office_credentials.MAX_PARTS, word_editing_traces.MAX_PARTS and
# metadata_editor's part check, so every document those accept passes here.
MAX_ZIP_ENTRIES = 10_000
# 10000 records of about 3 KB each. Real OOXML, ODT and EPUB directories are KB-sized.
MAX_CENTRAL_DIRECTORY_BYTES = 32 << 20


class ZipTooComplex(ValueError):
    """The archive has more entries, or a larger central directory, than the helper processes."""


def check(source: bytes | bytearray | memoryview | BinaryIO) -> None:
    """Raise ZipTooComplex when zipfile would materialize too many entries from *source*.

    Returns normally for inputs that are not ZIP archives or that zipfile
    rejects itself (truncated or bad directory), so existing handling of those
    is unchanged. A file object's position is restored afterwards.
    """
    if isinstance(source, (bytes, bytearray, memoryview)):
        fp: BinaryIO = io.BytesIO(source)
        restore = None
    else:
        fp = source
        restore = fp.tell()
    try:
        _check(fp)
    finally:
        if restore is not None:
            fp.seek(restore)


def _too_complex(detail: str) -> ZipTooComplex:
    return ZipTooComplex(
        f"The archive {detail}; at most {MAX_ZIP_ENTRIES} entries and a "
        f"{MAX_CENTRAL_DIRECTORY_BYTES}-byte central directory are processed."
    )


def _check(fp: BinaryIO) -> None:
    try:
        endrec = zipfile._EndRecData(fp)
    except (OSError, zipfile.BadZipFile, struct.error):
        return
    if not endrec:
        return
    try:
        offset_cd, concat = zipfile._handle_prepended_data(endrec)
    except (zipfile.BadZipFile, ValueError):
        return
    start_dir = offset_cd + concat
    if start_dir < 0:
        return  # zipfile raises "Bad offset for central directory".
    size_cd = endrec[zipfile._ECD_SIZE]
    fp.seek(start_dir, 0)
    if size_cd > MAX_CENTRAL_DIRECTORY_BYTES:
        # Only refuse what zipfile would start parsing: a record signature where
        # the directory is said to begin. Anything else is BadZipFile there.
        if fp.read(4) == zipfile.stringCentralDir:
            raise _too_complex(f"declares a {size_cd}-byte central directory")
        return
    data = fp.read(size_cd)
    header = zipfile.sizeCentralDir
    layout = struct.Struct(zipfile.structCentralDir)
    signature = zipfile.stringCentralDir
    name_length = zipfile._CD_FILENAME_LENGTH
    extra_length = zipfile._CD_EXTRA_FIELD_LENGTH
    comment_length = zipfile._CD_COMMENT_LENGTH
    count = 0
    total = 0
    # Mirrors zipfile.ZipFile._RealGetContents: same loop condition, same
    # advance. zipfile reads past the end of a short buffer as empty fields,
    # so only the fixed header needs to be complete.
    while total < size_cd:
        if total + header > len(data):
            return  # "Truncated central directory"
        fields = layout.unpack_from(data, total)
        if fields[zipfile._CD_SIGNATURE] != signature:
            return  # "Bad magic number for central directory"
        count += 1
        if count > MAX_ZIP_ENTRIES:
            raise _too_complex(f"has more than {MAX_ZIP_ENTRIES} entries")
        total += header + fields[name_length] + fields[extra_length] + fields[comment_length]
