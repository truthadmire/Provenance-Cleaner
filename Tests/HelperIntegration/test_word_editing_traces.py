from __future__ import annotations

import io
import re
import sys
import unittest
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from xml.etree import ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Helper"))
import word_editing_traces as traces

W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

def specimen(*, malformed_date=False, prefix="w") -> bytes:
    date = "not-a-date" if malformed_date else "2024-01-03T10:00:00Z"
    parts = {
        "[Content_Types].xml": '''<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="bin" ContentType="application/octet-stream"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/comments.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.comments+xml"/><Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/></Types>''',
        "_rels/.rels": '''<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/></Relationships>''',
        "word/_rels/document.xml.rels": '''<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments" Target="comments.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings" Target="settings.xml"/></Relationships>''',
        "word/document.xml": f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="{W}" xmlns:other="urn:unrelated" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" mc:Ignorable="other"><w:body>
<w:p w:rsidR="00112233" other:rsidR="00112233"><w:pPr><w:spacing w:after="220"/></w:pPr><w:r><w:rPr><w:b/></w:rPr><w:t>Editing traces specimen</w:t></w:r></w:p>
<w:p w:rsidR="00445566"><w:commentRangeStart w:id="0"/><w:r><w:t xml:space="preserve">Original text — naïve\u00a0spacing. </w:t></w:r><w:ins w:id="1" w:author="Reviewer" w:date="{date}"><w:r w:rsidR="00445566"><w:t>Added text.</w:t></w:r></w:ins><w:del w:id="2" w:author="Reviewer" w:date="2024-01-04T10:00:00Z"><w:r><w:delText>Earlier text.</w:delText></w:r></w:del><w:commentRangeEnd w:id="0"/><w:r><w:commentReference w:id="0"/></w:r></w:p>
<w:p><w:r><w:t>Literal rsidR=\"00112233\" stays as text.</w:t></w:r></w:p>
<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr></w:body></w:document>''',
        "word/settings.xml": f'''<w:settings xmlns:w="{W}"><w:trackRevisions/><w:rsids><w:rsidRoot w:val="00112233"/><w:rsid w:val="00112233"/><w:rsid w:val="00445566"/></w:rsids></w:settings>''',
        "word/comments.xml": f'''<w:comments xmlns:w="{W}" xmlns:wd="http://schemas.microsoft.com/office/word/2023/wordml/word16du" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" mc:Ignorable="wd"><w:comment w:id="0" w:author="Reviewer" w:initials="RV" w:date="2024-01-03T11:00:00+01:00" wd:dateUtc="2024-01-03T10:00:00Z"><w:p><w:r><w:t>Keep this comment.</w:t></w:r></w:p></w:comment></w:comments>''',
        "docProps/core.xml": '''<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:creator>Keep this author</dc:creator><cp:lastModifiedBy>Keep this editor</cp:lastModifiedBy><dcterms:created xsi:type="dcterms:W3CDTF">2024-01-01T10:00:00Z</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">2024-01-05T10:00:00Z</dcterms:modified><cp:lastPrinted>2024-01-05T09:00:00Z</cp:lastPrinted></cp:coreProperties>''',
        "docProps/app.xml": '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>Microsoft Word</Application><TotalTime>35</TotalTime></Properties>',
    }
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as archive:
        for name, value in parts.items():
            info = zipfile.ZipInfo(name, (2024, 1, 6, 10, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            if prefix != "w":
                value = value.replace('xmlns:w=', f'xmlns:{prefix}=').replace('w:', f'{prefix}:')
            archive.writestr(info, value)
        archive.writestr(zipfile.ZipInfo("word/media/keep.bin", (2024, 1, 6, 10, 0, 0)), b"\x00unchanged payload\xff")
    return buf.getvalue()


def content_tree(raw):
    root = ET.fromstring(raw)
    for element in root.iter():
        for key in list(element.attrib):
            local = key.split('}')[-1]
            if key.startswith('{' + W + '}') and (local in traces.RSID_NAMES or local == 'date'):
                del element.attrib[key]
            elif key.startswith('{http://schemas.microsoft.com/office/word/') and local == 'dateUtc':
                del element.attrib[key]
    return ET.tostring(root)


class WordEditingTracesTests(unittest.TestCase):
    def test_inspection_distinguishes_ids_dates_and_keeps_input(self):
        data = specimen()
        report = traces.inspect(data)
        self.assertTrue(report['available'])
        self.assertEqual(report['sessionIDs'], 2)
        self.assertEqual(report['rsidReferences'], 6)
        self.assertEqual(report['annotationDates'], 4)
        self.assertEqual(report['documentDates'], 3)
        self.assertEqual(report['earliest'], '2024-01-01T10:00:00Z')
        self.assertEqual(data, specimen())

    def test_randomization_preserves_order_equal_instants_and_document_contents(self):
        data = specimen()
        result, report = traces.rewrite(data, {'dates': 'randomize', 'start': '2020-01-01T00:00:00Z', 'end': '2020-02-01T00:00:00Z'})
        self.assertEqual(report['changedFields'], 13)
        id_changes = [x for x in report['changes'] if x['kind'] == 'rsid']
        for old in {x['before'] for x in id_changes}:
            targets = {x['after'] for x in id_changes if x['before'] == old}
            self.assertEqual(len(targets), 1)
            self.assertNotIn(old, targets)
        changes = [x for x in report['changes'] if x['kind'] != 'rsid']
        mapping = {}
        for item in changes:
            before, after = traces.parse_date(item['before']), traces.parse_date(item['after'])
            self.assertEqual(mapping.setdefault(before, after), after)
            self.assertGreaterEqual(after, datetime(2020, 1, 1, tzinfo=timezone.utc))
            self.assertLessEqual(after, datetime(2020, 2, 1, tzinfo=timezone.utc))
        self.assertEqual(sorted(mapping.values()), [mapping[key] for key in sorted(mapping)])
        with zipfile.ZipFile(io.BytesIO(data)) as original, zipfile.ZipFile(io.BytesIO(result)) as cleaned:
            self.assertEqual(original.namelist(), cleaned.namelist())
            for name in original.namelist():
                if name in ['word/document.xml', 'word/comments.xml']:
                    self.assertEqual(content_tree(original.read(name)), content_tree(cleaned.read(name)))
                elif name not in ['word/settings.xml', 'docProps/core.xml']:
                    self.assertEqual(original.read(name), cleaned.read(name), name)
            self.assertIn(b'Keep this author', cleaned.read('docProps/core.xml'))
            self.assertIn(b'mc:Ignorable="other"', cleaned.read('word/document.xml'))
        self.assertEqual(data, specimen())

    def test_remove_all_trace_fields_keeps_revision_text_and_other_namespaces(self):
        data = specimen(prefix='v')
        output, report = traces.rewrite(data, {'rsids': 'remove', 'dates': 'remove', 'resetArchiveDates': True})
        self.assertEqual(report['after']['sessionIDs'], 0)
        self.assertEqual(report['after']['documentDates'], 0)
        self.assertEqual(report['after']['annotationDates'], 0)
        with zipfile.ZipFile(io.BytesIO(output)) as archive:
            raw = archive.read('word/document.xml')
            self.assertIn(b'other:rsidR="00112233"', raw)
            self.assertIn(b'Earlier text.', raw)
            self.assertIn(b'<v:ins v:id="1" v:author="Reviewer">', raw)
            self.assertNotIn(b':rsids', archive.read('word/settings.xml'))
            for info in archive.infolist():
                self.assertEqual(info.date_time, (1980, 1, 1, 0, 0, 0))

    def test_keep_all_is_byte_identical(self):
        data = specimen()
        result, report = traces.rewrite(data, {'rsids': 'keep', 'dates': 'keep'})
        self.assertEqual(result, data)
        self.assertEqual(report['changedFields'], 0)

    def test_invalid_dates_refused_for_randomize_but_removable(self):
        data = specimen(malformed_date=True)
        self.assertEqual(traces.inspect(data)['invalidDates'], 1)
        with self.assertRaises(traces.WordTraceError):
            traces.rewrite(data, {'dates': 'randomize', 'start': '2020-01-01T00:00:00Z', 'end': '2021-01-01T00:00:00Z'})
        self.assertEqual(traces.rewrite(data, {'dates': 'remove'})[1]['after']['invalidDates'], 0)

    def test_small_date_range_is_refused_without_merging_distinct_times(self):
        with self.assertRaisesRegex(traces.WordTraceError, 'wider'):
            traces.rewrite(specimen(), {'dates': 'randomize', 'start': '2020-01-01T00:00:00Z', 'end': '2020-01-01T00:00:01Z'})

    def test_malformed_xml_and_dtd_are_refused(self):
        for raw in [b'<w:document>', b'<!DOCTYPE x [<!ENTITY a "x">]><x>&a;</x>']:
            with self.subTest(raw=raw), self.assertRaises(traces.WordTraceError):
                traces._xml_fields('word/document.xml', raw)

    def test_signed_package_refused_and_reported(self):
        data = io.BytesIO(specimen())
        with zipfile.ZipFile(data, 'a') as archive:
            archive.writestr('_xmlsignatures/sig1.xml', '<Signature/>')
        self.assertTrue(traces.inspect(data.getvalue())['signed'])
        with self.assertRaisesRegex(traces.WordTraceError, 'signature'):
            traces.rewrite(data.getvalue(), {})

    def test_option_validation_and_xml_encoding_fail_explicitly(self):
        for options in [{'rsids': []}, {'dates': 'invent'}, {'resetArchiveDates': 1}, {'surprise': True}, {'dates': 'randomize', 'start': 'yesterday'}]:
            with self.subTest(options=options), self.assertRaises(traces.WordTraceError):
                traces.validate_options(options)
        with self.assertRaisesRegex(traces.WordTraceError, 'UTF-8'):
            traces._xml_fields('word/document.xml', '<document/>'.encode('utf-16'))


if __name__ == '__main__':
    unittest.main()
