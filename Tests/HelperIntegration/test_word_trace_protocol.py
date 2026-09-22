import io
import tempfile
import unittest
import zipfile
from pathlib import Path

from test_provenance_helper import HelperProcess
from test_word_editing_traces import specimen, content_tree


class WordTraceProtocolTests(unittest.TestCase):
    def test_inspect_and_randomize_through_public_protocol_preserves_docx(self):
        with tempfile.TemporaryDirectory() as temp, HelperProcess() as helper:
            source, output = Path(temp) / 'input.docx', Path(temp) / 'output.docx'
            source.write_bytes(specimen())
            inspection = helper.exchange({'requestID': 'inspect', 'operation': 'inspect', 'inputPath': str(source)})
            self.assertTrue(inspection['report']['word_editing_traces']['available'])
            self.assertEqual(inspection['report']['word_editing_traces']['sessionIDs'], 2)
            request = {'requestID': 'rewrite', 'operation': 'clean', 'inputPath': str(source), 'outputPath': str(output), 'options': {'wordTraces': {'rsids': 'randomize', 'dates': 'randomize', 'start': '2020-01-01T00:00:00Z', 'end': '2020-02-01T00:00:00Z'}}}
            response = helper.exchange(request)
            self.assertTrue(response['ok'], response)
            self.assertEqual(response['report']['word_trace_changes']['changedFields'], 13)
            with zipfile.ZipFile(source) as original, zipfile.ZipFile(output) as rewritten:
                self.assertEqual(content_tree(original.read('word/document.xml')), content_tree(rewritten.read('word/document.xml')))
                self.assertIn(b'Keep this author', rewritten.read('docProps/core.xml'))
            self.assertEqual(source.read_bytes(), specimen())
            after = helper.exchange({'requestID': 'after', 'operation': 'inspect', 'inputPath': str(output)})
            self.assertEqual(after['report']['word_editing_traces']['sessionIDs'], 2)

    def test_remove_through_protocol_and_reinspect_zero_traces(self):
        with tempfile.TemporaryDirectory() as temp, HelperProcess() as helper:
            source, output = Path(temp) / 'input.docx', Path(temp) / 'output.docx'
            source.write_bytes(specimen())
            response = helper.exchange({'requestID': 'remove', 'operation': 'clean', 'inputPath': str(source), 'outputPath': str(output), 'options': {'wordTraces': {'rsids': 'remove', 'dates': 'remove', 'resetArchiveDates': True}}})
            self.assertTrue(response['ok'], response)
            after = helper.exchange({'requestID': 'after', 'operation': 'inspect', 'inputPath': str(output)})['report']['word_editing_traces']
            self.assertEqual(after['sessionIDs'] + after['annotationDates'] + after['documentDates'], 0)
            self.assertEqual(source.read_bytes(), specimen())

    def test_failed_rewrite_keeps_existing_output_and_helper_recovers(self):
        with tempfile.TemporaryDirectory() as temp, HelperProcess() as helper:
            source, output = Path(temp) / 'input.docx', Path(temp) / 'output.docx'
            source.write_bytes(specimen(malformed_date=True))
            output.write_bytes(b'existing output')
            request = {'requestID': 'bad', 'operation': 'clean', 'inputPath': str(source), 'outputPath': str(output), 'options': {'wordTraces': {'dates': 'randomize', 'start': '2020-01-01T00:00:00Z', 'end': '2020-02-01T00:00:00Z'}}}
            result = helper.exchange(request)
            self.assertFalse(result['ok'])
            self.assertEqual(result['kind'], 'word_trace_error')
            self.assertEqual(output.read_bytes(), b'existing output')
            request['options']['wordTraces'] = {'dates': 'randomize', 'start': 'bad', 'end': 'bad'}
            self.assertEqual(helper.exchange(request)['kind'], 'invalid_options')
            self.assertTrue(helper.exchange({'requestID': 'alive', 'operation': 'capabilities'})['report']['wordEditingTraces']['available'])


if __name__ == '__main__':
    unittest.main()
