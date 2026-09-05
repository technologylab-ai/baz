"""Check externally consumed wrk receipt semantics, including failed loads."""
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('compare', Path(__file__).resolve().parents[1] / 'tools/compare.py')
compare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compare)

class WrkReceiptTests(unittest.TestCase):
    def receipt(self, **changes):
        record = dict(requests=1600, duration_us=2000000, bytes=200000,
                      connect_errors=0, read_errors=0, write_errors=0,
                      status_errors=0, timeout_errors=0, latency_p50_us=10,
                      latency_p99_us=20, latency_max_us=30)
        record.update(changes)
        return 'wrk output\nRESULT ' + json.dumps(record) + '\n'

    def test_counts_are_already_responses_not_batches(self):
        result = compare.parse_wrk(self.receipt())
        self.assertEqual(result['responses_per_second'], 800)
        self.assertTrue(result['ok'])

    def test_any_error_invalidates_trial(self):
        for key in ['connect_errors', 'read_errors', 'write_errors', 'status_errors', 'timeout_errors']:
            self.assertFalse(compare.parse_wrk(self.receipt(**{key: 1}))['ok'])

    def test_invalid_latency_does_not_invalidate_response_count(self):
        result = compare.parse_wrk(self.receipt(latency_p99_us=0))
        self.assertFalse(result['latency_percentiles_sane'])
        self.assertTrue(result['ok'])
        self.assertEqual(result['responses_per_second'], 800)

    def test_incomplete_or_ambiguous_receipt_rejected(self):
        for text in ['', self.receipt() * 2, self.receipt(requests=0), self.receipt(duration_us=0)]:
            with self.assertRaises(RuntimeError):
                compare.parse_wrk(text)

if __name__ == '__main__':
    unittest.main()
