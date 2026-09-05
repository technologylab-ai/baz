"""Check externally consumed wrk receipt semantics, including failed loads."""
import importlib.util
import json
from collections import Counter
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

    def test_required_power_profile_cannot_silently_change_or_disappear(self):
        compare.check_power_state({'profile': 'performance'}, 'performance')
        compare.check_power_state({'profile': None}, None)
        for actual in ('balanced', 'power-saver', None):
            with self.assertRaises(RuntimeError):
                compare.check_power_state({'profile': actual}, 'performance')

    def test_incomplete_or_ambiguous_receipt_rejected(self):
        for text in ['', self.receipt() * 2, self.receipt(requests=0), self.receipt(duration_us=0)]:
            with self.assertRaises(RuntimeError):
                compare.parse_wrk(text)

    def test_abba_keeps_equal_workload_adjacent_and_balances_samples(self):
        servers = [{'name': 'baseline'}, {'name': 'candidate'}]
        jobs = compare.trial_jobs(servers, [8, 128], [16, 128], 2, 20260905, 'abba')
        self.assertEqual(len(jobs), 32)
        identities = [(rep, c, pipeline, s['name']) for rep, c, pipeline, s in jobs]
        self.assertEqual(len(set(identities)), len(identities))
        self.assertEqual(set(Counter((c, p, s['name']) for _, c, p, s in jobs).values()), {4})
        for start in range(0, len(jobs), 4):
            block = jobs[start:start + 4]
            self.assertEqual([s['name'] for _, _, _, s in block],
                             ['baseline', 'candidate', 'candidate', 'baseline'])
            self.assertEqual(len({(c, p, rep // 2) for rep, c, p, _ in block}), 1)
        self.assertEqual(jobs, compare.trial_jobs(servers, [8, 128], [16, 128], 2, 20260905, 'abba'))

    def test_abba_rejects_ambiguous_or_non_pair_comparisons(self):
        for servers in ([], [{'name': 'a'}], [{'name': 'a'}, {'name': 'a'}],
                        [{'name': 'a'}, {'name': 'b'}, {'name': 'c'}]):
            with self.assertRaises(RuntimeError):
                compare.trial_jobs(servers, [128], [16], 1, 1, 'abba')

    def test_default_shuffle_retains_each_requested_sample_once(self):
        servers = [{'name': 'a'}, {'name': 'b'}, {'name': 'c'}]
        jobs = compare.trial_jobs(servers, [8, 128], [1, 16], 3, 9, 'shuffled')
        self.assertEqual({(rep, c, p, s['name']) for rep, c, p, s in jobs},
                         {(rep, c, p, s['name']) for rep in range(3)
                          for c in [8, 128] for p in [1, 16] for s in servers})
        self.assertEqual(len(jobs), 36)

if __name__ == '__main__':
    unittest.main()
