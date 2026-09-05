#!/usr/bin/env python3
"""Launch a ReleaseSafe server and run three finite Python/client-bound workloads.

No warmup, repetition, external load generator, TechEmpower comparison or SLO
claim is implied. Each workload validates every body and retains its own client
CPU/latency receipt. The server is always stopped and ownership counters checked.
"""

import argparse
import contextlib
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import resource
import signal
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("zig_http_smoke_server", ROOT / "tests/integration.py")
WIRE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(WIRE)
WORKLOADS = (("plaintext_p1", "plaintext", 1),
             ("plaintext_p16", "plaintext", 16),
             ("html_p16", "index.html", 16))


def command_text(command):
    try:
        result = subprocess.run(command, cwd=ROOT, stdin=subprocess.DEVNULL,
                                capture_output=True, text=True, timeout=3)
        return result.stdout.strip() if result.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def environment():
    cpu = dict(model=platform.processor() or None, logical_count=os.cpu_count(),
               physical_count=None)
    memory_bytes = None
    if sys.platform == "darwin":
        cpu["model"] = command_text(["sysctl", "-n", "machdep.cpu.brand_string"])
        count = command_text(["sysctl", "-n", "hw.physicalcpu"])
        memory = command_text(["sysctl", "-n", "hw.memsize"])
        cpu["physical_count"] = int(count) if count and count.isdecimal() else None
        memory_bytes = int(memory) if memory and memory.isdecimal() else None
    elif sys.platform.startswith("linux"):
        with contextlib.suppress(OSError):
            for line in Path("/proc/cpuinfo").read_text().splitlines():
                if line.startswith("model name"):
                    cpu["model"] = line.split(":", 1)[1].strip()
                    break
        with contextlib.suppress(OSError, ValueError):
            for line in Path("/proc/meminfo").read_text().splitlines():
                if line.startswith("MemTotal:"):
                    memory_bytes = int(line.split()[1]) * 1024
                    break
    return dict(platform=platform.platform(), system=platform.system(),
                kernel_release=platform.release(), kernel_version=platform.version(),
                machine=platform.machine(), hostname=platform.node(),
                python=sys.version.split()[0], python_executable=sys.executable,
                cpu=cpu, physical_memory_bytes=memory_bytes,
                network="IPv4 TCP loopback; client and server share this host")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", type=Path, default=ROOT / "zig-out/bin/zig-http")
    parser.add_argument("--requests", type=int, default=10000,
                        help="per workload, default 10000; three workloads with eight clients each")
    parser.add_argument("--timeout", type=int, default=150,
                        help="whole-run watchdog seconds, including startup/shutdown")
    parser.add_argument("--json", type=Path, help="also save the combined JSON receipt")
    args = parser.parse_args()
    if not 8 <= args.requests <= 1000000 or not 10 <= args.timeout <= 3600:
        parser.error("requests must be 8..1000000 and timeout 10..3600 seconds")
    binary = args.server.resolve()
    asset = ROOT / "assets/index.html"
    configuration = dict(port=0, connections=128, workers=2, max_body=65536,
                         max_header=16384, timeout_ms=5000, stall_ms=1000,
                         send_chunk=65536, socket_send_buffer=65536,
                         duration_ms=args.timeout * 1000)
    receipt = dict(schema_version=1, tool="zig-http-smoke-suite", ok=False,
                   classification="Python/client-bound smoke; not TechEmpower ranking, server capacity or SLO evidence",
                   warning="Short closed-loop loopback runs without warmup/repetitions; keep safety assertions enabled and compare only matching environments",
                   started_utc=datetime.now(timezone.utc).isoformat(), environment=None,
                   build=dict(binary=str(binary), optimize=None),
                   server=dict(configuration=configuration, ready=None, stats=None),
                   workloads=[])
    started = time.monotonic()
    deadline = started + args.timeout
    previous_handlers = {}
    server = None
    child_usage_start = resource.getrusage(resource.RUSAGE_CHILDREN)

    def watchdog(signum, frame):
        raise TimeoutError("smoke orchestration interrupted or whole-run watchdog expired")

    for name in ("SIGALRM", "SIGTERM"):
        if hasattr(signal, name):
            number = getattr(signal, name)
            previous_handlers[number] = signal.signal(number, watchdog)
    if hasattr(signal, "SIGALRM"):
        signal.alarm(args.timeout)
    try:
        WIRE.require(binary.is_file(), "build the ReleaseSafe server first: zig build -Doptimize=ReleaseSafe")
        receipt["environment"] = environment()
        receipt["build"].update(binary_sha256=digest(binary),
                                zig_target=(ROOT / ".zig-version").read_text().strip(),
                                repository_commit=command_text(["git", "rev-parse", "HEAD"]),
                                repository_status=command_text(["git", "status", "--porcelain=v1", "--untracked-files=all"]))
        receipt["asset"] = dict(path="assets/index.html", bytes=asset.stat().st_size,
                                sha256=digest(asset))
        with WIRE.Server(binary, **configuration) as server:
            ready = next((line for line in server.lines if line.startswith("READY ")), "")
            receipt["server"].update(ready=ready, backend=server.backend, port=server.port)
            marker = re.search(r"(?:^|\s)optimize=(\S+)", ready)
            mode = marker.group(1) if marker else None
            receipt["build"]["optimize"] = mode
            WIRE.require(mode == "ReleaseSafe",
                         "server READY must report optimize=ReleaseSafe; got %r. Rebuild with -Doptimize=ReleaseSafe" % mode)
            for name, route, pipeline in WORKLOADS:
                remaining = deadline - time.monotonic() - 10
                WIRE.require(remaining > 1, "not enough watchdog budget for workload and safe shutdown")
                child_timeout = min(40, remaining)
                command = [sys.executable, str(ROOT / "tools/benchmark.py"),
                           "http://127.0.0.1:%d/%s" % (server.port, route),
                           "--connections", "8", "--requests", str(args.requests),
                           "--pipeline", str(pipeline), "--timeout", "5",
                           "--deadline", str(max(0.1, child_timeout - 2))]
                if route == "index.html":
                    command += ["--expect-file", str(asset)]
                result = subprocess.run(command, cwd=ROOT, stdin=subprocess.DEVNULL,
                                        capture_output=True, text=True, timeout=child_timeout)
                workload = dict(name=name, command=command, exit_code=result.returncode,
                                stderr=result.stderr[-8192:])
                receipt["workloads"].append(workload)
                workload["result"] = json.loads(result.stdout)
                WIRE.require(result.returncode == 0 and workload["result"].get("ok") is True,
                             "workload failed: " + name)
                WIRE.require(workload["result"].get("completed") == args.requests and
                             workload["result"].get("body_validation") == "exact expected bytes",
                             "workload did not validate every expected response: " + name)
                print("PASS %s: %d responses (Python/client-bound)" % (name, args.requests),
                      file=sys.stderr, flush=True)
        receipt["server"]["stats"] = server.stats
        WIRE.require(server.stats["completed"] == args.requests * len(WORKLOADS),
                     "server completion count differs from validated client responses")
        WIRE.require(server.stats["rejected"] == 0 and server.stats["timeouts"] == 0,
                     "smoke run encountered rejection or timeout")
        WIRE.require(digest(binary) == receipt["build"]["binary_sha256"],
                     "binary changed during measurement; rerun against one stable build")
        WIRE.require(digest(asset) == receipt["asset"]["sha256"],
                     "HTML asset changed during measurement")
        receipt["ok"] = True
    except (Exception, KeyboardInterrupt) as error:
        receipt["error"] = "%s: %s" % (type(error).__name__, error)
        print(receipt["error"], file=sys.stderr)
    finally:
        if server is not None:
            receipt["server"]["stats"] = server.stats
        if hasattr(signal, "SIGALRM"):
            signal.alarm(0)
        for number, handler in previous_handlers.items():
            signal.signal(number, handler)
    child_usage_end = resource.getrusage(resource.RUSAGE_CHILDREN)
    receipt["child_cpu"] = dict(
        user_seconds=round(child_usage_end.ru_utime - child_usage_start.ru_utime, 6),
        system_seconds=round(child_usage_end.ru_stime - child_usage_start.ru_stime, 6),
        scope="All reaped children, including server, clients and metadata commands; not isolated server CPU")
    receipt["seconds"] = round(time.monotonic() - started, 6)
    encoded = json.dumps(receipt, sort_keys=True)
    print(encoded)
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(encoded + "\n", encoding="utf-8")
    return 0 if receipt["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
