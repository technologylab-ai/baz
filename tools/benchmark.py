#!/usr/bin/env python3
"""Python/client-bound HTTP smoke measurement, never a TechEmpower ranking.

Runs a finite number of pipelined requests per connection. Latency is recorded
from batch submission to each ordered response: these are closed-loop pipeline
latencies, not an open-loop SLO measurement. No automatic server launch or tune.
"""

import argparse
import concurrent.futures
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import platform
import socket
import sys
import threading
import time
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("zig_http_wire_test", ROOT / "tests/integration.py")
WIRE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(WIRE)


def percentile(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    return round(ordered[max(0, math.ceil(len(ordered) * fraction) - 1)] * 1000, 6)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("url", nargs="?", default="http://127.0.0.1:8080/plaintext")
    parser.add_argument("--connections", type=int, default=8)
    parser.add_argument("--requests", type=int, default=1000, help="total requests, divided across connections")
    parser.add_argument("--pipeline", type=int, default=1)
    parser.add_argument("--timeout", type=float, default=5, help="per-socket operation seconds")
    parser.add_argument("--deadline", type=float, default=60, help="overall cooperative measurement deadline seconds")
    parser.add_argument("--expect-file", type=Path, help="compare each body against these exact bytes")
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    parsed = urlsplit(args.url)
    if parsed.scheme != "http" or not parsed.hostname or parsed.username or parsed.password or parsed.fragment:
        parser.error("use an http://host:port/path URL without credentials or fragment")
    if not (1 <= args.connections <= 1024 and args.connections <= args.requests <= 1_000_000 and
            1 <= args.pipeline <= 256 and 0 < args.timeout <= 60 and 0 < args.deadline <= 3600):
        parser.error("bounds: connections 1..1024 <= requests <= 1000000, pipeline 1..256, timeout (0,60], deadline (0,3600]")
    target = parsed.path or "/"
    if parsed.query:
        target += "?" + parsed.query
    if any(character in target + parsed.netloc for character in "\r\n "):
        parser.error("URL target/authority must not contain spaces or CR/LF")
    try:
        request = ("GET %s HTTP/1.1\r\nHost: %s\r\n\r\n" % (target, parsed.netloc)).encode("ascii")
    except UnicodeEncodeError:
        parser.error("URL must be ASCII/percent-encoded")
    expected = args.expect_file.read_bytes() if args.expect_file else (WIRE.PLAINTEXT if parsed.path == "/plaintext" else None)
    barrier = threading.Barrier(args.connections + 1, timeout=min(args.deadline, 10))
    stop = threading.Event()
    deadline = time.monotonic() + args.deadline

    def worker(count):
        latencies = []
        body_bytes = 0
        first_hash = None
        error = None
        try:
            with socket.create_connection((parsed.hostname, parsed.port or 80), args.timeout) as sock:
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                reader = WIRE.ResponseReader(sock)
                barrier.wait()
                for offset in range(0, count, args.pipeline):
                    if stop.is_set() or time.monotonic() >= deadline:
                        raise TimeoutError("measurement deadline or peer failure")
                    sock.settimeout(min(args.timeout, max(0.001, deadline - time.monotonic())))
                    batch = min(args.pipeline, count - offset)
                    start = time.monotonic()
                    sock.sendall(request * batch)
                    for _ in range(batch):
                        status, headers, body = reader.response()
                        if status != 200:
                            raise RuntimeError("response status %d" % status)
                        if expected is not None and body != expected:
                            raise RuntimeError("response body differs from expected bytes")
                        if first_hash is None:
                            first_hash = hashlib.sha256(body).hexdigest()
                        latencies.append(time.monotonic() - start)
                        body_bytes += len(body)
        except Exception as failure:
            stop.set()
            barrier.abort()
            error = "%s: %s" % (type(failure).__name__, failure)
        return dict(latencies=latencies, body_bytes=body_bytes, body_sha256=first_hash, error=error)

    start = time.monotonic()
    cpu_start = time.process_time()
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.connections) as pool:
        futures = [pool.submit(worker, args.requests // args.connections + (index < args.requests % args.connections))
                   for index in range(args.connections)]
        try:
            barrier.wait()
            start = time.monotonic()
            cpu_start = time.process_time()
        except threading.BrokenBarrierError:
            stop.set()
        results = [future.result() for future in futures]
    elapsed = time.monotonic() - start
    cpu_elapsed = time.process_time() - cpu_start
    latencies = [value for result in results for value in result["latencies"]]
    errors = [result["error"] for result in results if result["error"]]
    receipt = dict(schema_version=1, tool="zig-http-python-smoke", ok=not errors and len(latencies) == args.requests,
                   classification="Python/client-bound smoke; not TechEmpower ranking or server capacity",
                   latency_model="closed-loop; each pipelined response measured from its batch send",
                   url=args.url, platform=platform.platform(), machine=platform.machine(),
                   python=sys.version.split()[0], connections=args.connections, pipeline=args.pipeline,
                   requested=args.requests, completed=len(latencies), errors=errors,
                   seconds=round(elapsed, 6), requests_per_second=round(len(latencies) / elapsed, 3),
                   client_cpu_seconds=round(cpu_elapsed, 6), client_cpu_per_wall=round(cpu_elapsed / elapsed, 3),
                   body_bytes=sum(result["body_bytes"] for result in results),
                   body_sha256=sorted(set(result["body_sha256"] for result in results if result["body_sha256"])),
                   body_validation="exact expected bytes" if expected is not None else "status/framing only; first body hash per connection",
                   p50_ms=percentile(latencies, 0.5), p99_ms=percentile(latencies, 0.99),
                   p999_ms=percentile(latencies, 0.999))
    encoded = json.dumps(receipt, sort_keys=True)
    print(encoded)
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(encoded + "\n", encoding="utf-8")
    return 0 if receipt["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
