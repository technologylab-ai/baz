#!/usr/bin/env python3
"""Bounded synthetic cleanup checks. Never builds Zig or starts HTTP/wrk."""
import importlib.util
import json
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('hardened_runner', pathlib.Path(__file__).with_name('runner.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class FakeChild:
    pid = 99999999
    returncode = 0

    def poll(self):
        return self.returncode


class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='zig-http-synthetic-cleanup-')
        self.directory = pathlib.Path(self.temporary.name)
        self.children = []
        self.old_lock = runner.LOCK
        runner.LOCK = self.directory / 'lock'
        runner.OWNED.clear()
        runner.CLEANUP_LOG.clear()

    def tearDown(self):
        # Tests retain every real child identity even when testing registry faults.
        for child in self.children:
            if child not in runner.OWNED:
                if child.poll() is not None and not runner.group_exists(child.pid):
                    continue
                runner.OWNED.append(child)
            runner.stop_group(child, term_timeout=0.1, kill_timeout=2)
        runner.OWNED.clear()
        runner.LOCK = self.old_lock
        self.temporary.cleanup()

    def spawn(self, source, owned=True):
        child = subprocess.Popen([sys.executable, '-c', source], stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, start_new_session=True)
        self.children.append(child)
        if owned:
            runner.OWNED.append(child)
        return child

    def wait_file(self, path):
        deadline = time.monotonic() + 3
        while not path.exists():
            if time.monotonic() >= deadline:
                self.fail('Synthetic readiness watchdog expired')
            time.sleep(0.01)

    def live_source(self, ready, ignore_term=False):
        setup = 'signal.signal(signal.SIGTERM, signal.SIG_IGN);' if ignore_term else ''
        return 'import pathlib,signal,time;' + setup + 'pathlib.Path(%r).write_text("ready");time.sleep(60)' % str(ready)

    def own_lock(self, token='synthetic-owner'):
        runner.LOCK.mkdir()
        (runner.LOCK / 'owner.json').write_text(json.dumps({'token': token}))
        return token

    def test_graceful_group_reaped_and_idempotent(self):
        ready = self.directory / 'ready'
        child = self.spawn(self.live_source(ready))
        self.wait_file(ready)
        self.assertEqual(runner.stop_group(child, 0.5, 1), -signal.SIGTERM)
        self.assertNotIn(child, runner.OWNED)
        self.assertFalse(runner.group_exists(child.pid))
        self.assertTrue(runner.CLEANUP_LOG[-1]['group_disappeared'])
        with mock.patch.object(runner.os, 'killpg', side_effect=AssertionError('resignaled discharged PGID')):
            runner.stop_group(child, 0.1, 0.1)

    def test_term_ignoring_leader_requires_kill(self):
        ready = self.directory / 'ready'
        child = self.spawn(self.live_source(ready, ignore_term=True))
        self.wait_file(ready)
        self.assertEqual(runner.stop_group(child, 0.05, 1), -signal.SIGKILL)
        self.assertEqual(runner.CLEANUP_LOG[-1]['signals'], ['SIGTERM', 'SIGKILL'])
        self.assertFalse(runner.group_exists(child.pid))

    def test_exited_leader_does_not_discharge_live_descendant(self):
        ready = self.directory / 'descendant-ready'
        descendant = self.live_source(ready, ignore_term=True)
        leader = 'import subprocess,sys;subprocess.Popen([sys.executable,"-c",%r])' % descendant
        child = self.spawn(leader)
        self.wait_file(ready)
        self.assertEqual(child.wait(timeout=2), 0)
        self.assertTrue(runner.group_exists(child.pid))
        self.assertEqual(runner.stop_group(child, 0.05, 2), 0)
        self.assertFalse(runner.group_exists(child.pid))
        self.assertIn('SIGKILL', runner.CLEANUP_LOG[-1]['signals'])

    def test_unrelated_group_is_not_signaled(self):
        ready = self.directory / 'unrelated-ready'
        unrelated = self.spawn(self.live_source(ready), owned=False)
        self.wait_file(ready)
        own_ready = self.directory / 'own-ready'
        child = self.spawn(self.live_source(own_ready))
        self.wait_file(own_ready)
        runner.stop_group(child, 0.5, 1)
        self.assertIsNone(unrelated.poll())
        self.assertTrue(runner.group_exists(unrelated.pid))

    def test_group_watchdog_retains_uncertain_ownership(self):
        child = FakeChild()
        runner.OWNED.append(child)
        started = time.monotonic()
        with mock.patch.object(runner, 'group_exists', return_value=True), mock.patch.object(runner.os, 'killpg'):
            with self.assertRaises(runner.CleanupError):
                runner.stop_group(child, term_timeout=0.02, kill_timeout=0.02)
        self.assertLess(time.monotonic() - started, 1)
        self.assertIn(child, runner.OWNED)
        self.assertFalse(runner.CLEANUP_LOG[-1]['group_disappeared'])

    def test_cleanup_failure_clears_success_and_retains_lock(self):
        token = self.own_lock()
        child = FakeChild()
        runner.OWNED.append(child)
        result = {'complete': True}
        with mock.patch.object(runner, 'stop_group', side_effect=runner.CleanupError('synthetic remaining group')):
            with mock.patch.object(runner, 'group_exists', return_value=True):
                with self.assertRaises(runner.CleanupError):
                    runner.finalize_run(self.directory, token, True, result)
        record = json.loads((self.directory / 'summary.json').read_text())
        self.assertFalse(record['complete'])
        self.assertFalse(record['cleanup_complete'])
        self.assertEqual(record['lock_release'], 'retained')
        self.assertTrue(runner.LOCK.exists())
        self.assertEqual(json.loads((runner.LOCK / 'owner.json').read_text())['token'], token)
        self.assertEqual(record['owned_process_groups_remaining'][0]['pgid'], child.pid)

    def test_foreign_lock_blocks_success_without_modifying_owner(self):
        self.own_lock('foreign-owner')
        result = {}
        with self.assertRaises(runner.CleanupError):
            runner.finalize_run(self.directory, 'my-token', True, result)
        self.assertFalse(result['complete'])
        self.assertTrue(result['process_cleanup_complete'])
        self.assertFalse(result['cleanup_complete'])
        self.assertEqual(json.loads((runner.LOCK / 'owner.json').read_text())['token'], 'foreign-owner')

    def test_success_is_published_only_after_cleanup_and_lock_release(self):
        token = self.own_lock()
        result = {}
        snapshots = []
        original = runner.write_json

        def observe(path, value):
            snapshots.append((value['complete'], runner.LOCK.exists(), bool(runner.OWNED)))
            original(path, value)

        with mock.patch.object(runner, 'write_json', side_effect=observe):
            runner.finalize_run(self.directory, token, True, result)
        self.assertEqual(snapshots, [(False, True, False), (True, False, False)])
        self.assertTrue(result['complete'])
        self.assertTrue(result['cleanup_complete'])

    def test_failed_workload_stays_failed_after_clean_shutdown(self):
        token = self.own_lock()
        result = {'error': 'synthetic workload failure'}
        runner.finalize_run(self.directory, token, False, result)
        self.assertFalse(result['complete'])
        self.assertTrue(result['cleanup_complete'])
        self.assertEqual(result['error'], 'synthetic workload failure')
        self.assertFalse(runner.LOCK.exists())

    def test_external_reservation_is_never_released(self):
        self.own_lock('external-owner')
        result = {}
        runner.finalize_run(self.directory, None, True, result)
        self.assertTrue(result['complete'])
        self.assertTrue(runner.LOCK.exists())
        self.assertEqual(result['lock_release'], 'external reservation untouched')


def expired(signum, frame):
    raise RuntimeError('Synthetic test suite exceeded its 30-second watchdog')


if __name__ == '__main__':
    signal.signal(signal.SIGALRM, expired)
    signal.alarm(30)
    try:
        unittest.main(verbosity=2)
    finally:
        signal.alarm(0)
