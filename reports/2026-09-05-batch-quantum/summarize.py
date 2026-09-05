#!/usr/bin/env python3
"""Reproduce and verify this frozen matrix without workloads, network or writes.

Usage: python3 reports/2026-09-05-batch-quantum/summarize.py [--json]
"""
import hashlib
import json
from pathlib import Path
import random
import statistics
import sys
import tarfile

ROOT = Path(__file__).resolve().parent
COMMIT = "dbb639859e4c8503310933a2e53f0aaf45e2fca0"
SERVERS = ("b16-q64", "b16-q256", "b64-q64", "b64-q256")
ERRORS = ("connect_errors", "read_errors", "write_errors", "status_errors", "timeout_errors")
HEAP = {16: 31_100_880, 64: 59_805_648}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def distribution(values):
    return {"n": len(values), "median": statistics.median(values), "min": min(values), "max": max(values)}


def option(argv, key):
    require(argv.count(key) == 1, "missing or duplicate option: " + key)
    return argv[argv.index(key) + 1]


def summarize():
    with tarfile.open(ROOT / "timed-logs.tar.gz", "r:gz") as archive:
        entries = [entry for entry in archive.getmembers() if entry.isfile()]
        require(len(entries) == len({entry.name for entry in entries}), "duplicate archive names")
        members = {entry.name: archive.extractfile(entry).read() for entry in entries}
    receipt = json.loads((ROOT / "results.json").read_text())
    config = json.loads((ROOT / "configuration.json").read_text())
    controller = json.loads((ROOT / "controller.json").read_text())
    lock = json.loads((ROOT / "lock.json").read_text())
    require(controller["ok"] and controller["lock_released"], "controller failure")
    require(not controller["preexisting_workloads"] and not controller["remaining_owned_processes"], "controller ownership")
    require(controller["owner"] == lock and len(controller["commands"]) == 1 and controller["commands"][0]["exit"] == 0, "controller identity/command")
    require(controller["binary_sha256"] == json.loads((ROOT / "hashes.json").read_text()), "binary manifest")
    require(controller["binary_sha256"]["batchq/zig-out/bin/zig-http"] == "be0d15486773cd986dcc31a44d85fa44feb559751f911f9ef1f4769a6b2716a0", "server binary identity")
    require(receipt["wrk_sha256"] == controller["binary_sha256"]["bin/wrk"], "client binary identity")
    require(receipt["ok"] and receipt["configuration"] == config, "receipt/configuration")
    require(config["implementation_commit"] == COMMIT, "source commit")
    require(digest((ROOT / "configuration.json").read_bytes()) == receipt["configuration_sha256"], "configuration hash")
    require(digest(members["source/tools/compare.py"]) == receipt["harness_sha256"], "harness hash")
    require(digest(members["source/benchmarks/pipeline.lua"]) == receipt["lua_sha256"], "Lua hash")
    require(config["server_cpus"] == [0] and config["client_cpus"] == [3, 4, 5, 6, 7], "affinity")
    require(receipt["ordering"] == "shuffled" and receipt["repeats"] == receipt["samples_per_configuration"] == 3, "repeat metadata")
    require(receipt["connections"] == [128] and receipt["pipeline_depths"] == [16, 128], "workload")
    require(receipt["duration_seconds"] == 5 and receipt["threads"] == 4 and receipt["seed"] == 20260905, "load parameters")
    require(tuple(server["name"] for server in config["servers"]) == SERVERS, "configuration order")
    for server in config["servers"]:
        batch, quantum = [int(value[1:]) for value in server["name"].split("-")]
        require(server["source_commit"] == COMMIT, "contender source")
        require(server["configured_batch"] == batch and server["configured_callback_budget"] == quantum, "configuration bounds")
        require(server["command"][0] == "/tmp/zig-http-compare.PIwh35/batchq/zig-out/bin/zig-http", "same executable")
        for key, expected in (("--connections", "128"), ("--workers", "0"), ("--execution", "inline"), ("--gather-send", "1"), ("--response-batch-limit", str(batch)), ("--inline-callback-budget", str(quantum))):
            require(option(server["command"], key) == expected, "configured option: " + key)
    trials = receipt["trials"]
    jobs = [(rep, 128, depth, name) for rep in range(3) for depth in (16, 128) for name in SERVERS]
    random.Random(receipt["seed"]).shuffle(jobs)
    require(len(trials) == 24 and [(t["repeat"], t["connections"], t["pipeline"], t["server"]) for t in trials] == jobs, "shuffled trial identities/order")
    endpoints = []
    for index, trial in enumerate(trials):
        require(trial["index"] == index and trial["server_exit"] == trial["client_exit"] == 0, "trial exit/index")
        server = next(s for s in config["servers"] if s["name"] == trial["server"])
        require(trial["server_command"] == ["taskset", "-c", "0"] + server["command"], "actual server command")
        require(trial["client_command"][:3] == ["taskset", "-c", "3,4,5,6,7"], "client affinity")
        for key, expected in (("-c", "128"), ("-t", "4"), ("-d", "5s"), ("--timeout", "2s")):
            require(option(trial["client_command"][3:], key) == expected, "client load option: " + key)
        require(trial["client_command"][-2:] == ["--", str(trial["pipeline"])], "actual pipeline depth")
        batch, quantum = server["configured_batch"], server["configured_callback_budget"]
        prefix = f"raw/{index:03d}-{trial['server']}-c128-p{trial['pipeline']}"
        for suffix, phase in (("wrk", "result"), ("warmup", "warmup")):
            log = members[prefix + f"-{suffix}.log"].decode()
            records = [json.loads(line[7:]) for line in log.splitlines() if line.startswith("RESULT ")]
            require(len(records) == 1, "ambiguous raw RESULT")
            result = records[0]
            require(all(trial[phase][k] == v for k, v in result.items()), "raw RESULT differs")
            require(result["requests"] > 0 and result["duration_us"] > 0, "empty workload")
            require(trial[phase]["ok"] and all(result[k] == 0 for k in ERRORS), "workload errors")
            require(trial[phase]["responses_per_second"] == result["requests"] * 1e6 / result["duration_us"], "rate calculation")
            sane = 0 < result["latency_p50_us"] <= result["latency_p99_us"] <= result["latency_max_us"]
            require(trial[phase]["latency_percentiles_sane"] == sane, "latency sanity flag")
        log = members[prefix + "-server.log"].decode()
        require(log == trial["server_log"], "raw server log differs")
        require([json.loads(line[6:]) for line in log.splitlines() if line.startswith("STATS ")] == [trial["stats"]], "raw STATS differs")
        ready = [line for line in log.splitlines() if line.startswith("READY ")]
        require(len(ready) == 1, "READY marker count")
        for value in ("connections=128", "workers=0", "execution=inline_event_loop", "gather_send=1", "optimize=ReleaseSafe", f"response_batch_limit={batch}", f"inline_callback_budget={quantum}"):
            require(value in ready[0].split(), "READY option: " + value)
        stats = trial["stats"]
        require(stats["response_batch_limit"] == batch and stats["inline_callback_budget"] == quantum, "observed configuration")
        require(stats["max_batch_responses"] <= batch and stats["max_inline_callbacks_per_turn"] <= quantum, "observed bound violation")
        require(stats["max_send_parts"] <= batch * 5 and stats["framework_heap_peak_bytes"] == HEAP[batch], "vector/heap bounds")
        require(stats["execution"] == "inline_event_loop" and stats["gather_send"], "execution mode")
        for key in ("workers", "worker_dispatches", "allocation_calls_after_start", "live_connections", "live_operations", "rejected", "timeouts", "scalar_send_operations"):
            require(stats[key] == 0, "unexpected counter: " + key)
        require(stats["peak_connections"] == 128 and stats["peak_operations"] <= 258, "ownership bounds")
        require(trial["stable_thread_set"] and len(trial["server_threads"]) == 1 and trial["server_threads"][0]["last_cpu"] == 0, "server thread/CPU")
        preflight = trial["preflight"]
        require(preflight["validated_responses"] == 2 * trial["pipeline"] and preflight["pipeline_depth"] == trial["pipeline"], "preflight count/depth")
        require(preflight["exact_body"] == "Hello, World!" and preflight["first_date"] != preflight["last_date"], "preflight body/date")
        endpoints.extend((trial["power_before"], trial["power_after"]))
    require(all(p["profile"] == "performance" and p["profile_error"] is None for p in endpoints), "power endpoint")
    cpus = [cpu for endpoint in endpoints for cpu in endpoint["cpus"].values()]
    require(len(cpus) == 48 * 8 and all(cpu["energy_performance_preference"] == "performance" for cpu in cpus), "EPP endpoints")
    rows = []
    for depth in (16, 128):
        for name in SERVERS:
            subset = [trial for trial in trials if trial["pipeline"] == depth and trial["server"] == name]
            require(len(subset) == 3, "group count")
            batch, quantum = [int(value[1:]) for value in name.split("-")]
            row = {"server": name, "batch": batch, "callback_budget": quantum, "pipeline": depth, "configured_connections": 128, "active_clients": 128, "trial_indices": [t["index"] for t in subset]}
            row["responses_per_second"] = distribution([t["result"]["responses_per_second"] for t in subset])
            for field in ("server_cpu_percent", "client_cpu_percent"):
                row[field] = distribution([t[field] for t in subset])
            row["rss_kib"] = distribution([sum(t["resident_kib_by_pid"].values()) for t in subset])
            row["framework_heap_peak_bytes"] = HEAP[batch]
            row["observed_limits"] = {field: sorted({t["stats"][field] for t in subset}) for field in ("max_batch_responses", "max_inline_callbacks_per_turn", "max_send_parts", "max_send_bytes")}
            rows.append(row)
    for row in rows:
        base = next(r for r in rows if r["pipeline"] == row["pipeline"] and r["server"] == "b16-q64")
        row["ratio_to_same_binary_b16_q64_median"] = row["responses_per_second"]["median"] / base["responses_per_second"]["median"]
    counter_fields = ("peak_connections", "peak_operations", "short_send_completions", "gather_cancel_requests", "gather_canceled_completions", "max_canceled_batch_responses", "max_send_parts", "max_send_bytes", "framework_heap_limit_bytes")
    summary = {
        "timed_trials": 24, "warmups": 24, "raw_logs_verified": 72,
        "started_utc": receipt["started_utc"], "finished_utc": receipt["finished_utc"],
        "measured_responses": sum(t["result"]["requests"] for t in trials), "warmup_responses": sum(t["warmup"]["requests"] for t in trials), "exact_preflight_responses": sum(t["preflight"]["validated_responses"] for t in trials),
        "load_errors": {key: sum(t[phase][key] for t in trials for phase in ("result", "warmup")) for key in ERRORS},
        "late_allocation_calls": sum(t["stats"]["allocation_calls_after_start"] for t in trials),
        "counter_ranges": {key: {"min": min(t["stats"][key] for t in trials), "max": max(t["stats"][key] for t in trials)} for key in counter_fields},
        "power_endpoints": {"count": 48, "profile": "performance", "cpu_observations": len(cpus), "drivers": sorted({p["scaling_driver"] for p in cpus}), "governors": sorted({p["scaling_governor"] for p in cpus}), "epp": sorted({p["energy_performance_preference"] for p in cpus}), "intel_pstate": [json.loads(value) for value in sorted({json.dumps(p["intel_pstate"], sort_keys=True) for p in endpoints})]},
        "latency_sanity": {phase: {str(depth): {"sane": sum(t[phase]["latency_percentiles_sane"] for t in trials if t["pipeline"] == depth), "trials": 12} for depth in (16, 128)} for phase in ("result", "warmup")},
        "rows": rows,
    }
    return summary, {name: digest(data) for name, data in sorted(members.items())}


def main():
    packet = json.loads((ROOT / "timed.json").read_text())
    for name, expected in packet["artifact_sha256"].items():
        require(digest((ROOT / name).read_bytes()) == expected, "artifact hash: " + name)
    summary, members = summarize()
    require(summary == packet["summary"] and members == packet["archive_member_sha256"], "derived summary/archive differs")
    print(json.dumps(summary, indent=2) if "--json" in sys.argv else "Verified 24 trials, 24 warmups, 72 raw logs, B/Q limits, sample order, owners, profiles, hashes and derived summary values.")


if __name__ == "__main__":
    main()
