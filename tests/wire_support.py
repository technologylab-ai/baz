"""Shared bounded wire/process harness for native framework suites.

ResponseReader retains unread TCP suffixes and enforces explicit framing and
storage bounds. Server owns its process and log reader with finite startup,
shutdown and socket deadlines. The suite runner supplies the overall watchdog.
"""

import contextlib
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import sys
import threading


ROOT = Path(__file__).resolve().parents[1]


def require(condition, message):
    if not condition:
        raise AssertionError(message)


class ResponseReader:
    """Small test-side HTTP/1.x parser with explicit storage bounds."""

    def __init__(self, sock, maximum=4 * 1024 * 1024):
        self.sock = sock
        self.buffer = bytearray()
        self.maximum = maximum

    def _receive(self):
        data = self.sock.recv(65536)
        if not data:
            raise EOFError("EOF before complete HTTP response")
        self.buffer.extend(data)
        require(len(self.buffer) <= self.maximum + 65536, "client response buffer limit")

    def _take(self, count):
        require(0 <= count <= self.maximum, "response body exceeds client limit")
        while len(self.buffer) < count:
            self._receive()
        result = bytes(self.buffer[:count])
        del self.buffer[:count]
        return result

    def _line(self, maximum=16384):
        while True:
            end = self.buffer.find(b"\r\n")
            if end >= 0:
                require(end <= maximum, "response line exceeds client limit")
                line = bytes(self.buffer[:end])
                del self.buffer[:end + 2]
                return line
            require(len(self.buffer) <= maximum, "response line exceeds client limit")
            self._receive()

    def response(self, head=False):
        line = self._line()
        parts = line.split(b" ", 2)
        require(len(parts) >= 2 and parts[0] == b"HTTP/1.1", "bad response status line: %r" % line)
        status = int(parts[1])
        headers = {}
        header_bytes = len(line) + 2
        for _ in range(128):
            line = self._line()
            header_bytes += len(line) + 2
            require(header_bytes <= 32768, "response headers exceed client limit")
            if not line:
                break
            require(b":" in line, "malformed response header")
            name, value = line.split(b":", 1)
            name = name.lower()
            require(name not in headers or name not in (b"content-length", b"transfer-encoding"),
                    "duplicate response framing header")
            headers[name] = value.strip()
        else:
            raise AssertionError("too many response headers")
        if head or 100 <= status < 200 or status in (204, 304):
            return status, headers, b""
        require(not (b"content-length" in headers and b"transfer-encoding" in headers),
                "conflicting response framing")
        if b"transfer-encoding" in headers:
            require(headers[b"transfer-encoding"].lower() == b"chunked", "unsupported response coding")
            chunks = []
            total = 0
            for _ in range(self.maximum + 1):
                size = int(self._line().split(b";", 1)[0], 16)
                total += size
                require(total <= self.maximum, "chunked response exceeds client limit")
                if size == 0:
                    for _ in range(128):
                        if not self._line():
                            return status, headers, b"".join(chunks)
                    raise AssertionError("too many response trailers")
                chunks.append(self._take(size))
                require(self._take(2) == b"\r\n", "bad chunk terminator")
            raise AssertionError("too many response chunks")
        require(b"content-length" in headers, "test response must have explicit framing")
        return status, headers, self._take(int(headers[b"content-length"]))


class Server:
    def __init__(self, binary, **options):
        self.binary = binary
        self.options = dict(execution="workers", port=0, connections=16, workers=2, max_body=1024,
                            max_header=2048, timeout_ms=3000, stall_ms=1000,
                            send_chunk=7)
        self.options.update(options)
        self.process = None
        self.port = None
        self.backend = None
        self.stats = None
        self.lines = []
        self.ready = threading.Event()
        self.reader_thread = None

    def _read_log(self):
        try:
            for raw in iter(self.process.stderr.readline, b""):
                line = raw.decode("utf-8", "replace").rstrip()
                self.lines.append(line[:8192])
                del self.lines[:-200]
                ready = re.search(r"\bREADY port=(\d+) backend=(\S+)", line)
                if ready:
                    self.port = int(ready.group(1))
                    self.backend = ready.group(2)
                    self.ready.set()
                if line.startswith("STATS "):
                    self.stats = json.loads(line[6:])
        except Exception as error:
            self.lines.append("client log reader failed: %r" % error)
        finally:
            self.ready.set()

    def __enter__(self):
        command = [str(self.binary)]
        for key, value in self.options.items():
            command += ["--" + key.replace("_", "-"), str(value)]
        self.process = subprocess.Popen(command, cwd=ROOT, stdin=subprocess.DEVNULL,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                        start_new_session=(os.name == "posix"))
        self.reader_thread = threading.Thread(target=self._read_log, daemon=True)
        self.reader_thread.start()
        if not self.ready.wait(8) or self.port is None:
            self._kill()
            raise AssertionError("server did not become ready:\n" + "\n".join(self.lines))
        require(0 < self.port <= 65535, "invalid bound port")
        return self

    def connect(self, timeout=3.0):
        sock = socket.create_connection(("127.0.0.1", self.port), timeout=timeout)
        sock.settimeout(timeout)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        return sock

    def _kill(self):
        if self.process and self.process.poll() is None:
            if os.name == "posix":
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(self.process.pid, signal.SIGKILL)
            else:
                self.process.kill()
            self.process.wait(timeout=3)

    def __exit__(self, kind, value, tb):
        failure = None
        try:
            if self.process.poll() is None:
                self.process.send_signal(signal.SIGINT)
            try:
                code = self.process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                self._kill()
                raise AssertionError("server exceeded eight-second shutdown watchdog")
            self.reader_thread.join(timeout=2)
            require(code == 0, "server exited %d:\n%s" % (code, "\n".join(self.lines)))
            require(isinstance(self.stats, dict), "server did not emit final STATS JSON")
            for field in ("accepted", "completed", "rejected", "timeouts", "flushes", "resumed",
                          "bytes_received", "bytes_sent", "live_connections", "peak_connections",
                          "live_operations", "peak_operations", "workers", "allocation_calls_after_start"):
                require(type(self.stats.get(field)) is int and self.stats[field] >= 0,
                        "missing/non-integer/negative stats field: " + field)
            require(self.stats["live_connections"] == 0, "connection ownership leaked at shutdown")
            require(self.stats["live_operations"] == 0, "operation ownership leaked at shutdown")
            require(self.stats["peak_connections"] <= self.options["connections"], "connection cap exceeded")
            require(self.stats["workers"] == self.options["workers"], "worker provisioning differs from config")
            require(self.stats["allocation_calls_after_start"] == 0, "framework allocated after startup")
            heap_fields = ("framework_heap_peak_bytes", "framework_heap_limit_bytes")
            if any(field in self.stats for field in heap_fields):
                for field in heap_fields:
                    require(type(self.stats.get(field)) is int and self.stats[field] >= 0,
                            "missing/non-integer/negative heap stats field: " + field)
                require(self.stats[heap_fields[0]] <= self.stats[heap_fields[1]],
                        "framework heap exceeded its startup limit")
        except BaseException as error:
            failure = error
        finally:
            self._kill()
            self.process.stderr.close()
        if failure and kind is None:
            raise failure
        if failure:
            print("Shutdown also failed: %s" % failure, file=sys.stderr)
        return False


def request(server, data, head=False):
    with server.connect() as sock:
        sock.sendall(data)
        return ResponseReader(sock).response(head=head)


def expect_closed(sock):
    try:
        require(sock.recv(1) == b"", "unexpected bytes after connection-close response")
    except ConnectionResetError:
        pass
