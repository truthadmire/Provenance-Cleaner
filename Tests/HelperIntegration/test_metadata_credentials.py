import io
import json
import os
from pathlib import Path
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
            for edits in ({'unknown': 'a'}, {'author': True}, {'author': '\0'}, {'author': 'x'*4097}, {}):
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
                        # ExifTool's incremental update retains page/content bytes.
                        self.assertTrue(output.read_bytes().startswith(data))

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
