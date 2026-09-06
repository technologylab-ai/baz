#!/bin/sh
set -eu

linux_host=${1:-omarx1}
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
publication_commit=$(git -C "$repository_root" rev-parse HEAD 2>/dev/null || printf 'uncommitted-new-project')
printf 'checkout_commit=%s (streamed tree; require clean status for publication)\n' "$publication_commit"

COPYFILE_DISABLE=1 tar --no-xattrs --exclude=.git --exclude=.zig-cache \
    --exclude=zig-out --exclude=.claude/worktrees --exclude='__pycache__' -C "$repository_root" -czf - . |
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$linux_host" 'set -eu
        run_directory=$(mktemp -d /tmp/zig-http.XXXXXX)
        cleanup() {
            case "$run_directory" in
                /tmp/zig-http.*) rm -rf -- "$run_directory" ;;
                *) printf "unsafe cleanup target: %s\n" "$run_directory" >&2 ;;
            esac
        }
        trap cleanup EXIT HUP INT TERM
        tar -xzf - -C "$run_directory"
        cd "$run_directory"
        test "$(zig version)" = "$(cat .zig-version)"
        printf "host=%s arch=%s kernel=%s zig=%s io_uring_disabled=%s\n" \
            "$(uname -n)" "$(uname -m)" "$(uname -r)" "$(zig version)" \
            "$(cat /proc/sys/kernel/io_uring_disabled)"
        cat /etc/os-release
        timeout 180 zig build verify -Doptimize=Debug -j2 --summary all
        timeout 180 zig build verify -Doptimize=ReleaseSafe -j2 --summary all
        timeout 180 zig build -Doptimize=ReleaseSafe -j2
        timeout 180 zig build examples -Doptimize=ReleaseSafe -j2
        PYTHONDONTWRITEBYTECODE=1 timeout 180 python3 tests/test_compare.py -v
        PYTHONDONTWRITEBYTECODE=1 timeout 180 python3 tests/arena_lifecycle_integration.py
        PYTHONDONTWRITEBYTECODE=1 timeout 180 python3 tests/batch_integration.py
        PYTHONDONTWRITEBYTECODE=1 timeout 180 python3 tests/gather_integration.py
        PYTHONDONTWRITEBYTECODE=1 timeout 180 python3 tests/inline_integration.py
        PYTHONDONTWRITEBYTECODE=1 timeout 180 python3 tests/integration.py
        PYTHONDONTWRITEBYTECODE=1 timeout 120 python3 tests/app_integration.py
        PYTHONDONTWRITEBYTECODE=1 timeout 120 python3 tests/examples_integration.py
        PYTHONDONTWRITEBYTECODE=1 timeout 180 python3 tools/smoke.py
    '
