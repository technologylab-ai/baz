# Reproduce the Linux comparison preparation

`prepare.py` downloads pinned primary sources and package artifacts, verifies their
hashes, builds the three contenders and wrk, and generates the input for
`tools/compare.py`. It does **not** launch any server or load generator. Preparation
is separate from measurement so compilation cannot compete with a timed run.

The recorded September 2026 preparation used Linux x86_64 on `omarx1`, GCC 16.2.1,
OpenSSL 3.6.3, and Zig 0.16.0. This generalized script preserves those source pins
and optimization flags; it records the actual installed native compiler and
OpenSSL rather than assuming their versions or promising identical binaries.

Prerequisites: Python 3.9+, exact Zig 0.16.0, Git, curl, GCC/G++, gcc-ar/nm/ranlib,
autoconf, automake, libtool, make, unzip, OpenSSL development headers/libraries,
`taskset`, `lscpu`, and a usable Docker daemon. Seven distinct allowed logical CPUs
are required: three server CPUs and at least four client CPUs. Check physical
topology before interpreting this as a physical-core allocation. The script
installs no system packages. Docker may populate its normal image cache.

Create a fresh directory with `mktemp -d /tmp/zig-http-compare.XXXXXX` on the Linux
host. Place a clean archive of the chosen full commit in its `zig-http/` child
directory using `git archive <full-commit>`, not a copy containing uncommitted
source edits. The archived commit must contain this preparation directory and
the comparison harness. Run the following **on that Linux host**, substituting
the created directory and the actual full archived commit:

```sh
python3 /tmp/zig-http-compare.XXXXXX/zig-http/benchmarks/prepare/prepare.py \
  /tmp/zig-http-compare.XXXXXX --commit FULL_40_CHARACTER_COMMIT --check
python3 /tmp/zig-http-compare.XXXXXX/zig-http/benchmarks/prepare/prepare.py \
  /tmp/zig-http-compare.XXXXXX --commit FULL_40_CHARACTER_COMMIT
```

Defaults are `--server-cpus 0,1,2 --client-cpus 3,4,5,6,7`. Explicit lists may select
other available CPUs. The root must be canonical, owned by the caller, and match
the `/tmp/zig-http-compare.<suffix>` form. Existing preparation outputs cause a
refusal; partial preparations are retained for diagnosis. The script never deletes
an existing checkout or temporary root. The `--commit` value is caller attestation
of the archive command, not an independent proof that arbitrary supplied files
match that commit. `preparation.json` includes hashes of the supplied source files.

Preparation produces `preparation.log`, `preparation.json`, and
`comparison-config.json`, with binaries, dependency prefixes, package downloads,
and the mrhttp virtual environment entirely under that root. Builds run
sequentially, each capped at two make jobs; the mrhttp build container gets two
CPUs. The native server build uses Zig `ReleaseSafe` with assertions enabled.
Each subprocess has a finite timeout (normally 300 seconds, 600 for the image
pull), and the whole preparation has a one-hour watchdog. Interrupted native
commands terminate their owned process groups. The install container has a unique
name and ownership label and is removed on success, failure, or timeout, even if
its Docker CLI was killed. Docker daemon unavailability can prevent cleanup; that
failure is recorded with the owned container name/label for recovery.
Run the project's required verification gates before starting the separate
comparison command. No performance result is implied by successful preparation.

`pins.json` records the exact TFB Round 23 source snapshot, libreactor and its
dependencies, wrk 4.2.0, all six mrhttp package artifacts, and the Python image
digest. Source records derive from these primary repositories:

- [TFB snapshot](https://github.com/TechEmpower/FrameworkBenchmarks/tree/523534bb61450e3522d775a749ad060753e26e3a)
- [libreactor](https://github.com/fredrikwidlund/libreactor/tree/63fa717a8047b1b5c38bc1d69ad193050e4f0ef7)
- [libdynamic](https://github.com/fredrikwidlund/libdynamic/tree/5aacfb1bc8aee9468041313a38a15b086c9d0ee2)
- [libclo](https://github.com/fredrikwidlund/libclo/tree/cc815bded704919246685093d0574bcf8cafd561)
- [wrk](https://github.com/wg/wrk/tree/a211dd5a7050b1f9e8a9870b95513060e72ac4a0)

The libreactor recipe retains its source Makefile flags, response construction,
pipeline batching, fork-per-affinity-CPU workers, and CBPF filter. Its only app
edit changes binding to `127.0.0.1`. The unused libclo include is removed exactly
as in the TFB Dockerfile. Its libraries install into the temporary prefix and
link statically; libc remains dynamic. Sources come from verified commit archives
rather than release tarballs with pregenerated configure scripts. wrk uses its
hashed bundled LuaJIT archive and host OpenSSL via `WITH_OPENSSL=/usr`.

The original CBPF filter returns the current CPU number as a reuseport socket
index. CPUs outside indices 0–2 can fall back to normal reuseport distribution;
noncontiguous CPU lists and loopback client placement affect that behavior. This
recipe intentionally keeps the submitted implementation's selection logic.

mrhttp uses its original Python 3.8.12 image pinned by digest, exact hashed wheels,
and the hashed mrpacker source distribution. The install runs offline with
`--require-hashes`, and does not resolve floating dependencies. `app.py` changes
only the bind address to `127.0.0.1` and worker count to three. Its cached plaintext
route remains intact, including `Hello, world!` capitalization. The container uses
host networking and the assigned three CPUs. Build and runtime containers use
the caller's UID/GID so the resulting files remain removable by their owner;
this is an additional preparation detail beyond the original measured recipe.
Pip caching is disabled; standard home-directory environment variables are left
unchanged. The pinned image's venv uses pip 21.1.1, which supports mrpacker's legacy
`setup.py install` fallback without the `wheel` package; `--no-build-isolation`
keeps that offline install in the existing pinned environment.
Wheel build flags are upstream artifacts and are not reconstructed by this script.

Every mrhttp container name includes the unique directory suffix. The generated
configuration owns its stop command, avoiding a shared fixed name between runs.
Stopping and removing a benchmark root remains the caller's responsibility after
all its native process groups and named containers have stopped. Keep the JSON
receipt, logs, and actual measurement outputs before removing temporary files.
