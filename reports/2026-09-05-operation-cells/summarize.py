#!/usr/bin/env python3
"""Read-only verification and reproduction of the operation-cell timing summary.

Run from any directory with Python 3: python3 /path/to/summarize.py [--json].
No server, benchmark, network operation, or extraction is performed.
"""
import hashlib
import json
from pathlib import Path
import statistics
import sys
import tarfile

ROOT = Path(__file__).resolve().parent
SERVERS = ("baseline", "direct-cells")
ERRORS = ("connect_errors", "read_errors", "write_errors", "status_errors", "timeout_errors")
COMMITS = ("c0f87766efa310d517d262781a33ce189c4f9f0d", "2b971e14f5fd8ed9769b5cdefbea3d86c71d83fc")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def distribution(values):
    return {"n": len(values), "median": statistics.median(values), "min": min(values), "max": max(values)}


def summarize():
    with tarfile.open(ROOT / "timed-logs.tar.gz", "r:gz") as archive:
        entries = [member for member in archive.getmembers() if member.isfile()]
        require(len(entries) == len({member.name for member in entries}), "duplicate archive names")
        members = {member.name: archive.extractfile(member).read() for member in entries}
    rows, trials, endpoints = [], [], []
    receipts = {}
    for capacity in (128, 1024):
        receipt = json.loads((ROOT / f"abba-{capacity}.json").read_text())
        receipts[str(capacity)] = receipt
        require(receipt["ok"] and len(receipt["trials"]) == 24, "incomplete trial receipt")
        require(receipt["ordering"] == "abba" and receipt["samples_per_configuration"] == 4, "sample metadata")
        require(receipt["repeats"] == 2 and receipt["seed"] == 20260905, "replicate metadata")
        require(receipt["connections"] == [128] and receipt["pipeline_depths"] == [1, 16, 128], "workload")
        require(receipt["duration_seconds"] == 5 and receipt["threads"] == 4, "load configuration")
        config = json.loads((ROOT / f"configuration-{capacity}.json").read_text())
        require(config == receipt["configuration"], "configuration copy differs")
        require(digest((ROOT / f"configuration-{capacity}.json").read_bytes()) == receipt["configuration_sha256"], "configuration hash")
        require(config["server_capacity"] == capacity and config["server_cpus"] == [0] and config["client_cpus"] == [3, 4, 5, 6, 7], "affinity/capacity")
        require(tuple(server["source_commit"] for server in config["servers"]) == COMMITS, "source identity")
        require(tuple(server["name"] for server in config["servers"]) == SERVERS, "server identity")
        require(digest(members["source/tools/compare.py"]) == receipt["harness_sha256"], "harness identity")
        require(digest(members["source/benchmarks/pipeline.lua"]) == receipt["lua_sha256"], "Lua identity")
        current = receipt["trials"]
        require(len({(t["repeat"], t["pipeline"], t["server"]) for t in current}) == 24, "duplicate trial")
        for index, trial in enumerate(current):
            require(trial["index"] == index and trial["abba_block"] == index // 4 and trial["abba_position"] == index % 4, "ABBA positions")
            require(trial["abba_repeat"] == trial["repeat"] // 2, "ABBA replicate")
            require(trial["connections"] == 128 and trial["client_exit"] == trial["server_exit"] == 0, "trial failure")
            require(trial["stable_thread_set"] and len(trial["server_threads"]) == 1, "server thread count")
            require(trial["server_threads"][0]["last_cpu"] == 0, "server CPU")
            prefix = f"opcells-abba-{capacity}/{index:03d}-{trial['server']}-c128-p{trial['pipeline']}"
            for suffix, key in (("wrk", "result"), ("warmup", "warmup")):
                log = members[prefix + f"-{suffix}.log"].decode()
                records = [json.loads(line[7:]) for line in log.splitlines() if line.startswith("RESULT ")]
                require(len(records) == 1, "missing/ambiguous raw RESULT")
                result = records[0]
                require(all(trial[key][k] == v for k, v in result.items()), "raw RESULT differs")
                require(result["requests"] > 0 and result["duration_us"] > 0, "empty load")
                require(all(result[k] == 0 for k in ERRORS) and trial[key]["ok"], "load errors")
                require(trial[key]["responses_per_second"] == result["requests"] * 1e6 / result["duration_us"], "rate calculation")
                sane = 0 < result["latency_p50_us"] <= result["latency_p99_us"] <= result["latency_max_us"]
                require(trial[key]["latency_percentiles_sane"] == sane, "latency sanity flag")
            server_log = members[prefix + "-server.log"].decode()
            require(server_log == trial["server_log"], "raw server log differs")
            records = [json.loads(line[6:]) for line in server_log.splitlines() if line.startswith("STATS ")]
            require(records == [trial["stats"]], "raw STATS differs")
            require(f"connections={capacity} " in server_log and "optimize=ReleaseSafe" in server_log, "server configuration marker")
            stats = trial["stats"]
            for key in ("workers", "worker_dispatches", "allocation_calls_after_start", "live_connections", "live_operations", "rejected", "timeouts", "scalar_send_operations"):
                require(stats[key] == 0, "unexpected server counter: " + key)
            require(stats["execution"] == "inline_event_loop" and stats["gather_send"] and stats["response_batch_limit"] == 16, "execution mode")
            require(stats["peak_connections"] == 128 and stats["peak_operations"] <= 2 * (capacity + 1), "ownership bounds")
            require(stats["max_batch_responses"] <= 16 and stats["max_inline_callbacks_per_turn"] <= 64, "batch/callback bounds")
            preflight = trial["preflight"]
            require(preflight["validated_responses"] == 2 * max(16, trial["pipeline"]), "preflight count")
            require(preflight["exact_body"] == "Hello, World!" and preflight["first_date"] != preflight["last_date"], "body/date preflight")
            endpoints.extend((trial["power_before"], trial["power_after"]))
        for start in range(0, 24, 4):
            block = current[start:start + 4]
            require([t["server"] for t in block] == ["baseline", "direct-cells", "direct-cells", "baseline"], "ABBA order")
            require(len({(t["pipeline"], t["abba_repeat"]) for t in block}) == 1, "mixed workload block")
        for depth in (1, 16, 128):
            row = {"configured_connections": capacity, "active_clients": 128, "pipeline": depth, "servers": {}, "blocks": []}
            for server in SERVERS:
                subset = [t for t in current if t["pipeline"] == depth and t["server"] == server]
                require(len(subset) == 4, "sample count")
                row["servers"][server] = {
                    "trial_indices": [t["index"] for t in subset],
                    "responses_per_second": distribution([t["result"]["responses_per_second"] for t in subset]),
                    "server_cpu_percent": distribution([t["server_cpu_percent"] for t in subset]),
                    "client_cpu_percent": distribution([t["client_cpu_percent"] for t in subset]),
                    "rss_kib": distribution([sum(t["resident_kib_by_pid"].values()) for t in subset]),
                    "framework_heap_peak_bytes": sorted({t["stats"]["framework_heap_peak_bytes"] for t in subset}),
                }
            row["ratio_of_medians"] = row["servers"]["direct-cells"]["responses_per_second"]["median"] / row["servers"]["baseline"]["responses_per_second"]["median"]
            for block_id in sorted({t["abba_block"] for t in current if t["pipeline"] == depth}):
                block = [t for t in current if t["abba_block"] == block_id]
                means = {s: statistics.mean(t["result"]["responses_per_second"] for t in block if t["server"] == s) for s in SERVERS}
                row["blocks"].append({"abba_block": block_id, "abba_repeat": block[0]["abba_repeat"], "trial_indices": [t["index"] for t in block], "mean_responses_per_second": means, "ratio_of_means": means["direct-cells"] / means["baseline"]})
            rows.append(row)
        trials.extend(current)
    require(all(p["profile"] == "performance" and p["profile_error"] is None for p in endpoints), "profile endpoint")
    cpu_endpoints = [cpu for endpoint in endpoints for cpu in endpoint["cpus"].values()]
    require(len(cpu_endpoints) == 96 * 8, "CPU endpoint count")
    counters = ("peak_connections", "peak_operations", "max_batch_responses", "max_inline_callbacks_per_turn", "max_send_parts", "max_send_bytes", "short_send_completions", "gather_cancel_requests", "gather_canceled_completions", "framework_heap_limit_bytes")
    summary = {
        "timed_trials": len(trials), "warmups": len(trials), "raw_logs_verified": len(trials) * 3,
        "measured_responses": sum(t["result"]["requests"] for t in trials),
        "warmup_responses": sum(t["warmup"]["requests"] for t in trials),
        "exact_preflight_responses": sum(t["preflight"]["validated_responses"] for t in trials),
        "load_errors": {key: sum(t[phase][key] for t in trials for phase in ("result", "warmup")) for key in ERRORS},
        "late_allocation_calls": sum(t["stats"]["allocation_calls_after_start"] for t in trials),
        "counter_ranges": {key: {"min": min(t["stats"][key] for t in trials), "max": max(t["stats"][key] for t in trials)} for key in counters},
        "timing_intervals": {key: {field: r[field] for field in ("started_utc", "finished_utc")} for key, r in receipts.items()},
        "power_endpoints": {"count": len(endpoints), "profile": "performance", "cpu_observations": len(cpu_endpoints), "drivers": sorted({p["scaling_driver"] for p in cpu_endpoints}), "governors": sorted({p["scaling_governor"] for p in cpu_endpoints}), "epp": sorted({p["energy_performance_preference"] for p in cpu_endpoints}), "intel_pstate": [json.loads(s) for s in sorted({json.dumps(p["intel_pstate"], sort_keys=True) for p in endpoints})]},
        "measured_latency_sanity": {str(depth): {"sane": sum(t["result"]["latency_percentiles_sane"] for t in trials if t["pipeline"] == depth), "trials": sum(t["pipeline"] == depth for t in trials)} for depth in (1, 16, 128)},
        "rows": rows,
    }
    return summary, {name: digest(data) for name, data in sorted(members.items())}


def main():
    packet = json.loads((ROOT / "timed.json").read_text())
    for name, expected in packet["artifact_sha256"].items():
        require(digest((ROOT / name).read_bytes()) == expected, "artifact hash differs: " + name)
    summary, members = summarize()
    require(summary == packet["summary"], "derived summary differs")
    require(members == packet["archive_member_sha256"], "archive contents differ")
    print(json.dumps(summary, indent=2) if "--json" in sys.argv else "Verified 48 trials, 48 warmups, 144 raw logs, artifact hashes, and all derived summary values.")


if __name__ == "__main__":
    main()
