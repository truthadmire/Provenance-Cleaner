import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Helper'))
import credential_inspection as credentials
import metadata_editor as metadata
from test_provenance_helper import HelperProcess, FIXTURES, _JPEG_1X1, _png_with_text
from test_word_editing_traces import specimen

# Shaped like Word's own app.xml: a default namespace plus unprefixed attributes.
WORD_APP = (b'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\r\n'
            b'<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" '
            b'xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Template>Normal.dotm</Template>'
            b'<TotalTime>35</TotalTime><Pages>1</Pages><HeadingPairs><vt:vector size="2" baseType="variant"><vt:variant>'
            b'<vt:lpstr>Title</vt:lpstr></vt:variant><vt:variant><vt:i4>1</vt:i4></vt:variant></vt:vector></HeadingPairs>'
            b'<AppVersion>16.0000</AppVersion></Properties>')


def with_part(data, name, raw):
    """The package with one part replaced, or removed when raw is None."""
    output = io.BytesIO()
    with zipfile.ZipFile(io.BytesIO(data)) as source, zipfile.ZipFile(output, 'w') as archive:
        for info in source.infolist():
            if info.filename != name:
                archive.writestr(info, source.read(info))
            elif raw is not None:
                archive.writestr(info, raw)
    return output.getvalue()


def minimal_pdf(*authors, catalog=b"", extra=()):
    """A one-page PDF whose Info author is replaced by each later incremental
    revision, as other apps append them. `extra` objects follow object 4."""
    objects = [b"<< /Type /Catalog /Pages 2 0 R " + catalog + b">>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
               b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>", b"<< /Author (%s) >>" % authors[0], *extra]
    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for number, body in enumerate(objects, 1):
        offsets.append(len(out))
        out += b"%d 0 obj\n%s\nendobj\n" % (number, body)
    previous = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1) + b"".join(b"%010d 00000 n \n" % o for o in offsets)
    out += b"trailer\n<< /Size %d /Root 1 0 R /Info 4 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, previous)
    for author in authors[1:]:
        offset = len(out)
        out += b"4 0 obj\n<< /Author (%s) >>\nendobj\n" % author
        xref = len(out)
        out += b"xref\n0 1\n0000000000 65535 f \n4 1\n%010d 00000 n \n" % offset
        out += b"trailer\n<< /Size %d /Root 1 0 R /Info 4 0 R /Prev %d >>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, previous, xref)
        previous = xref
    return bytes(out)


def pdf_revisions(data):
    return len(re.findall(rb"startxref\s+\d+\s+%%EOF", data))


def office_values(ext, data):
    return {f['id']: f['value'] for f in metadata.inspect(Path('result'+ext), data)['fields']}


class MetadataCredentialTests(unittest.TestCase):
    def request(self, helper, path, operation='inspect', output=None, edits=None):
        request = {'requestID': 'metadata-test', 'operation': operation, 'inputPath': str(path)}
        if output:
            request.update(outputPath=str(output), options={'metadataEdits': edits})
        return helper.exchange(request, timeout=60)

    def test_office_edit_preserves_other_parts_unicode_namespaces_and_removes_field(self):
        for ext in ('.docx', '.xlsx', '.pptx'):
            with self.subTest(ext=ext):
                source = specimen()
                output = metadata.rewrite(source, ext, {'author': '陈 & <Editor>', 'title': '测试标题', 'lastModifiedBy': ''})
                with zipfile.ZipFile(io.BytesIO(source)) as before, zipfile.ZipFile(io.BytesIO(output)) as after:
                    self.assertEqual(before.namelist(), after.namelist())
                    for name in before.namelist():
                        if name != 'docProps/core.xml':
                            self.assertEqual(before.read(name), after.read(name))
                    self.assertIn(b'xmlns:dcterms=', after.read('docProps/core.xml'))
                values = {f['id']: f['value'] for f in metadata.inspect(Path('result'+ext), output)['fields']}
                self.assertEqual(values['author'], '陈 & <Editor>')
                self.assertEqual(values['title'], '测试标题')
                self.assertEqual(values['lastModifiedBy'], '')

    def test_office_revision_and_total_time_roundtrip_and_clear(self):
        for ext in ('.docx', '.xlsx', '.pptx'):
            with self.subTest(ext=ext):
                source = specimen()
                self.assertEqual(office_values(ext, source)['totalTime'], '35')
                self.assertEqual(office_values(ext, source)['revision'], '')
                output = metadata.rewrite(source, ext, {'revision': '007', 'totalTime': '1440'})
                with zipfile.ZipFile(io.BytesIO(source)) as before, zipfile.ZipFile(io.BytesIO(output)) as after:
                    self.assertEqual(before.namelist(), after.namelist())
                    for name in before.namelist():
                        if name not in ('docProps/core.xml', 'docProps/app.xml'):
                            self.assertEqual(before.read(name), after.read(name))
                    self.assertEqual(after.read('docProps/app.xml'),
                                     before.read('docProps/app.xml').replace(b'<TotalTime>35</TotalTime>', b'<TotalTime>1440</TotalTime>'))
                values = office_values(ext, output)
                self.assertEqual((values['revision'], values['totalTime']), ('7', '1440'))
                self.assertEqual(values['author'], 'Keep this author')
                cleared = metadata.rewrite(output, ext, {'revision': '', 'totalTime': ''})
                with zipfile.ZipFile(io.BytesIO(cleared)) as archive:
                    self.assertNotIn(b'TotalTime', archive.read('docProps/app.xml'))
                    self.assertNotIn(b'revision', archive.read('docProps/core.xml'))
                values = office_values(ext, cleared)
                self.assertEqual((values['revision'], values['totalTime']), ('', ''))

    def test_word_app_properties_are_edited_in_place(self):
        source = with_part(specimen(), 'docProps/app.xml', WORD_APP)
        output = metadata.rewrite(source, '.docx', {'totalTime': '0'})
        with zipfile.ZipFile(io.BytesIO(output)) as archive:
            self.assertEqual(archive.read('docProps/app.xml'), WORD_APP.replace(b'>35<', b'>0<'))
            self.assertEqual(archive.read('docProps/core.xml'), zipfile.ZipFile(io.BytesIO(source)).read('docProps/core.xml'))
        missing = WORD_APP.replace(b'<TotalTime>35</TotalTime>', b'')
        output = metadata.rewrite(with_part(specimen(), 'docProps/app.xml', missing), '.docx', {'totalTime': '12'})
        end = missing.index(b'</Properties>')
        with zipfile.ZipFile(io.BytesIO(output)) as archive:
            self.assertEqual(archive.read('docProps/app.xml'), missing[:end] + b'<TotalTime>12</TotalTime>' + missing[end:])

    def test_total_time_needs_application_properties(self):
        source = with_part(specimen(), 'docProps/app.xml', None)
        self.assertNotIn('totalTime', office_values('.docx', source))
        self.assertIn('revision', office_values('.docx', source))
        with self.assertRaises(metadata.MetadataError):
            metadata.rewrite(source, '.docx', {'totalTime': '5'})

    def test_revision_and_total_time_must_be_whole_numbers(self):
        for key in ('revision', 'totalTime'):
            for bad in ('abc', '-1', '1.5', ' 3', '1e3', '2147483648', '١٢'):
                with self.subTest(key=key, value=bad), self.assertRaises(metadata.MetadataError):
                    metadata.validate_options({key: bad})
            self.assertEqual(metadata.validate_options({key: '2147483647'}), {key: '2147483647'})
        with self.assertRaises(metadata.MetadataError):
            metadata.rewrite(_JPEG_1X1, '.jpg', {'revision': '3'})

    def test_signed_office_is_readable_but_edit_refused(self):
        buffer = io.BytesIO(specimen())
        with zipfile.ZipFile(buffer, 'a') as archive:
            archive.writestr('_xmlsignatures/sig1.xml', '<Signature/>')
        data = buffer.getvalue()
        self.assertFalse(metadata.inspect(Path('signed.docx'), data)['editable'])
        with self.assertRaises(metadata.MetadataError):
            metadata.rewrite(data, '.docx', {'author': 'new'})

    def test_metadata_protocol_keeps_original_and_reports_verified_changes(self):
        with tempfile.TemporaryDirectory() as folder, HelperProcess() as helper:
            source, output = Path(folder)/'original.docx', Path(folder)/'copy.docx'
            source.write_bytes(specimen())
            before = self.request(helper, source)
            self.assertTrue(before['report']['metadata']['editable'])
            self.assertEqual(before['report']['c2pa']['document']['state'], 'absent')
            # The specimen includes an intentionally unknown word/media/keep.bin.
            self.assertTrue(before['report']['c2pa']['inspectionIncomplete'])
            result = self.request(helper, source, 'clean', output, {'author': 'Alice', 'title': ''})
            self.assertTrue(result['ok'], result)
            self.assertEqual(source.read_bytes(), specimen())
            after = self.request(helper, output)['report']['metadata']
            self.assertEqual(next(f['value'] for f in after['fields'] if f['id']=='author'), 'Alice')

    def test_invalid_options_never_overwrite_existing_output(self):
        with tempfile.TemporaryDirectory() as folder, HelperProcess() as helper:
            source, output = Path(folder)/'original.docx', Path(folder)/'copy.docx'
            source.write_bytes(specimen()); output.write_bytes(b'keep')
            for edits in ({'unknown': 'a'}, {'author': True}, {'author': '\0'}, {'author': 'x'*4097}, {'totalTime': 'abc'}, {}):
                result = self.request(helper, source, 'clean', output, edits)
                self.assertFalse(result['ok'])
                self.assertEqual(output.read_bytes(), b'keep')

    def test_jpeg_png_pdf_unicode_roundtrip_and_clear(self):
        specimens = {'.jpg': _JPEG_1X1, '.png': _png_with_text(('Title', 'Old title')), '.pdf': (FIXTURES/'embedded-provenance.pdf').read_bytes()}
        with tempfile.TemporaryDirectory() as folder, HelperProcess() as helper:
            for ext, data in specimens.items():
                with self.subTest(ext=ext):
                    source, output, cleared = (Path(folder)/(name+ext) for name in ('original', 'edited', 'cleared'))
                    source.write_bytes(data)
                    result = self.request(helper, source, 'clean', output, {'author': '陈明 & Alice', 'title': 'New title'})
                    self.assertTrue(result['ok'], result)
                    self.assertEqual(source.read_bytes(), data)
                    after = self.request(helper, output)['report']['metadata']
                    self.assertEqual(next(f['value'] for f in after['fields'] if f['id']=='author'), '陈明 & Alice')
                    result = self.request(helper, output, 'clean', cleared, {'author': ''})
                    self.assertTrue(result['ok'], result)
                    after = self.request(helper, cleared)['report']['metadata']
                    self.assertEqual(next(f['value'] for f in after['fields'] if f['id']=='author'), '')
                    if ext == '.pdf':
                        # Rewritten, not appended: one revision, no earlier values.
                        self.assertEqual(pdf_revisions(output.read_bytes()), 1)
                        self.assertEqual(pdf_revisions(cleared.read_bytes()), 1)
                        self.assertNotIn('陈明'.encode('utf-16-be'), cleared.read_bytes())

    def test_pdf_edit_removes_earlier_values_and_revisions(self):
        data = minimal_pdf(b'Older Name', b'Original Name')
        self.assertEqual(pdf_revisions(data), 2)
        with tempfile.TemporaryDirectory() as folder, HelperProcess() as helper:
            source, output = Path(folder)/'original.pdf', Path(folder)/'edited.pdf'
            source.write_bytes(data)
            before = self.request(helper, source)['report']['metadata']
            self.assertEqual(next(f['value'] for f in before['fields'] if f['id']=='author'), 'Original Name')
            self.assertIn('earlier property values are removed', before['note'])
            result = self.request(helper, source, 'clean', output, {'author': 'New Name', 'title': 'Report'})
            self.assertTrue(result['ok'], result)
            self.assertEqual(source.read_bytes(), data)
            edited = output.read_bytes()
            self.assertEqual(pdf_revisions(edited), 1)
            for earlier in (b'Older Name', b'Original Name'):
                self.assertNotIn(earlier, edited)
            after = self.request(helper, output)['report']['metadata']
            values = {f['id']: f['value'] for f in after['fields']}
            self.assertEqual((values['author'], values['title']), ('New Name', 'Report'))

    def test_signed_pdf_says_the_signature_will_stop_validating(self):
        signature = b'<< /FT /Sig /T (Signature1) /V << /Type /Sig /Filter /Adobe.PPKLite /ByteRange [0 0 0 0] /Contents <00> >> >>'
        data = minimal_pdf(b'Signer', catalog=b'/AcroForm << /Fields [5 0 R] /SigFlags 3 >> ', extra=(signature,))
        with tempfile.TemporaryDirectory() as folder, HelperProcess() as helper:
            source = Path(folder)/'signed.pdf'
            source.write_bytes(data)
            metadata = self.request(helper, source)['report']['metadata']
            self.assertTrue(metadata['editable'])
            self.assertIn('signature will no longer validate', metadata['note'])

    def test_real_certificate_chain_and_trust_are_separate_from_signature(self):
        with HelperProcess() as helper:
            result = self.request(helper, FIXTURES/'signed-c2pa.jpg')
            self.assertTrue(result['ok'], result)
            c2pa = result['report']['c2pa']
            self.assertEqual(c2pa['state'], 'present')
            self.assertEqual(c2pa['signature'], 'valid')
            self.assertEqual(c2pa['contentBinding'], 'valid')
            self.assertEqual(c2pa['trust'], 'untrusted')
            self.assertEqual(len(c2pa['certificates']), 2)
            self.assertTrue(c2pa['certificates'][0]['sha256'])
            self.assertIn('2030', c2pa['certificates'][0]['notAfter'])

    def test_tampered_image_reports_content_binding_failure(self):
        with tempfile.TemporaryDirectory() as folder, HelperProcess() as helper:
            data = bytearray((FIXTURES/'signed-c2pa.jpg').read_bytes())
            start = data.index(b'\xff\xda')
            offset = start + 2 + int.from_bytes(data[start+2:start+4], 'big') + 8
            data[offset] ^= 1
            path = Path(folder)/'tampered.jpg'; path.write_bytes(data)
            c2pa = self.request(helper, path)['report']['c2pa']
            self.assertEqual(c2pa['state'], 'present')
            self.assertEqual(c2pa['contentBinding'], 'invalid')
            self.assertNotEqual(c2pa['validationState'], 'Trusted')

    def test_tool_error_mentions_are_not_manifest_evidence(self):
        with patch.object(credentials.shutil, 'which', return_value='/tool'), patch.dict(os.environ, {'C2PATOOL_SETTINGS': '/offline'}):
            with patch.object(credentials, '_run', return_value=subprocess.CompletedProcess([], 1, '', 'C2PA manifest parser error')):
                report = credentials.inspect('/file.jpg')
                self.assertFalse(report['has_manifest'])
                self.assertFalse(report['ok'])
                self.assertEqual(report['details']['state'], 'inconclusive')
            with patch.object(credentials, '_run', return_value=subprocess.CompletedProcess([], 1, '', 'Error: No claim found')):
                report = credentials.inspect('/file.jpg')
                self.assertTrue(report['ok'])
                self.assertEqual(report['details']['state'], 'absent')

    def test_empty_validation_list_does_not_imply_valid_or_trusted(self):
        report = credentials.summarize({'active_manifest': 'a', 'manifests': {'a': {}}, 'validation_status': []})
        self.assertEqual(report['signature'], 'unknown')
        self.assertEqual(report['trust'], 'unknown')
        self.assertEqual(report['contentBinding'], 'unknown')

    def test_incomplete_certificate_extraction_keeps_presence_and_marks_error(self):
        payload = {'active_manifest': 'a', 'manifests': {'a': {}}}
        with patch.object(credentials.shutil, 'which', return_value='/tool'), patch.dict(os.environ, {'C2PATOOL_SETTINGS': '/offline'}), patch.object(credentials, '_run', side_effect=[subprocess.CompletedProcess([], 0, json.dumps(payload), ''), subprocess.CompletedProcess([], 1, '', 'bad chain')]):
            report = credentials.inspect('/file.jpg')
            self.assertTrue(report['has_manifest'])
            self.assertIn('certificateError', report['details'])

if __name__ == '__main__':
    unittest.main()
