#!/usr/bin/env python3
"""Native CLI correctness checks for the 22 examples and three Baz fixtures.

Build and install ReleaseSafe binaries first. The caller holds the shared host
reservation and supplies an overall process-tree watchdog. Help/error processes
have finite exit deadlines; startup cases reuse the wire harness's shutdown and
terminal ownership checks. This suite makes no performance claims.
"""

import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import sys
import tempfile
import threading

import wire_support as wire


EXAMPLES = (
    "hello", "hello2", "hello_json", "simple_router", "routes", "serve",
    "sendfile", "senderror", "accept", "app_basic", "app_auth", "app_errors",
    "endpoint", "endpoint_auth", "middleware", "middleware_with_endpoint",
    "userpass_session", "cookies", "http_params", "bindataformpost", "streaming", "mustache",
)
FIXTURES = ("baz", "baz-streaming", "baz-borrow")
WORKER_EXAMPLES = frozenset(("endpoint", "streaming"))
EXIT_TIMEOUT = 5
MAX_TRANSCRIPT = 65536
PROBE = b"OPTIONS * HTTP/1.1\r\nHost: localhost\r\n\r\n"


def executable(directory, name):
    path = directory / (name + ".exe" if os.name == "nt" else name)
    wire.require(path.is_file(), "missing CLI executable: " + str(path))
    return path


def spawn(binary, arguments, **streams):
    if os.name == "nt":
        # Match the shared harness: hosted Windows runners can lack a console.
        import ctypes
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        if kernel.GetConsoleCP() == 0:
            wire.require(kernel.AllocConsole() != 0, "cannot allocate CLI test control console")
    return subprocess.Popen(
        [str(binary), *arguments], cwd=wire.ROOT, stdin=subprocess.DEVNULL,
        start_new_session=(os.name == "posix"),
        creationflags=subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0,
        **streams,
    )


def kill_process(process):
    if process.poll() is not None:
        return
    if os.name == "posix":
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGKILL)
    else:
        process.kill()
    process.wait(timeout=3)


def exits_before_ready(binary, arguments, expected_code, diagnostic=None):
    # A temporary transcript avoids unbounded Python pipe accumulation. Read
    # only a finite prefix after the process has exited or has been killed.
    with tempfile.TemporaryFile() as transcript:
        process = spawn(binary, arguments, stdout=transcript, stderr=subprocess.STDOUT)
        try:
            try:
                code = process.wait(timeout=EXIT_TIMEOUT)
            except subprocess.TimeoutExpired:
                kill_process(process)
                raise AssertionError(f"{binary.name} {arguments!r}: CLI exit deadline exceeded")
        finally:
            kill_process(process)
        transcript.seek(0)
        output = transcript.read(MAX_TRANSCRIPT + 1)
    label = f"{binary.name} {arguments!r}"
    wire.require(len(output) <= MAX_TRANSCRIPT, label + ": CLI transcript exceeded its bound")
    text = output.decode("utf-8", "replace")
    wire.require(code == expected_code, f"{label}: exit {code}, expected {expected_code}\n{text}")
    wire.require(b"READY " not in output and b"STATS " not in output,
                 label + ": help or invalid arguments reached HTTP startup")
    wire.require(output.strip(), label + ": no help or error diagnostic was printed")
    for fault in (b"panic:", b"Segmentation fault", b"General protection exception", b"error(gpa):"):
        wire.require(fault not in output, label + ": abnormal CLI failure\n" + text)
    if diagnostic is not None:
        wire.require(diagnostic.lower() in text.lower(), label + ": missing diagnostic detail\n" + text)
    return dict(arguments=list(arguments), exit_code=code, before_ready=True,
                output_bytes=len(output), output_sha256=hashlib.sha256(output).hexdigest())


class CliServer(wire.Server):
    """Use exact argument order/spelling, retaining shared lifecycle checks."""

    def __init__(self, binary, arguments, workers, execution):
        super().__init__(binary)
        self.arguments = list(arguments)
        self.options = dict(connections=4, workers=workers)
        self.expected_execution = execution

    def __enter__(self):
        self.process = spawn(self.binary, self.arguments,
                             stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.reader_thread = threading.Thread(target=self._read_log, daemon=True)
        self.reader_thread.start()
        if not self.ready.wait(8) or self.port is None:
            self._kill()
            self.reader_thread.join(timeout=2)
            self.process.stderr.close()
            raise AssertionError("CLI server did not become ready:\n" + "\n".join(self.lines))
        try:
            wire.require(0 < self.port <= 65535, "invalid bound CLI port")
            ready = [line for line in self.lines if line.startswith("READY ")]
            wire.require(len(ready) == 1, "CLI server emitted repeated READY records")
            wire.require("optimize=ReleaseSafe" in ready[0], "CLI startup gates require ReleaseSafe")
            wire.require("execution=" + self.expected_execution + " " in ready[0],
                         "CLI execution selection changed: " + ready[0])
        except BaseException:
            self.__exit__(*sys.exc_info())
            raise
        return self


def run(directory):
    binaries = {name: executable(directory, name) for name in EXAMPLES + FIXTURES}
    exits = []
    startups = []

    def exit_case(name, label, arguments, code=1, diagnostic=None):
        receipt = exits_before_ready(binaries[name], arguments, code, diagnostic)
        exits.append(dict(executable=name, case=label, **receipt))
        return receipt

    for name in EXAMPLES + FIXTURES:
        short = exit_case(name, "short help", ["-h"], 0, "--port")
        long = exit_case(name, "long help", ["--help"], 0, "--port")
        wire.require(short["output_sha256"] == long["output_sha256"],
                     name + ": -h and --help show different help")
        for label, arguments, detail in (
            ("unknown option", ["--definitely-unknown-option"], "definitely-unknown-option"),
            ("missing numeric value", ["--port"], "port"),
            ("empty numeric value", ["--port="], "port"),
            ("numeric type overflow", ["--port=65536"], "port"),
            ("invalid enum", ["--execution=async"], "execution"),
            ("duplicate option across spellings", ["--port=0", "--port", "0"], "duplicate"),
        ):
            exit_case(name, label, arguments, diagnostic=detail)
        print("PASS " + name + ": help and argument rejection before READY", flush=True)

    # These four binaries cover the shared example options and all three
    # fixture-specific option structs, including optional integer parsing.
    for name in ("hello",) + FIXTURES:
        for label, arguments, detail in (
            ("help prefix is not help", ["--helpful"], "helpful"),
            ("help does not take a value", ["--help=true"], "help"),
            ("empty separate value", ["--port", ""], "port"),
            ("negative unsigned value", ["--port=-1"], "port"),
            ("empty optional integer", ["--workers="], "workers"),
            ("optional integer overflow", ["--workers=65536"], "workers"),
            ("duration overflow", ["--duration-ms=4294967296"], "duration"),
            ("zero connection capacity", ["--connections=0"], "InvalidConfiguration"),
            ("workers cannot be zero", ["--execution=workers", "--workers=0"], "InvalidConfiguration"),
            ("inline cannot own workers", ["--workers=1", "--execution=inline"], "InvalidConfiguration"),
        ):
            exit_case(name, label, arguments, diagnostic=detail)

    exit_case("hello", "alias and long option share duplicate state",
              ["-p", "0", "--port=0"], diagnostic="duplicate")
    for name in sorted(WORKER_EXAMPLES):
        exit_case(name, "worker-required example rejects inline", ["--execution=inline"],
                  diagnostic="WorkerExecutionRequired")
        exit_case(name, "worker-required example rejects multiple shards", ["--shards=2"],
                  diagnostic="WorkerExecutionRequired")
        exit_case(name, "worker-required example rejects zero workers", ["--workers=0"],
                  diagnostic="InvalidConfiguration")

    def startup(name, label, arguments, workers, execution):
        with CliServer(binaries[name], arguments, workers, execution) as server:
            status, _, body = wire.request(server, PROBE)
            wire.require(status == 204 and body == b"", name + ": OPTIONS startup probe failed")
        wire.require(server.stats["completed"] >= 1, name + ": startup probe did not complete")
        startups.append(dict(executable=name, case=label, arguments=arguments,
                             backend=server.backend, execution=execution,
                             stats=server.stats))
        print("PASS " + name + ": " + label, flush=True)

    # Every public example exercises its -p alias and execution default. The
    # normal wire suites retain responsibility for each example's HTTP routes.
    for index, name in enumerate(EXAMPLES):
        port = ["-p", "0"] if index % 2 == 0 else ["-p=0"]
        arguments = port + ["--connections=4", "--shards", "1", "--duration-ms=15000"]
        workers = 2 if name in WORKER_EXAMPLES else 0
        startup(name, "port alias and execution default", arguments, workers,
                "workers" if workers else "inline_event_loop")

    base = ["--port=0", "--connections=4", "--shards=1", "--duration-ms=15000"]
    for name in FIXTURES:
        workers = 0 if name == "baz" else 2
        startup(name, "fixture execution default", base, workers,
                "workers" if workers else "inline_event_loop")

    for name in ("hello",) + FIXTURES:
        for label, selection in (
            ("worker count before execution", ["--workers", "1", "--execution=workers"]),
            ("worker count after execution", ["--execution", "workers", "--workers=1"]),
        ):
            startup(name, label, base + selection, 1, "workers")

    return dict(passed=len(exits) + len(startups), executables=len(binaries),
                exit_cases=exits, startup_cases=startups,
                platform=platform.platform(), optimize="ReleaseSafe",
                performance_comparison=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=wire.ROOT / "zig-out/bin")
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    result = run(args.directory.resolve())
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(dict(passed=result["passed"], executables=result["executables"],
                          exit_cases=len(result["exit_cases"]),
                          startup_cases=len(result["startup_cases"]),
                          performance_comparison=False)), flush=True)


if __name__ == "__main__":
    main()
