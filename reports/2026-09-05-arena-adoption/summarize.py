#!/usr/bin/env python3
"""Read-only verification of the frozen arena adoption evidence.

Run from any directory: python3 /path/to/summarize.py [--json].
No extraction, workloads, subprocesses, network access or writes are performed.
"""
import hashlib
import io
import json
import math
from pathlib import Path, PurePosixPath
import random
import re
import statistics
import sys
import tarfile

ROOT = Path(__file__).resolve().parent
COMMIT = "bbcec8aa9516efc470238b9edeea4f01b1f4a6d7"
SERVERS = ("zig-http", "libreactor")
ERRORS = ("connect_errors", "read_errors", "write_errors", "status_errors", "timeout_errors")
ZERO_OWNERS = ("allocation_calls_after_start", "live_connections", "live_operations")
SUITES = {"arena_lifecycle": 8, "batch": 29, "gather": 11, "inline": 10, "generic": 26}
BINARY_HASHES = {
    "zig-http": "7305b3e2edb99a30c434a9793c18dcddfdacea923d1e7a30ff4736bc177553e3",
    "wrk": "c8000cec3cb25e87292c983828ecfcfd4108ce39d2bb01b9cd313f17dcf290af",
    "libreactor": "8d55f6ddbc87b3e53de7eab97d843d8ea8d97d2eb5bf8c602849bf493b0056aa",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def distribution(values):
    require(bool(values), "empty distribution")
    return {"n": len(values), "median": statistics.median(values), "min": min(values), "max": max(values)}


def option(argv, key):
    require(argv.count(key) == 1, "missing or duplicate option: " + key)
    return argv[argv.index(key) + 1]


def archive_members(data, canonical=False):
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as archive:
        entries = archive.getmembers()
        if canonical:
            require(all(e.isfile() for e in entries), "non-file evidence member")
            require([e.name for e in entries] == sorted(e.name for e in entries), "archive order")
            require(all((e.uid, e.gid, e.mtime, e.mode, e.uname, e.gname) == (0, 0, 0, 0o644, "", "") for e in entries), "archive metadata")
        entries = [e for e in entries if e.isfile()]
        require(len(entries) == len({e.name for e in entries}), "duplicate archive member")
        require(all(not PurePosixPath(e.name).is_absolute() and ".." not in PurePosixPath(e.name).parts for e in entries), "unsafe archive path")
        return {e.name: archive.extractfile(e).read() for e in entries}


def json_records(log, marker=""):
    return [json.loads(line[len(marker):]) for line in log.splitlines()
            if line.startswith(marker + "{")]


def verify_suite(receipt, expected, platform):
    require(receipt["ok"] and receipt["passed"] == expected and receipt["platform"] == platform, "native suite outcome")
    require(len(receipt["tests"]) == expected and all(t["ok"] for t in receipt["tests"]), "native test count")
    for session in receipt.get("sessions", []):
        stats = session.get("stats")
        if stats:
            require(all(stats[key] == 0 for key in ZERO_OWNERS), "native suite retained owners")


def verify_smoke(receipt):
    require(receipt["ok"] and receipt["build"]["zig_target"] == "0.16.0" and receipt["build"]["optimize"] == "ReleaseSafe", "smoke build")
    require(len(receipt["workloads"]) == 3, "smoke workload count")
    for workload in receipt["workloads"]:
        require(workload["exit_code"] == 0 and workload["result"]["ok"] and not workload["result"]["errors"], "smoke failure")
        require(workload["result"]["completed"] == workload["result"]["requested"] == 10000, "smoke response count")
        require(workload["result"]["body_validation"] == "exact expected bytes", "smoke body validation")
    stats = receipt["server"]["stats"]
    require(stats["completed"] == 30000 and all(stats[key] == 0 for key in ZERO_OWNERS), "smoke owners/count")
    return {"responses": 30000, "environment": receipt["environment"], "build": receipt["build"]}


def verify_gates(members):
    mac_gates = {}
    for scope in ("clean", "development"):
        mac = "macos-" + scope + "/"
        commands = json.loads(members[mac + "receipt.json"])
        require(all(c["exit_code"] == 0 for c in commands["commands"]), "macOS commands")
        for mode in ("debug", "release-safe"):
            require("Build Summary: 14/14 steps succeeded; 67/69 tests passed (2 skipped)" in members[mac + mode + ".log"].decode(), "macOS unit gate")
        require(re.search(r"Ran 8 tests\s+.*?\bOK\b", members[mac + "comparator.log"].decode(), re.S), "macOS comparator gate")
        for name, count in SUITES.items():
            receipt = json.loads(members[mac + name + ".json"])
            verify_suite(receipt, count, "darwin")
            require(receipt in json_records(members[mac + name + ".log"].decode()), "macOS raw wire receipt")
        smoke = verify_smoke(json.loads(members[mac + "smoke.json"]))
        require(smoke["build"]["repository_commit"] == commands["commit"], "macOS gate identity")
        if scope == "clean":
            require(commands["commit"] == COMMIT and not smoke["build"]["repository_status"].strip(), "macOS clean source")
        else:
            require(smoke["build"]["repository_status"].strip(), "macOS development status")
        mac_gates[scope] = {"scope": "clean detached bbcec8a native gate" if scope == "clean" else "historical development working tree; dirty d5b6d9b base, no independent source snapshot; not exact-commit evidence", "unit_tests_each_mode": {"passed": 67, "total": 69, "skipped": 2}, "skip_scope": "Linux-only multi-shard fixtures", "wire_cases": 84, "comparator_cases": 8, "smoke": smoke}
    linux_log = members["linux/publication-gates.log"].decode()
    require(linux_log.startswith("checkout_commit=" + COMMIT + " "), "Linux gate source identity")
    require(linux_log.count("Build Summary: 14/14 steps succeeded; 69/69 tests passed") == 2, "Linux Debug/ReleaseSafe unit gates")
    require("zig=0.16.0 io_uring_disabled=0" in linux_log and re.search(r"Ran 8 tests\s+.*?\bOK\b", linux_log, re.S), "Linux compiler/comparator gate")
    records = json_records(linux_log)
    linux_suites = [r for r in records if "passed" in r]
    require(sorted(r["passed"] for r in linux_suites) == sorted(SUITES.values()), "Linux wire suite set")
    for receipt in linux_suites:
        verify_suite(receipt, receipt["passed"], "linux")
    smoke_records = [r for r in records if r.get("tool") == "zig-http-smoke-suite"]
    require(len(smoke_records) == 1, "Linux smoke count")
    linux_smoke = verify_smoke(smoke_records[0])
    return {
        "macos": mac_gates,
        "linux": {"scope": "clean bbcec8a input streamed for native gates; measured source captured separately before documentation edits", "commit": COMMIT, "unit_tests_each_mode": {"passed": 69, "total": 69, "skipped": 0}, "wire_cases": 84, "comparator_cases": 8, "smoke": linux_smoke},
    }


def verify_wrk(trial, members, prefix):
    for suffix, phase in (("wrk", "result"), ("warmup", "warmup")):
        records = json_records(members[prefix + "-" + suffix + ".log"].decode(), "RESULT ")
        require(len(records) == 1, "missing/ambiguous raw RESULT")
        result = records[0]
        require(all(trial[phase][key] == value for key, value in result.items()), "raw RESULT differs from receipt")
        require(result["requests"] > 0 and result["duration_us"] > 0, "empty measured load")
        require(trial[phase]["ok"] and all(result[key] == 0 for key in ERRORS), "wrk load errors")
        require(trial[phase]["responses_per_second"] == result["requests"] * 1e6 / result["duration_us"], "rate arithmetic")
        sane = 0 < result["latency_p50_us"] <= result["latency_p99_us"] <= result["latency_max_us"]
        require(trial[phase]["latency_percentiles_sane"] == sane, "latency sanity flag")


def verify_zig(trial, cpus):
    log, stats = trial["server_log"], trial["stats"]
    require(trial["server_exit"] == 0 and json_records(log, "STATS ") == [stats], "raw Zig STATS/exit")
    ready = [line for line in log.splitlines() if line.startswith("READY ")]
    require(len(ready) == 1, "READY count")
    for item in ("connections=128", "workers=0", "execution=inline_event_loop", "gather_send=1", "response_batch_limit=128", "callbacks_per_turn=8192", "optimize=ReleaseSafe", "shards=" + str(cpus)):
        require(item in ready[0].split(), "READY field: " + item)
    require(stats["shards"] == cpus and stats["response_batch_limit"] == 128 and stats["callbacks_per_turn"] == 8192, "actual shards/B/Q")
    require(stats["max_batch_responses"] <= 128 and stats["max_inline_callbacks_per_turn"] <= 8192, "B/Q observed bound")
    require(stats["execution"] == "inline_event_loop" and stats["gather_send"], "execution mode")
    require(0 < stats["framework_heap_peak_bytes"] <= stats["framework_heap_limit_bytes"], "heap reservation")
    require(stats["peak_connections"] <= 128 and stats["peak_operations"] <= cpus * (4 * 128 + 2), "ownership peak")
    for key in ZERO_OWNERS + ("rejected", "timeouts", "workers", "worker_dispatches", "prearmed_receives", "scalar_send_operations"):
        require(stats[key] == 0, "unexpected measured Zig counter: " + key)
    shards = [line for line in log.splitlines() if line.startswith("SHARDS ")]
    if cpus == 1:
        require(not shards, "unexpected multi-shard record")
    else:
        require(len(shards) == 1, "missing SHARDS record")
        counts = re.findall(r" accepted=(\d+)/completed=(\d+)", shards[0])
        require(len(counts) == cpus, "SHARDS count")
        require(sum(int(a) for a, _ in counts) == stats["accepted"] and sum(int(c) for _, c in counts) == stats["completed"], "SHARDS sum differs")
    require(len(trial["server_threads"]) == cpus, "actual Zig I/O thread count")


def summarize():
    encoded = (ROOT / "evidence.tar.gz").read_bytes()
    require(encoded[:2] == b"\x1f\x8b" and encoded[4:8] == b"\0\0\0\0", "gzip timestamp")
    members = archive_members(encoded, canonical=True)
    identity = json.loads(members["linux/identity.json"])
    source_bytes = members["linux/source.tar"]
    source = archive_members(source_bytes)
    require(source[".zig-version"].strip() == b"0.16.0", "pinned Zig version")
    require(identity["commit"] == COMMIT and identity["source_archive_sha256"] == digest(source_bytes), "source archive identity")
    require(digest(source_bytes) == "0bebb6b0298f3ca8c32fd9881a450008fa0f518fbfa31ec5aa5712eacf06329e", "pinned source archive")
    require(identity["compiler_sha256"] == "2317bbb91798556d9d0f38aabdac23db83f0979b25f767259ae474546724087c", "pinned Linux compiler")
    require(identity["all_builds_finished_before_timings"], "build/timing ordering")
    require({Path(path).name: value for path, value in identity["binaries"].items()} == BINARY_HASHES, "binary identities")
    require(identity["pins"]["zig_version"] == "0.16.0", "compiler baseline")
    reference = json.loads(members["linux/preparation-reference.json"])
    require(identity["pins"] == reference["pins"] and reference["source_archive_sha256"] == digest(source_bytes), "pinned preparation identity")
    for path, value in reference["binaries"].items():
        require(BINARY_HASHES[Path(path).name] == value, "pinned contender binary")
    outer = json.loads(members["linux/receipt.json"])
    lock = json.loads(members["linux/lock.json"])
    require(outer["reconstructed_after_local_extraction_error"] and outer["original_controller_exit"] == 1, "outer controller reconstruction")
    require(outer["publication_native_gates_passed"] and not outer["input_status_before_publication_stream"].strip(), "clean native input")
    require(outer["source_commit"] == COMMIT and outer["identity"] == identity, "outer source identity")
    release = json.loads(members["linux/release.json"])
    recovery = json.loads(members["linux/extraction-recovery.json"])
    require(outer["release"] == release and outer["extraction_recovery"] == recovery, "recovery record copies")
    require(lock["status"] == "acquired" and release["owner"] == lock["owner"], "reservation identity")
    require(release["status"] == "released" and not release["owned_processes_remaining"] and release["original_keeper_absent"], "recovered owner cleanup")
    require(release["original_keeper_expected_start_ticks"] == lock["owner"]["owner_start_ticks"], "keeper PID reuse protection")
    require(outer["no_benchmark_retry"] and not recovery["benchmarks_rerun"] and recovery["initial_controller_exit"] == 1, "recovery reran measurements")
    require(recovery["initial_failure"] in members["linux/extraction-failure.log"].decode().replace("'", ""), "extraction failure evidence")
    remote_bytes = members["linux/raw-remote.tar.gz"]
    require(digest(remote_bytes) == outer["artifact_sha256"], "transport archive digest")
    remote = archive_members(remote_bytes)
    require(all(members["linux/" + name] == data for name, data in remote.items()), "transport archive differs from expanded files")
    captured = json.loads(members["linux/input-captured.json"])
    require(captured["commit"] == COMMIT and captured["publication_gates_passed"] and captured["source_archive_sha256"] == digest(source_bytes), "captured clean gate/source")
    controller = json.loads(members["linux/qualified/timing-controller.json"])
    require(controller == outer["timing_controller"], "original timing receipt copy")
    require(controller["ok"] and len(controller["commands"]) == 2 and len(controller["validations"]) == 2, "timing controller")
    require(all(c["returncode"] == 0 for c in controller["commands"]) and all(v["ok"] and v["trials"] == 18 and v["zig_trials"] == 9 for v in controller["validations"]), "controller validation")
    require(json.loads(members["linux/qualified/identity.json"]) == identity, "remote identity copy")
    gates = verify_gates(members)
    all_trials, rows, endpoints, receipts = [], [], [], {}
    for cpus in (1, 3):
        prefix = f"linux/qualified/{cpus}cpu/"
        receipt = json.loads(members[prefix + "results.json"])
        config_data = members[f"linux/configuration-{cpus}cpu.json"]
        config = json.loads(config_data)
        receipts[str(cpus)] = receipt
        require(members[f"linux/qualified/configuration-{cpus}cpu.json"] == config_data, "remote configuration bytes")
        require(receipt["ok"] and receipt["configuration"] == config and digest(config_data) == receipt["configuration_sha256"], "receipt/configuration/hash")
        require(config["implementation_commit"] == COMMIT and tuple(s["name"] for s in config["servers"]) == SERVERS, "source/contender identity")
        require(config["server_cpus"] == list(range(cpus)) and config["client_cpus"] == [3, 4, 5, 6, 7], "CPU budgets")
        require(config["expected_power_profile"] == "performance", "power requirement")
        require(receipt["harness_sha256"] == digest(source["tools/compare.py"]) and receipt["lua_sha256"] == digest(source["benchmarks/pipeline.lua"]), "harness/Lua source")
        require(receipt["wrk_sha256"] == BINARY_HASHES["wrk"], "wrk receipt identity")
        require(receipt["ordering"] == "shuffled" and receipt["repeats"] == receipt["samples_per_configuration"] == 3, "sample metadata")
        require(receipt["connections"] == [128] and receipt["pipeline_depths"] == [1, 16, 128] and receipt["duration_seconds"] == 5 and receipt["threads"] == 4 and receipt["seed"] == 20260905, "workload parameters")
        require(receipt["environment"]["io_uring_disabled"] == "0", "io_uring environment")
        jobs = [(rep, 128, depth, server) for rep in range(3) for depth in (1, 16, 128) for server in SERVERS]
        random.Random(receipt["seed"]).shuffle(jobs)
        trials = receipt["trials"]
        require(len(trials) == 18 and [(t["repeat"], t["connections"], t["pipeline"], t["server"]) for t in trials] == jobs, "shuffled trial count/order")
        for index, trial in enumerate(trials):
            require(trial["index"] == index and trial["client_exit"] == 0, "trial index/client exit")
            server = next(s for s in config["servers"] if s["name"] == trial["server"])
            require(server["body"] == "Hello, World!" and server["command"][0] in identity["binaries"], "server binary/body")
            require(trial["server_command"] == ["taskset", "-c", ",".join(map(str, range(cpus)))] + server["command"], "actual server command")
            require(trial["client_command"][:4] == ["taskset", "-c", "3,4,5,6,7", config["wrk"]], "actual client affinity/binary")
            for key, expected in (("-c", "128"), ("-t", "4"), ("-d", "5s"), ("--timeout", "2s")):
                require(option(trial["client_command"][4:], key) == expected, "actual client option: " + key)
            require(trial["client_command"][-2:] == ["--", str(trial["pipeline"])], "actual pipeline depth")
            path = prefix + f"{index:03d}-{trial['server']}-c128-p{trial['pipeline']}"
            verify_wrk(trial, members, path)
            require(members[path + "-server.log"].decode() == trial["server_log"], "raw server log differs")
            require(trial["stable_thread_set"] and all(t["last_cpu"] in range(cpus) for t in trial["server_threads"]), "observed thread set/CPUs")
            require(math.isclose(trial["server_cpu_percent"], sum(t["cpu_percent"] for t in trial["server_threads"]), rel_tol=1e-12, abs_tol=1e-10) and math.isclose(trial["client_cpu_percent"], trial["client_cpu_seconds"] / trial["elapsed_seconds"] * 100, rel_tol=1e-12, abs_tol=1e-10), "CPU arithmetic")
            require(len(trial["server_threads"]) == (cpus if trial["server"] == "zig-http" else cpus + 1), "observed threads/processes including libreactor parent")
            if trial["server"] == "zig-http":
                for key, expected in (("--connections", "128"), ("--execution", "inline"), ("--workers", "0")):
                    require(option(server["command"], key) == expected, "Zig option: " + key)
                verify_zig(trial, cpus)
            else:
                require(trial["server_exit"] in (0, -15) and "stats" not in trial, "contender exit/metrics")
            preflight = trial["preflight"]
            require(preflight["validated_responses"] == 2 * max(16, trial["pipeline"]) and preflight["pipeline_depth"] == max(16, trial["pipeline"]), "preflight count/depth")
            require(preflight["exact_body"] == "Hello, World!" and preflight["first_date"] != preflight["last_date"], "preflight bytes/Date")
            endpoints.extend((trial["power_before"], trial["power_after"]))
        for depth in (1, 16, 128):
            row = {"server_cpus": list(range(cpus)), "client_cpus": [3, 4, 5, 6, 7], "active_clients": 128, "pipeline": depth, "servers": {}}
            for name in SERVERS:
                group = [t for t in trials if t["pipeline"] == depth and t["server"] == name]
                require(len(group) == 3, "group sample count")
                item = {"trial_indices": [t["index"] for t in group], "responses_per_second": distribution([t["result"]["responses_per_second"] for t in group]), "server_cpu_percent": distribution([t["server_cpu_percent"] for t in group]), "client_cpu_percent": distribution([t["client_cpu_percent"] for t in group]), "rss_kib": distribution([sum(t["resident_kib_by_pid"].values()) for t in group]), "observed_threads_including_idle_parent": sorted({len(t["server_threads"]) for t in group}), "serving_contexts": cpus}
                if name == "zig-http":
                    item["counter_ranges"] = {key: distribution([t["stats"][key] for t in group]) for key in ("framework_heap_peak_bytes", "framework_heap_limit_bytes", "max_batch_responses", "max_inline_callbacks_per_turn", "max_send_parts", "max_send_bytes", "borrow_copies", "pipeline_copy_bytes", "peak_connections", "peak_operations")}
                row["servers"][name] = item
            row["zig_to_libreactor_ratio_of_medians"] = row["servers"]["zig-http"]["responses_per_second"]["median"] / row["servers"]["libreactor"]["responses_per_second"]["median"]
            rows.append(row)
        all_trials.extend(trials)
    require(all(p["profile"] == "performance" and p["profile_error"] is None for p in endpoints), "performance endpoint")
    cpu_endpoints = [cpu for p in endpoints for cpu in p["cpus"].values()]
    require(len(cpu_endpoints) == 72 * 8 and all(c["energy_performance_preference"] == "performance" for c in cpu_endpoints), "EPP endpoint observations")
    summary = {
        "schema_version": 1, "implementation_commit": COMMIT,
        "artifact_recovery": {"original_controller_exit": 1, "timing_controller_ok": True, "benchmarks_rerun": False, "failure": recovery["initial_failure"], "release_utc": release["released_utc"], "owned_processes_remaining": []},
        "timed_trials": 36, "warmups": 36, "raw_logs_verified": 108,
        "timing_intervals": {key: {field: r[field] for field in ("started_utc", "finished_utc")} for key, r in receipts.items()},
        "measured_responses": sum(t["result"]["requests"] for t in all_trials),
        "warmup_responses": sum(t["warmup"]["requests"] for t in all_trials),
        "exact_preflight_responses": sum(t["preflight"]["validated_responses"] for t in all_trials),
        "load_errors": {key: sum(t[phase][key] for t in all_trials for phase in ("result", "warmup")) for key in ERRORS},
        "zig_zero_counters": {key: sum(t["stats"][key] for t in all_trials if t["server"] == "zig-http") for key in ZERO_OWNERS + ("rejected", "timeouts")},
        "power_endpoints": {"count": 72, "cpu_observations": len(cpu_endpoints), "profile": "performance", "drivers": sorted({p["scaling_driver"] for p in cpu_endpoints}), "governors": sorted({p["scaling_governor"] for p in cpu_endpoints}), "epp": sorted({p["energy_performance_preference"] for p in cpu_endpoints})},
        "latency_sanity": {phase: {str(depth): {"sane": sum(t[phase]["latency_percentiles_sane"] for t in all_trials if t["pipeline"] == depth), "trials": 12} for depth in (1, 16, 128)} for phase in ("result", "warmup")},
        "limitations": ["IPv4 loopback closed-loop controlled comparisons, not official TechEmpower rankings or production capacity.", "wrk corrected completed-batch histogram has a pinned validity defect; raw percentiles do not establish per-response, open-loop or SLO tail latency.", "Five-second samples and endpoint CPU/power observations do not establish workload stationarity, a client limit, parser cost attribution, or CPU residency.", "Framework requested heap excludes kernel storage, allocator metadata, requested thread stacks, assets and unrelated application allocations; RSS is a separate observation.", "Authoritative macOS and Linux native gates use bbcec8a; older macOS development receipts remain separately labeled history. Final publication gates are recorded separately by the parent."],
        "gates": gates, "rows": rows,
    }
    return summary, {name: digest(data) for name, data in sorted(members.items())}, {name: digest(data) for name, data in sorted(source.items()) if name.startswith(("src/", "tests/", "tools/")) or name in (".zig-version", "build.zig", "build.zig.zon", "benchmarks/pipeline.lua")}


def main():
    require(sys.argv[1:] in ([], ["--json"]), "usage: summarize.py [--json]")
    packet = json.loads((ROOT / "packet.json").read_text())
    for name, expected in packet["artifact_sha256"].items():
        require(digest((ROOT / name).read_bytes()) == expected, "artifact hash: " + name)
    summary, members, source = summarize()
    require(summary == packet["summary"] and members == packet["archive_member_sha256"] and source == packet["measured_source_sha256"], "derived summary/manifests differ")
    print(json.dumps(summary, indent=2, sort_keys=True) if "--json" in sys.argv else "Verified 36 trials, 36 warmups, 108 raw logs, native gates, source/binary hashes, sample order, CPU/shard/B/Q bounds, zero late/live owners and all derived summaries.")


if __name__ == "__main__":
    main()
