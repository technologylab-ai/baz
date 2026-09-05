#!/usr/bin/env python3
"""Finite Linux loopback comparison using pinned wrk and explicit server commands.

Run only after builds finish. Input JSON provides owned commands/directories;
never execute an untrusted configuration. CPU affinity is applied to both roles.
Timed runs parse HTTP with wrk; separate preflight validates exact bodies/headers.
No official TFB reproduction, open-loop latency, or production capacity claim.
"""
import argparse
import contextlib
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import random
import resource
import signal
import socket
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('wire', ROOT / 'tests/integration.py')
WIRE = importlib.util.module_from_spec(spec)
spec.loader.exec_module(WIRE)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def capture(command):
    return subprocess.check_output(command, text=True, timeout=10).strip()


def ticks():
    result = {}
    for path in Path('/proc').glob('[0-9]*/task/[0-9]*/stat'):
        with contextlib.suppress(OSError, ValueError, IndexError):
            fields = path.read_text().rsplit(')', 1)[1].split()
            result[int(path.parts[-2])] = dict(pid=int(path.parts[-4]), ppid=int(fields[1]),
                start=int(fields[19]), ticks=int(fields[11]) + int(fields[12]),
                processor=int(fields[36]))
    return result


def descendants(samples, root):
    pids = {root}
    while True:
        expanded = pids | {v['pid'] for v in samples.values() if v['ppid'] in pids}
        if expanded == pids:
            return {tid: v for tid, v in samples.items() if v['pid'] in pids}
        pids = expanded


def cpu_delta(before, after, elapsed):
    hz = os.sysconf('SC_CLK_TCK')
    return [dict(tid=tid, pid=v['pid'], last_cpu=v['processor'],
                 cpu_seconds=(v['ticks'] - before[tid]['ticks']) / hz,
                 cpu_percent=100 * (v['ticks'] - before[tid]['ticks']) / hz / elapsed)
            for tid, v in after.items() if tid in before and v['start'] == before[tid]['start']]


def system_ticks():
    result = {}
    for line in Path('/proc/stat').read_text().splitlines():
        fields = line.split()
        if fields[0].startswith('cpu'):
            # guest times already included in user/nice; count only first eight.
            result[fields[0]] = list(map(int, fields[1:9]))
    return result


def system_delta(before, after):
    output = {}
    for cpu, values in after.items():
        delta = [a - b for a, b in zip(values, before[cpu])]
        total = sum(delta)
        output[cpu] = dict(busy_percent=100 * (total - delta[3] - delta[4]) / total if total else 0,
                          iowait_percent=100 * delta[4] / total if total else 0)
    return output


def preflight(port, expected):
    dates = []
    header_sample = None
    for phase in range(2):
        with socket.create_connection(('127.0.0.1', port), 2) as sock:
            sock.settimeout(3)
            reader = WIRE.ResponseReader(sock)
            sock.sendall(WIRE.REQUEST * 16)
            for _ in range(16):
                status, headers, body = reader.response()
                require(status == 200 and body == expected, 'wrong plaintext status/body')
                require(headers.get(b'content-type', b'').lower().startswith(b'text/plain'), 'content type')
                require(int(headers[b'content-length']) == len(expected), 'content length')
                require(bool(headers.get(b'server')), 'Server header absent')
                date = parsedate_to_datetime(headers[b'date'].decode())
                require(date.tzinfo is not None and abs(time.time() - date.timestamp()) < 5, 'stale Date')
                dates.append(headers[b'date'].decode())
                header_sample = {k.decode(): v.decode() for k, v in headers.items()}
        if phase == 0:
            time.sleep(1.2)
    require(dates[0] != dates[-1], 'Date did not advance')
    return dict(validated_responses=32, exact_body=expected.decode(), headers=header_sample,
                first_date=dates[0], last_date=dates[-1])


def parse_wrk(stdout):
    records = [json.loads(line[7:]) for line in stdout.splitlines() if line.startswith('RESULT ')]
    require(len(records) == 1, 'missing or ambiguous wrk receipt')
    result = records[0]
    require(result['duration_us'] > 0 and result['requests'] > 0, 'empty wrk result')
    result['latency_percentiles_sane'] = (0 < result['latency_p50_us'] <= result['latency_p99_us'] <= result['latency_max_us'])
    result['latency_model'] = 'wrk corrected histogram of completed pipeline batches; not per-response or open-loop SLO latency'
    result['responses_per_second'] = result['requests'] * 1e6 / result['duration_us']
    result['ok'] = all(result[key] == 0 for key in (
        'connect_errors', 'read_errors', 'write_errors', 'status_errors', 'timeout_errors'))
    return result


def stop(process, server):
    # Native server descendants share this owned process group. Docker uses its
    # explicit named-container stop command instead; the CLI group is still owned.
    try:
        if server.get('stop'):
            subprocess.run(server['stop'], timeout=15, capture_output=True, check=True)
    finally:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=3)
            raise RuntimeError('server required forced kill')
        finally:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
        # Forked workers may outlive their already-reaped parent briefly while
        # the kernel processes the group signal. Confirm the owned listener ends.
        deadline = time.monotonic() + 3
        while True:
            try:
                with socket.create_connection(('127.0.0.1', server.get('port', 8080)), .1):
                    pass
            except ConnectionRefusedError:
                break
            except TimeoutError:
                pass
            require(time.monotonic() < deadline, 'owned listener remained after stop')
            time.sleep(.02)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('configuration', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--seconds', type=int, default=5)
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--connections', type=int, nargs='+', default=[8, 32, 128])
    parser.add_argument('--threads', type=int, default=4)
    parser.add_argument('--seed', type=int, default=20260905)
    args = parser.parse_args()
    require(sys.platform == 'linux', 'this controlled-affinity harness requires Linux')
    require(1 <= args.seconds <= 30 and 1 <= args.repeats <= 5, 'finite trial bounds')
    require(1 <= args.threads <= 8 and all(args.threads <= c <= 128 and c % args.threads == 0
                                          for c in args.connections), 'connection/thread bounds')
    config = json.loads(args.configuration.read_text())
    require(1 <= len(config['servers']) <= 4, 'bounded contender count')
    require(not set(config['server_cpus']) & set(config['client_cpus']), 'overlapping CPU budgets')
    require(set(config['server_cpus'] + config['client_cpus']) <= os.sched_getaffinity(0), 'unavailable CPU')
    args.output.mkdir(parents=True, exist_ok=False)
    receipt = dict(schema_version=1, tool='zig-http-wrk-comparison', ok=False,
                   started_utc=datetime.now(timezone.utc).isoformat(), configuration=config,
                   harness_sha256=digest(__file__), lua_sha256=digest(ROOT / 'benchmarks/pipeline.lua'),
                   configuration_sha256=digest(args.configuration), wrk_sha256=digest(config['wrk']),
                   latency_model='wrk corrected batch histogram; batch depth1 or16; closed loop',
                   validation='32 exact-body/header responses per trial before timed load; wrk framing/status during load',
                   duration_seconds=args.seconds, repeats=args.repeats, threads=args.threads,
                   seed=args.seed, connections=args.connections, pipeline_depths=[1, 16],
                   environment=dict(uname=capture(['uname', '-a']), os_release=Path('/etc/os-release').read_text(),
                       cpuinfo=Path('/proc/cpuinfo').read_text(), meminfo=Path('/proc/meminfo').read_text(),
                       io_uring_disabled=Path('/proc/sys/kernel/io_uring_disabled').read_text().strip(),
                       lscpu=capture(['lscpu']), python=sys.version,
                       frequency_policy={str(p):p.read_text().strip() for p in Path('/sys/devices/system/cpu').glob('cpu[0-9]*/cpufreq/scaling_governor')},
                       boost_policy={str(p):p.read_text().strip() for p in Path('/sys/devices/system/cpu').glob('intel_pstate/no_turbo')}), trials=[])
    jobs = [(rep, c, pipeline, s) for rep in range(args.repeats)
            for c in args.connections for pipeline in (1, 16) for s in config['servers']]
    random.Random(args.seed).shuffle(jobs)
    def interrupted(number, frame):
        raise TimeoutError(f'orchestrator signal {number}; cancel owned processes')
    for number in (signal.SIGALRM, signal.SIGTERM, signal.SIGINT):
        signal.signal(number, interrupted)
    signal.alarm(min(3600, len(jobs) * (args.seconds + 25) + 30))
    try:
        for index, (rep, connections, pipeline, server) in enumerate(jobs):
            trial = dict(index=index, repeat=rep, server=server['name'], connections=connections, pipeline=pipeline)
            receipt['trials'].append(trial)
            prefix = f"{index:03d}-{server['name']}-c{connections}-p{pipeline}"
            logpath = args.output / (prefix + '-server.log')
            command = ['taskset', '-c', ','.join(map(str, config['server_cpus']))] + server['command']
            trial['server_command'] = command
            process = None
            try:
                try:
                    with socket.create_connection(('127.0.0.1', server.get('port', 8080)), .2):
                        raise RuntimeError('benchmark port already has a listener; refusing to reuse it')
                except ConnectionRefusedError:
                    pass
                with logpath.open('w') as log:
                    process = subprocess.Popen(command, cwd=server['cwd'], stdout=log, stderr=log,
                                               stdin=subprocess.DEVNULL, start_new_session=True)
                    deadline = time.monotonic() + 15
                    while True:
                        require(process.poll() is None, 'server exited during startup; see ' + str(logpath))
                        try:
                            with socket.create_connection(('127.0.0.1', server.get('port', 8080)), .1):
                                break
                        except OSError:
                            require(time.monotonic() < deadline, 'startup watchdog')
                            time.sleep(.05)
                    if server.get('implementation', server['name']) == 'zig-http':
                        while 'READY ' not in logpath.read_text():
                            require(process.poll() is None and time.monotonic() < deadline, 'READY watchdog')
                            time.sleep(.02)
                        require('optimize=ReleaseSafe' in logpath.read_text(), 'benchmark requires ReleaseSafe')
                    trial['preflight'] = preflight(server.get('port', 8080), server['body'].encode())
                    root_pid = int(capture(server['pid_command'])) if server.get('pid_command') else process.pid
                    trial['root_pid'] = root_pid
                    base = ['taskset', '-c', ','.join(map(str, config['client_cpus'])), config['wrk'],
                            '-t', str(args.threads), '-c', str(connections), '--timeout', '2s',
                            '-s', str(ROOT / 'benchmarks/pipeline.lua'),
                            f"http://127.0.0.1:{server.get('port', 8080)}/plaintext", '--', str(pipeline)]
                    warm = subprocess.run(base[:4] + ['-d', '1s'] + base[4:], capture_output=True, text=True, timeout=6)
                    (args.output / (prefix + '-warmup.log')).write_text(warm.stdout + warm.stderr)
                    trial['warmup'] = parse_wrk(warm.stdout)
                    require(warm.returncode == 0 and trial['warmup']['ok'], 'warmup errors')
                    command = base[:4] + ['-d', f'{args.seconds}s'] + base[4:]
                    trial['client_command'] = command
                    before = descendants(ticks(), root_pid)
                    sys_before = system_ticks()
                    child_before = resource.getrusage(resource.RUSAGE_CHILDREN)
                    started = time.monotonic()
                    measured = subprocess.run(command, capture_output=True, text=True, timeout=args.seconds + 8)
                    elapsed = time.monotonic() - started
                    child_after = resource.getrusage(resource.RUSAGE_CHILDREN)
                    after = descendants(ticks(), root_pid)
                    trial['stable_thread_set'] = before.keys() == after.keys()
                    trial.update(result=parse_wrk(measured.stdout), elapsed_seconds=elapsed,
                                 server_threads=cpu_delta(before, after, elapsed),
                                 system_cpu=system_delta(sys_before, system_ticks()),
                                 client_cpu_seconds=(child_after.ru_utime + child_after.ru_stime -
                                                     child_before.ru_utime - child_before.ru_stime))
                    trial['server_cpu_percent'] = sum(v['cpu_percent'] for v in trial['server_threads'])
                    trial['resident_kib_by_pid'] = {}
                    for pid in {v['pid'] for v in after.values()}:
                        with contextlib.suppress(OSError):
                            for line in Path(f'/proc/{pid}/status').read_text().splitlines():
                                if line.startswith('VmRSS:'):
                                    trial['resident_kib_by_pid'][str(pid)] = int(line.split()[1])
                    trial['client_cpu_percent'] = trial['client_cpu_seconds'] / elapsed * 100
                    trial['client_exit'] = measured.returncode
                    (args.output / (prefix + '-wrk.log')).write_text(measured.stdout + measured.stderr)
                    require(measured.returncode == 0 and trial['result']['ok'], 'measured client errors')
                    require(process.poll() is None, 'server exited during load')
            finally:
                if process is not None:
                    pending_error = sys.exc_info()[1]
                    try:
                        stop(process, server)
                    except Exception as cleanup_error:
                        trial['cleanup_error'] = str(cleanup_error)
                        if pending_error is None:
                            raise
                    trial['server_exit'] = process.returncode
                    trial['server_log'] = logpath.read_text()
                    if server.get('implementation', server['name']) == 'zig-http' and pending_error is None:
                        stats = [json.loads(line[6:]) for line in trial['server_log'].splitlines() if line.startswith('STATS ')]
                        require(process.returncode == 0 and len(stats) == 1, 'Zig shutdown failed')
                        trial['stats'] = stats[0]
                        if server.get('expected_execution'):
                            require(stats[0]['execution'] == server['expected_execution'], 'wrong execution mode')
                        if stats[0].get('execution') == 'inline_event_loop':
                            require(stats[0]['workers'] == stats[0]['worker_dispatches'] == 0, 'inline worker activity')
                        require(stats[0]['allocation_calls_after_start'] == 0, 'late framework allocation')
                        require(stats[0]['live_connections'] == stats[0]['live_operations'] == 0, 'live shutdown ownership')
                        require(stats[0]['peak_connections'] <= 128, 'connection limit exceeded')
            (args.output / 'results.json').write_text(json.dumps(receipt, indent=2) + '\n')
            print(json.dumps(dict(index=index, total=len(jobs), server=server['name'], c=connections, p=pipeline,
                                  rps=round(trial['result']['responses_per_second']),
                                  server_cpu=round(trial['server_cpu_percent']),
                                  client_cpu=round(trial['client_cpu_percent']))), flush=True)
        receipt['ok'] = True
    except Exception as error:
        receipt['error'] = f'{type(error).__name__}: {error}'
        raise
    finally:
        signal.alarm(0)
        receipt['finished_utc'] = datetime.now(timezone.utc).isoformat()
        (args.output / 'results.json').write_text(json.dumps(receipt, indent=2) + '\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
