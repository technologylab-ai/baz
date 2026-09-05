#!/usr/bin/env python3
"""Prepare pinned Linux contenders in a fresh caller-owned temporary directory.

Builds and writes configuration; never launches a server or a load generator.
--check validates the inputs and prints the plan without changing anything.
"""
import argparse
import contextlib
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import uuid

HERE = Path(__file__).resolve().parent
PINS = json.loads((HERE / 'pins.json').read_text())
OUTPUT_NAMES = ('libreactor-build', 'wrk-build', 'mrhttp-build', 'bin',
                'preparation.log', 'preparation.json', 'comparison-config.json')


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def cpu_list(text):
    require(re.fullmatch(r'\d+(,\d+)*', text), 'CPU list must contain comma-separated integers')
    result = [int(value) for value in text.split(',')]
    require(len(set(result)) == len(result), 'duplicate CPU')
    return result


def validate(args):
    require(sys.platform == 'linux' and os.uname().machine == 'x86_64',
            'this recipe requires native Linux x86_64; its CPython wheels are architecture-specific')
    require(re.fullmatch(r'/tmp/zig-http-compare\.[A-Za-z0-9]{6,}', str(args.directory)),
            'directory must be /tmp/zig-http-compare.<at least six alphanumeric characters>')
    info = args.directory.lstat()
    require(stat.S_ISDIR(info.st_mode) and not args.directory.is_symlink()
            and args.directory.resolve() == args.directory and info.st_uid == os.getuid(),
            'temporary directory must be real, canonical, and owned by the caller')
    require(re.fullmatch(r'[0-9a-f]{40}', args.commit), 'provide the full archived Zig HTTP commit')
    archive = args.directory / 'zig-http'
    require(archive.is_dir() and not archive.is_symlink(), 'place the clean Zig HTTP archive in directory/zig-http first')
    require((archive / '.zig-version').read_text().strip() == PINS['zig_version'], 'Zig version mismatch')
    require((archive / 'src/main.zig').is_file(), 'missing archived server sources')
    require((archive / 'tools/compare.py').is_file(), 'archive must contain the comparison harness')
    require(not any((args.directory / name).exists() for name in OUTPUT_NAMES),
            'preparation outputs already exist; use a fresh directory instead of overwriting')
    require(len(args.server_cpus) == 3, 'this recipe preserves exactly three server CPUs/workers')
    require(len(args.client_cpus) >= 4, 'the default comparison needs at least four client CPUs')
    require(not set(args.server_cpus) & set(args.client_cpus), 'server and client CPUs overlap')
    require(set(args.server_cpus + args.client_cpus) <= os.sched_getaffinity(0), 'CPU unavailable to this process')
    for tool in ('git', 'curl', 'gcc', 'gcc-ar', 'gcc-nm', 'gcc-ranlib', 'g++', 'autoreconf',
                 'autoconf', 'automake', 'libtoolize', 'make', 'unzip', 'openssl', 'docker', 'taskset', 'lscpu', 'ldd'):
        require(shutil.which(tool), 'missing prerequisite: ' + tool)
    require(shutil.which(args.zig), 'exact Zig compiler is unavailable: ' + args.zig)
    for name, record in PINS['repositories'].items():
        require(re.fullmatch(r'[0-9a-f]{40}', record['commit']), 'unpinned repository: ' + name)
    for package in PINS['mrhttp_packages']:
        require(re.fullmatch(r'[0-9a-f]{64}', package['sha256']), 'invalid package hash')


class Preparation:
    def __init__(self, args, log):
        self.args = args
        self.root = args.directory
        self.log = log
        self.receipt = dict(schema_version=1, pins=PINS, caller_asserted_archive_commit=args.commit,
                            started_utc=datetime.now(timezone.utc).isoformat(),
                            source_commit_validation='Caller must create the input with git archive of this commit.',
                            server_cpus=args.server_cpus, client_cpus=args.client_cpus,
                            commands=[], hashes={}, ok=False, servers_started=False, load_tests_run=False)

    def command(self, argv, cwd=None, env=None, capture=False, timeout=300, check=True):
        argv = [str(value) for value in argv]
        directory = str(cwd or self.root)
        record = dict(argv=argv, cwd=directory, environment=env or {}, timeout_seconds=timeout)
        self.receipt['commands'].append(record)
        self.log.write('\n$ ' + shlex.join(argv) + '\n')
        self.log.flush()
        merged = dict(os.environ)
        # Do not let a developer shell silently override the submitted recipe's
        # compiler flags or make job limit. Explicit per-command values follow.
        for name in ('CFLAGS', 'CXXFLAGS', 'CPPFLAGS', 'LDFLAGS', 'MAKEFLAGS', 'MFLAGS'):
            merged.pop(name, None)
        if env:
            merged.update(env)
        process = subprocess.Popen(argv, cwd=directory, env=merged, start_new_session=True,
                                   stdout=subprocess.PIPE if capture else self.log,
                                   stderr=self.log, text=True)
        try:
            stdout, _ = process.communicate(timeout=timeout)
        except BaseException:
            # A timed-out make can leave compiler children behind if only its
            # immediate process is killed. This entire process group is ours.
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGTERM)
            try:
                process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGKILL)
                process.communicate(timeout=5)
            finally:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGKILL)
            raise
        finally:
            record['returncode'] = process.returncode
        if check and process.returncode:
            raise subprocess.CalledProcessError(process.returncode, argv, output=stdout)
        if capture:
            self.log.write(stdout)
            self.log.flush()
            return stdout.strip()
        return process.returncode

    def fetch(self, url, destination, expected):
        destination.parent.mkdir(parents=True, exist_ok=True)
        self.command(['curl', '--fail', '--location', '--silent', '--show-error',
                      '--connect-timeout', '30', '--max-time', '300', url, '--output', destination], timeout=310)
        actual = sha256(destination)
        require(actual == expected, 'download hash mismatch: ' + url)
        self.receipt['hashes'][str(destination.relative_to(self.root))] = actual

    def clone(self, name, parent):
        record = PINS['repositories'][name]
        path = parent / name
        self.command(['git', 'init', '-q', path])
        self.command(['git', 'remote', 'add', 'origin', record['repository']], path)
        self.command(['git', 'fetch', '--depth=1', 'origin', record['commit']], path)
        self.command(['git', 'checkout', '--detach', '-q', 'FETCH_HEAD'], path)
        require(self.command(['git', 'rev-parse', 'HEAD'], path, capture=True) == record['commit'],
                'unexpected fetched commit: ' + name)
        # git archive bytes include object-format provenance. Check against the
        # recorded source snapshot independently of the checkout's generated files.
        archive = path.with_suffix('.tar')
        self.command(['git', 'archive', '--output=' + str(archive), 'HEAD'], path)
        require(sha256(archive) == record['git_archive_sha256'], 'source archive hash mismatch: ' + name)
        self.receipt['hashes'][str(archive.relative_to(self.root))] = sha256(archive)
        return path

    def sources(self):
        for relative, expected in PINS['tfb_files'].items():
            if relative.startswith('frameworks/C/libreactor/'):
                destination = self.root / 'libreactor-build/app' / relative.removeprefix('frameworks/C/libreactor/')
            else:
                destination = self.root / 'mrhttp-build/original' / relative.removeprefix('frameworks/Python/mrhttp/')
            url = 'https://raw.githubusercontent.com/TechEmpower/FrameworkBenchmarks/' + PINS['tfb_commit'] + '/' + relative
            self.fetch(url, destination, expected)

    def native(self):
        build = self.root / 'libreactor-build'
        prefix = build / 'prefix'
        env = dict(CC='gcc', AR='gcc-ar', NM='gcc-nm', RANLIB='gcc-ranlib',
                   CPPFLAGS='-I' + str(prefix / 'include'), LDFLAGS='-L' + str(prefix / 'lib'))
        for name in ('libdynamic', 'libclo', 'libreactor'):
            source = self.clone(name, build)
            if name == 'libclo':
                path = source / 'src/clo.c'
                text = path.read_text()
                require(text.count('#include <dynamic.h>\n') == 1, 'unexpected libclo include')
                path.write_text(text.replace('#include <dynamic.h>\n', ''))
            self.command(['./autogen.sh'], source, env)
            configure = ['./configure', '--prefix=' + str(prefix)]
            if name == 'libclo':
                configure.append('CFLAGS=-march=native')
            self.command(configure, source, env)
            self.command(['make', '-j2'], source, env)
            self.command(['make', '-j2', 'install'], source, env)
        app = build / 'app'
        path = app / 'src/libreactor.c'
        text = path.read_text()
        require(text.count('server_open(&s, 0, 8080);') == 1, 'unexpected server bind source')
        path.with_suffix('.c.upstream').write_text(text)
        path.write_text(text.replace('server_open(&s, 0, 8080);', 'server_open(&s, 0x7f000001, 8080);'))
        self.command(['make', '-j2', 'libreactor', 'LDADD=-L' + str(prefix / 'lib') + ' -lreactor -ldynamic -lclo'], app, env)
        shutil.copy2(app / 'libreactor', self.root / 'bin/libreactor')
        wrk = self.clone('wrk', self.root / 'wrk-build')
        require(sha256(wrk / 'deps/LuaJIT-2.1.zip') == PINS['wrk_luajit_archive_sha256'], 'LuaJIT archive mismatch')
        self.command(['make', '-j2', 'WITH_OPENSSL=/usr'], wrk, dict(CC='gcc'))
        shutil.copy2(wrk / 'wrk', self.root / 'bin/wrk')
        for name in ('libreactor', 'wrk'):
            binary = self.root / 'bin' / name
            self.receipt['hashes'][str(binary.relative_to(self.root))] = sha256(binary)
            self.receipt[name + '_ldd'] = self.command(['ldd', binary], capture=True)
        for path in sorted((prefix / 'lib').glob('*.a')):
            self.receipt['hashes'][str(path.relative_to(self.root))] = sha256(path)
        self.receipt['hashes']['libreactor-build/app/src/libreactor.c'] = sha256(app / 'src/libreactor.c')
        self.receipt['host_openssl_library_sha256'] = {}
        for line in self.receipt['wrk_ldd'].splitlines():
            fields = line.split()
            if len(fields) >= 3 and fields[0].startswith(('libssl.', 'libcrypto.')) and fields[1] == '=>':
                path = Path(fields[2])
                require(path.is_file(), 'OpenSSL shared library is unavailable')
                self.receipt['host_openssl_library_sha256'][str(path)] = sha256(path)

    def mrhttp(self):
        build = self.root / 'mrhttp-build'
        for package in PINS['mrhttp_packages']:
            self.fetch(package['url'], build / 'packages' / package['filename'], package['sha256'])
        lock = '\n'.join(package['project'] + '==' + package['version'] + ' --hash=sha256:' + package['sha256']
                         for package in PINS['mrhttp_packages']) + '\n'
        (build / 'requirements.lock').write_text(lock)
        text = (build / 'original/app.py').read_text()
        original = "app.run('0.0.0.0', 8080, cores=multiprocessing.cpu_count())"
        require(text.count(original) == 1, 'unexpected mrhttp startup source')
        (build / 'app.py').write_text(text.replace(original, "app.run('127.0.0.1', 8080, cores=3)"))
        install = '''#!/bin/sh
set -eu
python3 -m venv /work/venv
/work/venv/bin/pip install --no-index --no-deps --no-build-isolation --require-hashes --find-links=/work/packages -r /work/requirements.lock
/work/venv/bin/python -m pip freeze > /work/pip-freeze.txt
/work/venv/bin/python -m pip --version > /work/pip-version.txt
/work/venv/bin/python --version > /work/python-version.txt
cc --version > /work/cc-version.txt
cat /etc/os-release > /work/os-release.txt
'''
        (build / 'install.sh').write_text(install)
        self.command(['docker', 'pull', '--platform', 'linux/amd64', PINS['python_image']], timeout=600)
        self.receipt['python_image_inspect'] = json.loads(self.command(['docker', 'image', 'inspect', PINS['python_image']], capture=True))
        user = str(os.getuid()) + ':' + str(os.getgid())
        name = 'zig-http-tfb-mrhttp-' + self.root.name.split('.', 1)[1]
        install_name = name + '-install'
        ownership = 'ai.technologylab.zig-http-preparation=' + uuid.uuid4().hex
        self.receipt['install_container'] = dict(name=install_name, ownership_label=ownership)
        try:
            self.command(['docker', 'run', '--rm', '--name', install_name, '--label', ownership,
                          '--platform', 'linux/amd64', '--network', 'none',
                          '--cpuset-cpus', ','.join(map(str, self.args.server_cpus[:2])), '--user', user,
                          '-e', 'PIP_NO_CACHE_DIR=1', '-e', 'MAKEFLAGS=-j2', '-e', 'PIP_DISABLE_PIP_VERSION_CHECK=1',
                          '-v', str(build) + ':/work', '-w', '/work', PINS['python_image'], 'sh', '/work/install.sh'])
        finally:
            # Docker containers outlive a killed docker-run CLI. A fresh ownership
            # label lets us remove only this invocation's install container, even
            # if creation failed because an unrelated container held its name.
            owned = self.command(['docker', 'ps', '--all', '--quiet', '--no-trunc',
                                  '--filter', 'label=' + ownership], capture=True, timeout=20).splitlines()
            for container in owned:
                require(re.fullmatch(r'[0-9a-f]{64}', container), 'unexpected owned Docker container ID')
                self.command(['docker', 'rm', '--force', container], timeout=20, check=False)
            remaining = self.command(['docker', 'ps', '--all', '--quiet', '--filter',
                                      'label=' + ownership], capture=True, timeout=20)
            require(not remaining, 'owned install container cleanup failed: ' + install_name)
        launch = ['docker', 'run', '--rm', '--name', name, '--platform', 'linux/amd64',
                  '--cpuset-cpus', ','.join(map(str, self.args.server_cpus)), '--network', 'host',
                  '--user', user, '-v', str(build) + ':/work', '-w', '/work',
                  PINS['python_image'], '/work/venv/bin/python', '-u', '/work/app.py']
        (build / 'launch.sh').write_text('#!/bin/sh\nset -eu\nexec ' + shlex.join(launch) + '\n')
        self.receipt['mrhttp_container_name'] = name
        self.receipt['mrhttp_packages'] = (build / 'pip-freeze.txt').read_text().splitlines()
        self.receipt['mrhttp_pip'] = (build / 'pip-version.txt').read_text().strip()
        for path in (build / 'app.py', build / 'launch.sh', build / 'requirements.lock'):
            self.receipt['hashes'][str(path.relative_to(self.root))] = sha256(path)
        for path in sorted(build.rglob('*.so')):
            self.receipt['hashes'][str(path.relative_to(self.root))] = sha256(path)
        return name

    def finish(self, container):
        source = self.root / 'zig-http'
        self.command([self.args.zig, 'build', '-Doptimize=ReleaseSafe', '-j2'], source)
        binary = source / 'zig-out/bin/zig-http'
        self.receipt['hashes'][str(binary.relative_to(self.root))] = sha256(binary)
        for path in sorted(source.rglob('*')):
            relative = path.relative_to(source)
            if path.is_file() and not any(part in ('.git', '.zig-cache', 'zig-out', '__pycache__') for part in relative.parts):
                self.receipt['hashes']['zig-http/' + str(relative)] = sha256(path)
        config = dict(server_cpus=self.args.server_cpus, client_cpus=self.args.client_cpus,
                      wrk=str(self.root / 'bin/wrk'), implementation_commit=self.args.commit,
                      servers=[
            dict(name='zig-http', cwd=str(source), command=[str(binary), '--port', '8080', '--connections', '128',
                 '--workers', '2', '--duration-ms', '120000'], body='Hello, World!'),
            dict(name='libreactor', cwd=str(self.root), command=[str(self.root / 'bin/libreactor')], body='Hello, World!'),
            dict(name='mrhttp', cwd=str(self.root), command=['sh', str(self.root / 'mrhttp-build/launch.sh')],
                 body='Hello, world!', pid_command=['docker', 'inspect', '-f', '{{.State.Pid}}', container],
                 stop=['docker', 'stop', '-t', '3', container])])
        (self.root / 'comparison-config.json').write_text(json.dumps(config, indent=2) + '\n')

    def run(self):
        for name in OUTPUT_NAMES[:4]:
            (self.root / name).mkdir()
        self.receipt['zig_version'] = self.command([self.args.zig, 'version'], capture=True)
        require(self.receipt['zig_version'] == PINS['zig_version'], 'compiler must be exactly ' + PINS['zig_version'])
        self.receipt['uname'] = self.command(['uname', '-a'], capture=True)
        self.receipt['os_release'] = Path('/etc/os-release').read_text()
        self.receipt['gcc'] = self.command(['gcc', '--version'], capture=True)
        self.receipt['openssl'] = self.command(['openssl', 'version', '-a'], capture=True)
        self.receipt['lscpu'] = self.command(['lscpu'], capture=True)
        if shutil.which('pacman'):
            self.receipt['packages'] = self.command(['pacman', '-Q', 'gcc', 'glibc', 'openssl',
                                                    'autoconf', 'automake', 'libtool', 'make'], capture=True)
        self.sources()
        self.native()
        container = self.mrhttp()
        self.finish(container)
        self.receipt['ok'] = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--commit', required=True, help='full commit used to create directory/zig-http with git archive')
    parser.add_argument('--server-cpus', type=cpu_list, default=[0, 1, 2])
    parser.add_argument('--client-cpus', type=cpu_list, default=[3, 4, 5, 6, 7])
    parser.add_argument('--zig', default='zig')
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    validate(args)
    if args.check:
        print(json.dumps(dict(directory=str(args.directory), commit=args.commit, mutates=False,
                              server_cpus=args.server_cpus, client_cpus=args.client_cpus,
                              planned_outputs=OUTPUT_NAMES, pins=PINS), indent=2))
        return 0
    with (args.directory / 'preparation.log').open('x') as log:
        preparation = Preparation(args, log)
        def interrupted(signum, _frame):
            raise TimeoutError('preparation interrupted by signal ' + str(signum))
        signal.signal(signal.SIGTERM, interrupted)
        signal.signal(signal.SIGALRM, interrupted)
        signal.alarm(3600)
        try:
            preparation.run()
        except BaseException as error:
            preparation.receipt['error'] = type(error).__name__ + ': ' + str(error)
            raise
        finally:
            signal.alarm(0)
            preparation.receipt['finished_utc'] = datetime.now(timezone.utc).isoformat()
            (args.directory / 'preparation.json').write_text(json.dumps(preparation.receipt, indent=2) + '\n')
    print('Prepared comparison-config.json; no server or load test was started.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
