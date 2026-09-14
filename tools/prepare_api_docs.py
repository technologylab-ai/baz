#!/usr/bin/env python3
"""Normalize Zig 0.16 Autodoc's filename/order-based module root selection.

The viewer chooses root.zig, <module>.zig, or the first file in each module.
Baz uses baz.zig; two dependencies use different root names. Keep every source byte and
archive path; put the build graph's real roots first instead of relying on
filesystem iteration order. The compiler's JS and Wasm stay unchanged.
"""
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import shutil
import sys
import tarfile


FILES = ('index.html', 'main.js', 'main.wasm', 'sources.tar')


def normalize_archive(source, destination, roots):
    root_by_module = {path.split('/')[0]: path for path in roots}
    if len(root_by_module) != len(roots):
        raise ValueError('Duplicate module roots')
    with tarfile.open(source) as archive:
        members = archive.getmembers()
        paths = [member.name for member in members]
        if len(paths) != len(set(paths)):
            raise ValueError('Duplicate source archive paths')
        for member in members:
            path = PurePosixPath(member.name)
            if not member.isfile() or path.is_absolute() or '..' in path.parts or len(path.parts) < 2:
                raise ValueError('Expected a relative regular source file: ' + member.name)
            module = path.parts[0]
            if member.name in (module + '/root.zig', module + '/' + module + '.zig'):
                if module in root_by_module and root_by_module[module] != member.name:
                    raise ValueError('Autodoc root heuristic conflicts with build graph: ' + member.name)
        if set(roots) - set(paths):
            raise ValueError('Build graph roots missing from source archive')
        # This also makes Baz the default module and produces deterministic output.
        order = {path: index for index, path in enumerate(roots)}
        members.sort(key=lambda member: (order.get(member.name, len(roots)), member.name))
        digests = {}
        with tarfile.open(destination, 'w', format=tarfile.USTAR_FORMAT) as output:
            for member in members:
                data = archive.extractfile(member).read()
                info = tarfile.TarInfo(member.name)
                info.size, info.mode = len(data), 0o644
                output.addfile(info, io.BytesIO(data))
                digests[member.name] = hashlib.sha256(data).hexdigest()
    return {'module_roots': root_by_module, 'sources_sha256': digests}


def prepare(source, destination, roots):
    destination.mkdir(parents=True, exist_ok=True)
    for name in FILES:
        if not (source / name).is_file() or (source / name).is_symlink():
            raise ValueError('Missing compiler documentation output: ' + name)
    for name in FILES[:-1]:
        shutil.copyfile(source / name, destination / name)
    manifest = normalize_archive(source / 'sources.tar', destination / 'sources.tar', roots)
    manifest['generator'] = 'Zig 0.16.0 Autodoc'
    manifest['files_sha256'] = {name: hashlib.sha256((destination / name).read_bytes()).hexdigest() for name in FILES}
    (destination / 'api-build.json').write_text(json.dumps(manifest, indent=2) + '\n')


if __name__ == '__main__':
    prepare(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3:])
