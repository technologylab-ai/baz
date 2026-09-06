#!/usr/bin/env python3
"""Unmeasured cleanup-hardened reproducer; measured archive remains unchanged."""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import platform
import re
import signal
import socket
import statistics
import subprocess
import sys
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parent
LOCK = pathlib.Path('/tmp/zig-http-measurement.lock')
OWNED = []
CLEANUP_LOG = []
RESULT = {}


class CleanupError(RuntimeError):
    pass


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def write_json(path, value):
    pathlib.Path(path).write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def capture(command, timeout=10):
    try:
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, timeout=timeout, check=False)
        return {'command': command, 'returncode': result.returncode, 'output': result.stdout}
    except (OSError, subprocess.TimeoutExpired) as err:
        return {'command': command, 'error': str(err)}


def process_table():
    result = capture(['ps', '-axo', 'pid,ppid,pgid,command'])
    if result.get('returncode') != 0:
        raise RuntimeError('Cannot inspect process table: ' + str(result))
    rows = []
    for line in result['output'].splitlines()[1:]:
        fields = line.strip().split(None, 3)
        if len(fields) == 4:
            rows.append({'pid': int(fields[0]), 'ppid': int(fields[1]),
                         'pgid': int(fields[2]), 'command': fields[3]})
    return rows


def other_measurements(rows):
    result = []
    for row in rows:
        if row['pid'] == os.getpid():
            continue
        command = row['command']
        # SSH orchestration can mention commands running on a different host.
        if re.match(r'(?:\S*/)?ssh\s', command):
            continue
        if re.match(r'(?:\S*/)?wrk(?:\s|$)', command) or re.search(r'(?:^|/)zig (?:build|test)\b', command):
            result.append(row)
        elif re.match(r'(?:\S*/)?basic-(?:app|zap)(?:\s|$)', command):
            result.append(row)
        elif re.search(r'python\S*\s+\S*/(?:smoke|compare|integration(?:_[\w]+)?)\.py', command):
            result.append(row)
    return result


def acquire_lock(token, output):
    rows = process_table()
    conflicts = other_measurements(rows)
    write_json(output / 'preexisting-measurements.json', conflicts)
    if conflicts:
        raise RuntimeError('Other measurement/build processes exist; holding off')
    if token:
        owner = json.loads((LOCK / 'owner.json').read_text())
        if token not in (owner.get('token'), owner.get('ownership_token')):
            raise RuntimeError('Supplied lock token does not match existing reservation')
        write_json(output / 'lock-owner.json', owner)
        return None
    LOCK.mkdir()
    owner = {'agent': '/root/lifecycle_api_review', 'purpose': 'Basic ReleaseSafe Zap/App comparison',
             'host': socket.gethostname(), 'started_utc': now(), 'owner_pid': os.getpid(),
             'token': str(uuid.uuid4()), 'working_directory': str(ROOT)}
    if sys.platform.startswith('linux'):
        owner['start_ticks'] = pathlib.Path('/proc/self/stat').read_text().split()[21]
    write_json(LOCK / 'owner.json', owner)
    write_json(output / 'lock-owner.json', owner)
    return owner['token']


def group_exists(pgid):
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        # Permission is not evidence of disappearance, including exit races.
        return True


def stop_group(child, term_timeout=8.0, kill_timeout=5.0):
    # Once discharged, never signal the old numeric PGID again: it may be reused.
    if child not in OWNED:
        return child.returncode
    record = {'pgid': child.pid, 'started_utc': now(), 'signals': [],
              'term_timeout_seconds': term_timeout, 'kill_timeout_seconds': kill_timeout,
              'group_disappeared': False}

    def send(sig):
        try:
            os.killpg(child.pid, sig)
            record['signals'].append(sig.name)
        except ProcessLookupError:
            pass
        except PermissionError as err:
            record.setdefault('signal_errors', []).append(repr(err))

    def wait_gone(timeout):
        deadline = time.monotonic() + timeout
        while True:
            # poll() reaps the leader; its exit alone never discharges descendants.
            child.poll()
            if not group_exists(child.pid) and child.returncode is not None:
                return True
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            time.sleep(min(0.02, remaining))

    try:
        if group_exists(child.pid):
            send(signal.SIGTERM)
        if not wait_gone(term_timeout):
            send(signal.SIGKILL)
            if not wait_gone(kill_timeout):
                raise CleanupError('Original process group %d remains after TERM/KILL watchdogs' % child.pid)
        record['group_disappeared'] = True
        OWNED.remove(child)
        return child.returncode
    except BaseException as err:
        # Retain ownership on uncertainty; finalization must retain the lock too.
        record['error'] = repr(err)
        raise
    finally:
        record['leader_returncode'] = child.poll()
        record['finished_utc'] = now()
        CLEANUP_LOG.append(record)


def finalize_run(output, owned_token, workload_complete, result):
    errors = []
    result['complete'] = False
    result['workload_complete'] = workload_complete
    result['cleanup_complete'] = False
    # If cleanup fails or is interrupted, a prior success flag must not survive.
    try:
        write_json(output / 'summary.json', result)
    except BaseException as err:
        errors.append('Initial incomplete receipt: ' + repr(err))
    for child in list(OWNED):
        try:
            stop_group(child)
        except BaseException as err:
            errors.append('Cleanup PGID %d: %r' % (child.pid, err))
    remaining = []
    for child in OWNED:
        row = {'pgid': child.pid, 'leader_returncode': child.poll()}
        try:
            row['group_exists'] = group_exists(child.pid)
        except BaseException as err:
            row['inspection_error'] = repr(err)
            errors.append('Inspect PGID %d: %r' % (child.pid, err))
        remaining.append(row)
    result['owned_process_groups_remaining'] = remaining
    result['process_group_cleanup'] = list(CLEANUP_LOG)
    result['process_cleanup_complete'] = not remaining and not errors
    result['lock_release'] = 'external reservation untouched' if not owned_token else 'retained'
    if owned_token and not remaining and not errors:
        try:
            owner = json.loads((LOCK / 'owner.json').read_text())
            if owner.get('token') != owned_token:
                raise CleanupError('Lock ownership changed; refusing release')
            (LOCK / 'owner.json').unlink()
            LOCK.rmdir()
            result['lock_release'] = 'owned reservation released'
        except BaseException as err:
            errors.append('Release own lock: ' + repr(err))
    result['cleanup_errors'] = errors
    result['cleanup_complete'] = not remaining and not errors
    result['finished_utc'] = now()
    result['complete'] = bool(workload_complete and result['cleanup_complete'])
    write_json(output / 'summary.json', result)
    if errors or remaining:
        raise CleanupError('Cleanup incomplete; see summary.json: ' + repr(errors))


def run_group(command, log, timeout, check=True):
    with open(log, 'w') as output:
        child = subprocess.Popen(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT,
                                 start_new_session=True)
        OWNED.append(child)
        try:
            code = child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            stop_group(child)
            raise RuntimeError('Process watchdog expired: ' + repr(command))
        finally:
            stop_group(child)
    if check and code != 0:
        raise RuntimeError('Command failed (%d), see %s: %r' % (code, log, command))
    return code


def get_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def request(port, method='GET', path='/plaintext'):
    with socket.create_connection(('127.0.0.1', port), timeout=2) as sock:
        sock.settimeout(2)
        sock.sendall(('%s %s HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Length: 0\r\n\r\n' % (method, path)).encode())
        data = bytearray()
        while True:
            part = sock.recv(4096)
            if not part:
                break
            data.extend(part)
            if len(data) > 65536:
                raise RuntimeError('Oversized preflight response')
    head, body = bytes(data).split(b'\r\n\r\n', 1)
    lines = head.split(b'\r\n')
    status = int(lines[0].split()[1])
    headers = {}
    for line in lines[1:]:
        name, value = line.split(b':', 1)
        headers.setdefault(name.lower().decode(), []).append(value.strip().decode('latin1'))
    return {'status': status, 'headers': headers, 'body_hex': body.hex(),
            'body_bytes': len(body), 'raw_head': head.decode('latin1')}


def wait_ready(child, port, log):
    deadline = time.monotonic() + 10
    last = ''
    while time.monotonic() < deadline:
        if child.poll() is not None:
            raise RuntimeError('Server exited before preflight: ' + log.read_text())
        text = log.read_text()
        if 'optimize=Debug' in text or 'optimize=ReleaseFast' in text or 'optimize=ReleaseSmall' in text:
            raise RuntimeError('REFUSING ALL LOAD: server is not ReleaseSafe')
        if re.search(r'^READY .*\boptimize=ReleaseSafe\b', text, re.MULTILINE):
            try:
                record = request(port)
                if record['status'] != 200 or record['body_hex'] != b'Hello, World!'.hex():
                    raise RuntimeError('Bad plaintext preflight: ' + str(record))
                if record['headers'].get('content-type') != ['text/plain']:
                    raise RuntimeError('Bad plaintext content type: ' + str(record))
                if record['headers'].get('content-length') != ['13']:
                    raise RuntimeError('Bad plaintext content length: ' + str(record))
                return record
            except (OSError, ValueError) as err:
                last = str(err)
        time.sleep(0.02)
    raise RuntimeError('Server startup watchdog expired: ' + last)


def process_layout(child):
    rows = [r for r in process_table() if r['pgid'] == child.pid]
    for row in rows:
        pid = row['pid']
        if sys.platform == 'darwin':
            threads = capture(['ps', '-M', '-p', str(pid)])
            row['threads_raw'] = threads
            if threads.get('returncode') == 0:
                row['thread_count'] = max(0, len(threads['output'].strip().splitlines()) - 1)
        elif sys.platform.startswith('linux'):
            try:
                row['thread_ids'] = sorted(int(p.name) for p in pathlib.Path('/proc/%d/task' % pid).iterdir())
                row['thread_count'] = len(row['thread_ids'])
                row['status_raw'] = pathlib.Path('/proc/%d/status' % pid).read_text()
            except FileNotFoundError:
                row['exited_during_snapshot'] = True
    return rows


def parse_wrk(log):
    text = log.read_text()
    socket_errors = re.search(r'Socket errors: connect (\d+), read (\d+), write (\d+), timeout (\d+)', text)
    if socket_errors and any(int(n) for n in socket_errors.groups()):
        raise RuntimeError('Nonzero wrk socket errors: ' + str(log))
    statuses = re.search(r'Non-2xx or 3xx responses: (\d+)', text)
    if statuses and int(statuses.group(1)):
        raise RuntimeError('Non-success wrk responses: ' + str(log))
    requests = re.search(r'^\s*(\d+) requests in ([\d.]+)s,', text, re.MULTILINE)
    rps = re.search(r'^Requests/sec:\s*([\d.]+)', text, re.MULTILINE)
    if not requests or not rps or int(requests.group(1)) == 0:
        raise RuntimeError('Missing wrk result: ' + str(log))
    return {'requests': int(requests.group(1)), 'reported_seconds': float(requests.group(2)),
            'requests_per_second': float(rps.group(1)), 'socket_errors': [0, 0, 0, 0],
            'non_2xx_or_3xx': 0}


def manifest(framework):
    result = {}
    for path in sorted((framework / 'src').rglob('*.zig')):
        result['framework/' + path.relative_to(framework).as_posix()] = sha(path)
    support = framework / 'examples/support.zig'
    result['framework/examples/support.zig'] = sha(support)
    for name in ['build.zig', '.zig-version', 'PROTOCOL.md', 'runner.py']:
        result['fixture/' + name] = sha(ROOT / name)
    for path in sorted((ROOT / 'src').rglob('*.zig')):
        result['fixture/' + path.relative_to(ROOT).as_posix()] = sha(path)
    for path in sorted((ROOT / 'deps/zap').rglob('*')):
        if path.is_file():
            result[path.relative_to(ROOT).as_posix()] = sha(path)
    return result


def environment(args):
    data = {'recorded_utc': now(), 'platform': platform.platform(), 'uname': list(platform.uname()),
            'logical_cpus': os.cpu_count(), 'python': sys.version,
            'zig': capture([args.zig, 'version']), 'wrk': capture([args.wrk, '--version']),
            'wrk_path': str(pathlib.Path(args.wrk).resolve()), 'wrk_sha256': sha(args.wrk),
            'framework_root': str(args.framework_root), 'fixture_root': str(ROOT),
            'framework_git_head': capture(['git', '-C', str(args.framework_root), 'rev-parse', 'HEAD']),
            'framework_git_status': capture(['git', '-C', str(args.framework_root), 'status', '--short']),
            'build_mode': 'ReleaseSafe', 'tls': False,
            'zap_commit': 'f6099ecec496c7ec623c5913baa5b6b5da2e883d',
            'inherited_c_flags': ['-Os', '-Wno-return-type-c-linkage', '-fno-sanitize=undefined', '-DFIO_HTTP_EXACT_LOGGING'],
            'cpu_affinity': 'No CPU pinning applied by runner',
            'client_location': 'same-host IPv4 loopback', 'http_pipeline_depth': 1,
            'latency_claim': False}
    if sys.platform == 'darwin':
        data['cpu'] = capture(['sysctl', 'machdep.cpu.brand_string', 'hw.model', 'hw.physicalcpu', 'hw.logicalcpu', 'hw.memsize'])
        data['os_version'] = capture(['sw_vers'])
        data['power_policy'] = capture(['pmset', '-g', 'custom'])
        data['power_source'] = capture(['pmset', '-g', 'batt'])
    elif sys.platform.startswith('linux'):
        data['cpu'] = capture(['lscpu'])
        data['allowed_cpus'] = sorted(os.sched_getaffinity(0))
        for name in ['/etc/os-release', '/proc/sys/kernel/io_uring_disabled', '/sys/firmware/acpi/platform_profile']:
            path = pathlib.Path(name)
            data[name] = path.read_text() if path.exists() else None
        data['frequency_policy'] = {str(p): p.read_text() for p in pathlib.Path('/sys/devices/system/cpu').glob('cpu*/cpufreq/scaling_governor')}
    return data


def trial(args, contender, concurrency, threads, repetition, sequence):
    name = '%02d-c%d-t%d-pair%d-%s' % (sequence, concurrency, threads, repetition + 1, contender)
    directory = args.output / name
    directory.mkdir()
    port = get_port()
    command = [str(ROOT / 'zig-out/bin' / ('basic-' + contender)), '--port', str(port)]
    record = {'name': name, 'sequence': sequence, 'contender': contender,
              'connections': concurrency, 'client_threads': threads, 'pair': repetition + 1,
              'server_command': command, 'started_utc': now(), 'build_mode': 'ReleaseSafe'}
    log = directory / 'server.log'
    with open(log, 'w') as output:
        server = subprocess.Popen(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT,
                                  start_new_session=True)
        OWNED.append(server)
        try:
            record['plaintext_preflight'] = wait_ready(server, port, log)
            record['not_found_preflight'] = request(port, path='/missing')
            record['method_preflight'] = request(port, method='POST')
            if record['not_found_preflight']['status'] != 404 or record['method_preflight']['status'] != 405:
                raise RuntimeError('Negative route preflight mismatch')
            record['process_layout'] = process_layout(server)
            url = 'http://127.0.0.1:%d/plaintext' % port
            common = [args.wrk, '-c', str(concurrency), '-t', str(threads)]
            record['warmup_command'] = common + ['-d', '1s', url]
            run_group(record['warmup_command'], directory / 'warmup-wrk.txt', 12)
            record['warmup'] = parse_wrk(directory / 'warmup-wrk.txt')
            record['measurement_command'] = common + ['-d', '3s', url]
            run_group(record['measurement_command'], directory / 'measurement-wrk.txt', 14)
            record['measurement'] = parse_wrk(directory / 'measurement-wrk.txt')
            if server.poll() is not None:
                raise RuntimeError('Server terminated during workload')
            record['postflight'] = request(port)
            if record['postflight']['status'] != 200 or record['postflight']['body_hex'] != b'Hello, World!'.hex():
                raise RuntimeError('Postflight mismatch')
        finally:
            record['server_exit_code'] = stop_group(server)
            record['finished_utc'] = now()
            write_json(directory / 'trial.json', record)
    if record['server_exit_code'] != 0:
        raise RuntimeError('Server did not shut down cleanly: ' + name)
    return record


def fixture_preflight(args, contender):
    directory = args.output / ('preflight-' + contender)
    directory.mkdir()
    port = get_port()
    command = [str(ROOT / 'zig-out/bin' / ('basic-' + contender)), '--port', str(port)]
    record = {'contender': contender, 'command': command, 'build_mode': 'ReleaseSafe'}
    log = directory / 'server.log'
    with open(log, 'w') as output:
        server = subprocess.Popen(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT,
                                  start_new_session=True)
        OWNED.append(server)
        try:
            record['plaintext'] = wait_ready(server, port, log)
            record['not_found'] = request(port, path='/missing')
            record['method'] = request(port, method='POST')
            if record['not_found']['status'] != 404 or record['method']['status'] != 405:
                raise RuntimeError('Negative route preflight mismatch')
            record['process_layout'] = process_layout(server)
        finally:
            record['server_exit_code'] = stop_group(server)
            write_json(directory / 'preflight.json', record)
    if record['server_exit_code'] != 0:
        raise RuntimeError('Preflight server did not shut down cleanly: ' + contender)
    return record


def timeout_handler(signum, frame):
    raise RuntimeError('Runner interrupted or overall 1000-second watchdog expired: %d' % signum)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--framework-root', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--wrk', required=True)
    parser.add_argument('--zig', default='zig')
    parser.add_argument('--lock-token')
    parser.add_argument('--build-only', action='store_true')
    args = parser.parse_args()
    args.framework_root = args.framework_root.resolve()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGALRM):
        signal.signal(sig, timeout_handler)
    signal.alarm(1000)
    owned_token = None
    workload_complete = False
    RESULT.update({'started_utc': now(), 'complete': False, 'trials': [],
                   'interpretation': 'Basic indicative same-host loopback throughput only; no latency/SLO/capacity claims'})
    try:
        owned_token = acquire_lock(args.lock_token, args.output)
        env = environment(args)
        write_json(args.output / 'environment.json', env)
        if env['zig'].get('output', '').strip() != '0.16.0':
            raise RuntimeError('Exact Zig 0.16.0 required')
        before = manifest(args.framework_root)
        write_json(args.output / 'source-sha256.json', before)
        command = [args.zig, 'build', 'verify', '-Doptimize=ReleaseSafe',
                   '-Dframework-root=' + str(args.framework_root), '--summary', 'all']
        RESULT['build_command'] = command
        print('BUILD ReleaseSafe verify', flush=True)
        run_group(command, args.output / 'build-verify.log', 600)
        RESULT['binary_sha256'] = {c: sha(ROOT / 'zig-out/bin' / ('basic-' + c)) for c in ('app', 'zap')}
        if not args.build_only:
            # No warmup or measured load until BOTH fixtures pass the mode and
            # exact-wire checks. Trials repeat these checks after each restart.
            RESULT['fixture_preflights'] = [fixture_preflight(args, c) for c in ('app', 'zap')]
            sequence = 0
            for case, (connections, threads) in enumerate([(1, 1), (32, 2)]):
                for pair in range(3):
                    order = ('app', 'zap') if (case * 3 + pair) % 2 == 0 else ('zap', 'app')
                    for contender in order:
                        sequence += 1
                        print('TRIAL %02d c%d/t%d %s' % (sequence, connections, threads, contender), flush=True)
                        record = trial(args, contender, connections, threads, pair, sequence)
                        RESULT['trials'].append(record)
                        write_json(args.output / 'summary.json', RESULT)
            RESULT['medians'] = []
            for connections in (1, 32):
                rates = {c: [t['measurement']['requests_per_second'] for t in RESULT['trials']
                             if t['connections'] == connections and t['contender'] == c] for c in ('app', 'zap')}
                medians = {c: statistics.median(rates[c]) for c in rates}
                RESULT['medians'].append({'connections': connections, 'rates': rates,
                                          'median_rps': medians,
                                          'app_over_zap_ratio_of_medians': medians['app'] / medians['zap']})
        if manifest(args.framework_root) != before:
            raise RuntimeError('Source changed during comparison')
        workload_complete = True
    except BaseException as err:
        RESULT['error'] = repr(err)
        print('FAILED: ' + repr(err), file=sys.stderr, flush=True)
        raise
    finally:
        signal.alarm(0)
        # Cleanup has its own finite per-group deadlines. A second interrupt
        # must not skip reconciliation or release an uncertain reservation.
        handlers = {sig: signal.signal(sig, signal.SIG_IGN) for sig in (signal.SIGINT, signal.SIGTERM)}
        try:
            finalize_run(args.output, owned_token, workload_complete, RESULT)
        finally:
            for sig, handler in handlers.items():
                signal.signal(sig, handler)
    print(json.dumps({'complete': RESULT['complete'], 'medians': RESULT.get('medians', [])}), flush=True)


if __name__ == '__main__':
    main()
