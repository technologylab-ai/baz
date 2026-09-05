#!/usr/bin/env python3
"""Package completed local evidence only; never run workloads or contact a host.

Usage: python3 reports/2026-09-05-arena-adoption/pack.py
Inputs are the named .zig-cache gate/trial directories. Writes stay beside this
script. Archive names/order, ownership/mode/mtime and gzip mtime are normalized.
"""
import gzip
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tarfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent
REPOSITORY = ROOT.parents[1]
spec = importlib.util.spec_from_file_location("arena_summary", ROOT / "summarize.py")
summary_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(summary_module)


def main():
    summary_module.require(len(sys.argv) == 1, "usage: pack.py")
    cache = REPOSITORY / ".zig-cache"
    linux = cache / "arena-qualified-linux"
    receipt = json.loads((linux / "receipt.json").read_text())
    summary_module.require(receipt["timing_controller"]["ok"] and receipt["release"]["status"] == "released", "wait for completed Linux controller and released reservation")
    members = {}
    for prefix, directory in (("linux", linux), ("macos-clean", cache / "arena-clean-macos"), ("macos-development", cache / "arena-hardened-macos")):
        for path in sorted(directory.rglob("*")):
            summary_module.require(not path.is_symlink(), "source cache symlink: " + str(path))
            if path.is_file():
                members[prefix + "/" + path.relative_to(directory).as_posix()] = path.read_bytes()
    # Preserve the exact transported bytes and independently compare their
    # expanded regular files with the local copies included in this archive.
    remote = summary_module.archive_members(members["linux/raw-remote.tar.gz"])
    for name, data in remote.items():
        summary_module.require(members["linux/" + name] == data, "remote transport/local artifact differs: " + name)
    target = ROOT / "evidence.tar.gz"
    with target.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0, compresslevel=9) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
                for name, data in sorted(members.items()):
                    entry = tarfile.TarInfo(name)
                    entry.size = len(data)
                    entry.uid = entry.gid = entry.mtime = 0
                    entry.uname = entry.gname = ""
                    entry.mode = 0o644
                    archive.addfile(entry, io.BytesIO(data))
    derived, member_hashes, source_hashes = summary_module.summarize()
    packet = {
        "schema_version": 1,
        "tool": "zig-http-arena-adoption-evidence",
        "mutates_repository": False,
        "implementation_commit": summary_module.COMMIT,
        "archive_construction": "sorted regular files; uid/gid/mtime zero; mode0644; empty owner names; gzip mtime zero; original input bytes retained",
        "artifact_sha256": {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in ("evidence.tar.gz", "pack.py", "summarize.py")},
        "archive_member_sha256": member_hashes,
        "measured_source_sha256": source_hashes,
        "summary": derived,
    }
    (ROOT / "packet.json").write_text(json.dumps(packet, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"archive_members": len(member_hashes), "source_files": len(source_hashes), "timed_trials": derived["timed_trials"], "archive_sha256": packet["artifact_sha256"]["evidence.tar.gz"]}, sort_keys=True))


if __name__ == "__main__":
    main()
