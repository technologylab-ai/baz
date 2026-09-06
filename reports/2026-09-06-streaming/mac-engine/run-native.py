import contextlib
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import sys
import time
import uuid

OUT = Path(__file__).resolve().parent
ENGINE = OUT.parents[3] / "bounded-http-streaming"
if not ENGINE.is_dir():
    ENGINE = Path("/Users/rs/code/github.com/technologylab.ai/bounded-http-streaming")
BINARY = ENGINE / "zig-out/bin/bounded-http"
LOCK = Path("/tmp/zig-http-measurement.lock")
TOKEN = str(uuid.uuid4())


def now():
    return datetime.now(timezone.utc).isoformat()


def write(name, value):
    (OUT / name).write_text(json.dumps(value, indent=2) + "\n")


def command(args):
    return subprocess.check_output(args, cwd=ENGINE, text=True, timeout=5).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def processes():
    rows = subprocess.check_output(["ps", "-axo", "pid=,ppid=,pgid=,lstart=,args="], text=True, timeout=5)
    result = {}
    for line in rows.splitlines():
        fields = line.split(None, 8)
        if len(fields) == 9:
            pid, ppid, pgid = map(int, fields[:3])
            result[pid] = dict(pid=pid, ppid=ppid, pgid=pgid, start=" ".join(fields[3:8]), command=fields[8])
    return result


def conflicts(rows):
    found = []
    for item in rows.values():
        executable = Path(item["command"].split()[0]).name
        if executable in ("zsh", "bash", "sh", "rg", "ps"):
            continue
        args = item["command"]
        if (executable in ("zig", "wrk", "wrk2", "bounded-http", "baz", "baz-streaming", "streaming")
                or re.search(r"python[^ ]* .*?(tests/\S*integration\.py|tools/(smoke|benchmark)\.py|run-site-qa\.py)", args)
                or "--headless" in args):
            found.append(item)
    return found


def gather_owned(rows, root_pid, owned):
    roots = {root_pid}
    roots.update(pid for pid, item in owned.items() if pid in rows and rows[pid]["start"] == item["start"])
    while True:
        children = {pid for pid, row in rows.items() if row["ppid"] in roots}
        if children <= roots:
            break
        roots.update(children)
    for pid in roots:
        if pid in rows:
            owned[pid] = rows[pid]


def cleanup_owned(owned):
    signals = []
    for number in (signal.SIGTERM, signal.SIGKILL):
        rows = processes()
        live = [row for pid, row in owned.items() if pid in rows and rows[pid]["start"] == row["start"]]
        for row in reversed(live):
            with contextlib.suppress(ProcessLookupError):
                os.kill(row["pid"], number)
                signals.append(dict(pid=row["pid"], signal=number.name))
        if live:
            time.sleep(0.25)
    rows = processes()
    remaining = [row for pid, row in owned.items() if pid in rows and rows[pid]["start"] == row["start"]]
    return dict(signals=signals, remaining=remaining)


def stage(name, args, watchdog):
    started = now()
    clock_start = time.monotonic()
    owned = {}
    timeout = False
    interrupted = None
    with (OUT / (name + ".log")).open("wb") as log:
        child = subprocess.Popen(args, cwd=ENGINE, stdin=subprocess.DEVNULL, stdout=log,
                                 stderr=subprocess.STDOUT, start_new_session=True)
        try:
            while child.poll() is None:
                gather_owned(processes(), child.pid, owned)
                if time.monotonic() - clock_start > watchdog:
                    timeout = True
                    break
                time.sleep(0.1)
        except BaseException as error:
            interrupted = repr(error)
        finally:
            gather_owned(processes(), child.pid, owned)
            cleanup = cleanup_owned(owned)
            code = child.wait(timeout=3)
    item = dict(name=name, command=args, started_utc=started, ended_utc=now(), exit_code=code,
                watchdog_seconds=watchdog, timed_out=timeout, interrupted=interrupted,
                owned_processes=list(owned.values()), cleanup=cleanup)
    write(name + "-processes.json", item)
    print(json.dumps(dict(stage=name, exit_code=code, timed_out=timeout, remaining=cleanup["remaining"])), flush=True)
    if code != 0 or timeout or interrupted or cleanup["remaining"]:
        raise RuntimeError("native stage failed: " + name)
    return item


def source():
    names = subprocess.check_output(["git", "ls-files", "-z"], cwd=ENGINE).decode().split("\0")
    files = [name for name in names if name and
             (name.startswith(("src/", "tests/", "tools/", "assets/")) or name in ("build.zig", "build.zig.zon", ".zig-version"))]
    return dict(repository_commit=command(["git", "rev-parse", "HEAD"]),
                repository_status=command(["git", "status", "--porcelain=v1"]),
                files={name: digest(ENGINE / name) for name in sorted(files)},
                binary=str(BINARY), binary_sha256=digest(BINARY))


OUT.mkdir(parents=True, exist_ok=True)
def interrupt(number, frame):
    raise RuntimeError("native supervisor interrupted by signal " + str(number))
signal.signal(signal.SIGTERM, interrupt)
before = conflicts(processes())
write("preexisting-processes.json", dict(checked_utc=now(), conflicts=before))
if before:
    raise SystemExit("Existing measurement processes require coordination")
LOCK.mkdir()
owner = dict(agent="/root/stream_wire", purpose="bounded/http ReleaseSafe native macOS regression and 30000-response correctness smoke",
             host=platform.node(), started_utc=now(), owner_pid=os.getpid(), token=TOKEN, cwd=str(ENGINE))
(LOCK / "owner.json").write_text(json.dumps(owner, indent=2) + "\n")
write("reservation.json", owner)
print("RESERVED " + TOKEN, flush=True)
stages = []
receipt = dict(ok=False, started_utc=now(), stages=stages, classification="native correctness regression; no performance comparison")
try:
    snapshot = source()
    if snapshot["repository_commit"] != "2a269ef57301b21df22f1c616d02d6d244e5d6ca":
        raise RuntimeError("unexpected engine candidate")
    write("source.json", snapshot)
    write("environment.json", dict(platform=platform.platform(), uname=list(platform.uname()),
                                   python=sys.version, zig=command(["/Users/rs/bin/zig", "version"]),
                                   cpu=command(["sysctl", "-n", "machdep.cpu.brand_string"]),
                                   memory_bytes=command(["sysctl", "-n", "hw.memsize"])))
    probe = OUT / "probe.py"
    probe.write_text('import json, sys\nfrom pathlib import Path\nsys.path.insert(0, ' + repr(str(ENGINE / "tests")) + ')\nimport integration as wire\n'
                     'with wire.Server(Path(' + repr(str(BINARY)) + ')) as server:\n'
                     '    ready = next(line for line in server.lines if line.startswith("READY "))\n'
                     '    wire.require("optimize=ReleaseSafe" in ready, "ReleaseSafe required")\n'
                     '    wire.plaintext(server)\n'
                     'Path(' + repr(str(OUT / "readiness.json")) + ').write_text(json.dumps(dict(ready=ready, stats=server.stats), indent=2) + "\\n")\n')
    stages.append(stage("readiness", [sys.executable, str(probe)], 25))
    stages.append(stage("comparator", [sys.executable, "-m", "unittest", "discover", "-s", "tests", "-p", "test_compare.py", "-v"], 30))
    for name, limit in (("arena_lifecycle", 90), ("batch", 120), ("gather", 120), ("inline", 45), ("integration", 90)):
        filename = "tests/integration.py" if name == "integration" else "tests/" + name + "_integration.py"
        stages.append(stage(name, [sys.executable, filename, "--server", str(BINARY), "--timeout", str(limit),
                                   "--json", str(OUT / (name + ".json"))], limit + 20))
    stages.append(stage("smoke", [sys.executable, "tools/smoke.py", "--server", str(BINARY), "--requests", "10000",
                                   "--timeout", "150", "--json", str(OUT / "smoke.json")], 170))
    final_source = source()
    write("source-after.json", final_source)
    if snapshot["files"] != final_source["files"] or snapshot["binary_sha256"] != final_source["binary_sha256"]:
        raise RuntimeError("source or binary changed during the gates")
    validations = {}
    for name in ("arena_lifecycle", "batch", "gather", "inline", "integration", "smoke"):
        value = json.loads((OUT / (name + ".json")).read_text())
        if value.get("ok") is not True:
            raise RuntimeError("unsuccessful receipt: " + name)
        sessions = value.get("sessions", [])
        if name == "smoke":
            sessions = [value["server"]]
        for session in sessions:
            stats = session["stats"]
            if any(stats[key] != 0 for key in ("live_connections", "live_operations", "allocation_calls_after_start")):
                raise RuntimeError("nonzero terminal ownership: " + name)
        validations[name] = dict(passed=value.get("passed"), sessions=len(sessions))
    receipt.update(ok=True, validations=validations)
except BaseException as error:
    receipt["error"] = repr(error)
    raise
finally:
    remaining = conflicts(processes())
    receipt.update(ended_utc=now(), remaining_processes=remaining)
    lock_owner = json.loads((LOCK / "owner.json").read_text())
    if lock_owner.get("token") != TOKEN:
        raise RuntimeError("reservation ownership changed")
    if remaining:
        write("run.json", receipt)
        raise RuntimeError("workload processes remain; reservation retained")
    (LOCK / "owner.json").unlink()
    LOCK.rmdir()
    receipt["reservation_released"] = True
    write("run.json", receipt)
    print("RELEASED " + TOKEN, flush=True)
