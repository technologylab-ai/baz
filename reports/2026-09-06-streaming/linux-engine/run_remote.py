import ctypes
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import sys
import tarfile
import time
import traceback
import uuid

ROOT = Path(__file__).resolve().parent
assert ROOT.parent == Path('/tmp') and ROOT.name.startswith('baz-stream-engine.')
OUT = ROOT / 'evidence'
OUT.mkdir(exist_ok=True)
SOURCE = ROOT / 'source'
LOCK = Path('/tmp/zig-http-measurement.lock')
TOKEN = str(uuid.uuid4())
owned = False
report = {'schema_version': 1, 'ok': False, 'steps': [], 'started_utc': datetime.datetime.now(datetime.timezone.utc).isoformat()}

def save(name, value):
    (OUT / name).write_text(json.dumps(value, indent=2) + '\n')

def processes():
    result = {}
    for entry in Path('/proc').iterdir():
        if not entry.name.isdigit():
            continue
        try:
            stat = (entry / 'stat').read_text().rsplit(')', 1)[1].split()
            argv = (entry / 'cmdline').read_bytes().split(b'\0')
            result[int(entry.name)] = {'pid': int(entry.name), 'ppid': int(stat[1]), 'pgid': int(stat[2]), 'state': stat[0], 'start_ticks': int(stat[19]), 'argv': [part.decode(errors='replace') for part in argv if part]}
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            pass
    return result

def descendants():
    table = processes()
    owners = {os.getpid()}
    changed = True
    while changed:
        changed = False
        for pid, item in table.items():
            if pid not in owners and item['ppid'] in owners:
                owners.add(pid)
                changed = True
    return [table[pid] for pid in owners if pid != os.getpid()]

def cleanup_children():
    before = descendants()
    for round_number in range(30):
        children = descendants()
        if not children:
            break
        for child in children:
            try:
                os.kill(child['pid'], signal.SIGTERM if round_number < 10 else signal.SIGKILL)
            except ProcessLookupError:
                pass
        while True:
            try:
                pid, _ = os.waitpid(-1, os.WNOHANG)
                if pid == 0:
                    break
            except ChildProcessError:
                break
        time.sleep(0.1)
    after = descendants()
    return {'before': before, 'after': after, 'ok': not after}

def interruption(signum, frame):
    raise TimeoutError('outer watchdog or orchestration signal: %s' % signum)

def gate(name, command, seconds):
    print('START ' + name, flush=True)
    started = time.monotonic()
    item = {'name': name, 'command': command, 'timeout_seconds': seconds}
    report['steps'].append(item)
    with (OUT / (name + '.log')).open('wb') as log:
        child = subprocess.Popen(command, cwd=SOURCE, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                 start_new_session=True, env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})
        try:
            item['exit_code'] = child.wait(timeout=seconds)
        except BaseException:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait(timeout=5)
            raise
        finally:
            item['seconds'] = round(time.monotonic() - started, 3)
            item['cleanup'] = cleanup_children()
            save('summary.json', report)
    print('END %s exit=%s seconds=%s' % (name, item['exit_code'], item['seconds']), flush=True)
    if item['exit_code'] != 0 or not item['cleanup']['ok']:
        raise RuntimeError('gate failed: ' + name)

try:
    # Orphaned test servers remain our children, even if they create new sessions.
    if ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) != 0:
        raise OSError('PR_SET_CHILD_SUBREAPER failed')
    table = processes()
    parents = {os.getpid()}
    current = os.getpid()
    while current in table and table[current]['ppid'] not in parents:
        current = table[current]['ppid']
        parents.add(current)
    suspect = []
    for pid, item in table.items():
        argv = item['argv']
        if pid in parents or not argv or item['state'] == 'Z':
            continue
        base = Path(argv[0]).name
        scripts = [Path(arg).name for arg in argv[1:] if not arg.startswith('-')]
        if base in ('zig', 'wrk', 'wrk2', 'hey', 'bounded-http', 'zig-http', 'zap-bench') or \
                ('.zig-cache/' in argv[0] and base in ('test', 'build')) or \
                (base.startswith('python') and any(name.endswith('integration.py') or name in ('smoke.py', 'benchmark.py', 'compare.py') for name in scripts)):
            suspect.append(item)
    save('preflight.json', {'suspected_measurement_processes': suspect, 'lock_existed': LOCK.exists()})
    if suspect:
        raise RuntimeError('measurement processes already exist: %r' % suspect)
    try:
        LOCK.mkdir()
    except FileExistsError:
        owner_path = LOCK / 'owner.json'
        save('busy.json', {'owner': owner_path.read_text() if owner_path.exists() else None})
        raise RuntimeError('measurement host is reserved')
    owned = True
    owner = {'agent': '/root/stream_engine', 'purpose': 'bounded/http 62c238a streaming native Linux correctness; ReleaseSafe smoke only',
             'host': platform.node(), 'started_utc': report['started_utc'], 'pid': os.getpid(),
             'process_start_ticks': processes()[os.getpid()]['start_ticks'], 'token': TOKEN, 'cwd': str(ROOT)}
    (LOCK / 'owner.json').write_text(json.dumps(owner, indent=2) + '\n')
    save('reservation.json', owner)
    for sig in (signal.SIGALRM, signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, interruption)
    signal.alarm(1800)
    print('RESERVED ' + TOKEN, flush=True)
    manifest = json.loads((ROOT / 'source.json').read_text())
    archive = ROOT / 'source.tar'
    assert hashlib.sha256(archive.read_bytes()).hexdigest() == manifest['archive_sha256']
    SOURCE.mkdir()
    with tarfile.open(archive) as source_tar:
        for member in source_tar.getmembers():
            path = Path(member.name)
            assert not path.is_absolute() and '..' not in path.parts and (member.isfile() or member.isdir())
        source_tar.extractall(SOURCE, filter='data')
    for name, expected in manifest['files_sha256'].items():
        assert hashlib.sha256((SOURCE / name).read_bytes()).hexdigest() == expected, name
    save('source.json', manifest)
    zig = subprocess.check_output(['zig', 'version'], text=True).strip()
    assert zig == (SOURCE / '.zig-version').read_text().strip() == '0.16.0'
    environment = {'platform': platform.platform(), 'uname': list(platform.uname()), 'python': sys.version,
                   'zig': zig, 'zig_path': shutil.which('zig'), 'os_release': Path('/etc/os-release').read_text(),
                   'io_uring_disabled': Path('/proc/sys/kernel/io_uring_disabled').read_text().strip(),
                   'cpu_model': next(line.split(':', 1)[1].strip() for line in Path('/proc/cpuinfo').read_text().splitlines() if line.startswith('model name'))}
    save('environment.json', environment)
    gate('Debug', ['zig', 'build', 'verify', '--summary', 'all'], 300)
    gate('ReleaseSafe', ['zig', 'build', 'verify', '-Doptimize=ReleaseSafe', '--summary', 'all'], 300)
    gate('install', ['zig', 'build', '-Doptimize=ReleaseSafe', '--summary', 'all'], 300)
    gate('test_compare', ['python3', 'tests/test_compare.py', '-v'], 60)
    for suite in ('arena_lifecycle_integration', 'batch_integration', 'gather_integration', 'inline_integration', 'integration'):
        gate(suite, ['python3', 'tests/' + suite + '.py', '--json', str(OUT / (suite + '.json'))], 240)
    gate('smoke', ['python3', 'tools/smoke.py', '--json', str(OUT / 'smoke.json')], 180)
    report['ok'] = True
except BaseException as error:
    report['error'] = repr(error)
    (OUT / 'error.log').write_text(traceback.format_exc())
    print('ERROR ' + repr(error), flush=True)
finally:
    signal.alarm(0)
    cleanup = cleanup_children()
    cleanup['lock_released'] = False
    if owned and cleanup['ok']:
        current_owner = json.loads((LOCK / 'owner.json').read_text())
        assert current_owner['token'] == TOKEN
        (LOCK / 'owner.json').unlink()
        LOCK.rmdir()
        cleanup['lock_released'] = True
    save('cleanup.json', cleanup)
    report['finished_utc'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    save('summary.json', report)
    print(json.dumps({'ok': report['ok'], 'cleanup': cleanup, 'evidence': str(OUT)}), flush=True)
sys.exit(0 if report['ok'] else 1)
