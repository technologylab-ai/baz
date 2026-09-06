#!/usr/bin/env python3
"""Build Baz's static Pages artifact using local, checksum-pinned browser assets."""
import hashlib
import html
import json
from pathlib import Path
import re
import shutil
import statistics
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / '.zig-cache/github-pages'
REPOSITORY = 'https://github.com/technologylab-ai/baz'
# Pages does not serve dot-prefixed paths. Keep the reader's canonical file name.
DOCUMENT_URLS = {'.zig-version': 'docs/zig-version.txt'}
EXAMPLES = [
    ('hello', 'routing', 'A minimal HTML response and an explicit route.'),
    ('hello2', 'routing', 'Inspect methods, raw queries, headers, and bounded bodies.'),
    ('hello_json', 'routing', 'JSON user lookup, with explicit ID parsing.'),
    ('simple_router', 'routing', 'Functions, stateful routes, and a synchronized counter.'),
    ('routes', 'routing', 'Static and dynamic responses in one router.'),
    ('serve', 'responses', 'Serve immutable embedded assets through explicit routes.'),
    ('sendfile', 'responses', 'File content as an embedded asset; no sendfile syscall.'),
    ('senderror', 'responses', 'Controlled errors, with no client-visible stack trace.'),
    ('accept', 'responses', 'Explicit, bounded content negotiation.'),
    ('mustache', 'responses', 'A greeting form and user cards: startup templates, typed data, bounded HTML.'),
    ('streaming', 'responses', 'Write, flush, sleep, and write again through a standard Zig writer.'),
    ('app_basic', 'app', 'Typed Shared, endpoint state, and instance shutdown.'),
    ('app_errors', 'app', 'Error mapping and discarded private response drafts.'),
    ('endpoint', 'app', 'Bounded user CRUD on explicit application workers.'),
    ('app_auth', 'composition', 'A typed bearer wrapper and early unauthorized response.'),
    ('endpoint_auth', 'composition', 'Stateful endpoints with an explicit authentication check.'),
    ('middleware', 'composition', 'Ordered Zig functions and typed stack locals.'),
    ('middleware_with_endpoint', 'composition', 'Endpoint composition with an early-stop path.'),
    ('userpass_session', 'composition', 'A bounded local login, logout, and session demonstration.'),
    ('cookies', 'composition', 'Borrowed cookie input, explicit expiry, and validated Set-Cookie output.'),
    ('http_params', 'data', 'Raw duplicates and explicit query versus form decoding.'),
    ('bindataformpost', 'data', 'One flat loop for fields and files, with bounded previews.'),
]


def documents():
    paths = {'README.md', 'ROADMAP.md', 'LICENSE', '.zig-version', 'build.zig', 'build.zig.zon',
             'examples/README.md', 'examples/LICENSE-ZAP',
             'examples/assets/session_login.html', 'examples/assets/session_home.html',
             'examples/assets/mustache.html', 'examples/assets/mustache-user.html', 'examples/embedding/build.zig',
             'examples/embedding/build.zig.zon', 'examples/embedding/src/main.zig',
             'reports/2026-09-06-basic-zap.md', 'reports/2026-09-06-app-api.md',
             'reports/2026-09-06-baz-extraction.md', 'reports/2026-09-06-windows-baz.md',
             'reports/2026-09-06-streaming.md', 'reports/2026-09-06-large-borrow.md',
             'reports/2026-09-06-mustache.md',
             'reports/2026-09-06-basic-zap/PROTOCOL.md',
             'reports/2026-09-06-basic-zap/reproducer/README.md'}
    for pattern in ('docs/*.md', 'src/*.zig', 'examples/*.zig'):
        paths.update(str(p.relative_to(ROOT)) for p in ROOT.glob(pattern))
    return sorted(paths)


def benchmark():
    rows = {}
    for host, label in [('macos', 'macOS · M3 Max'), ('linux', 'Linux · Core Ultra 7')]:
        summary = json.loads((ROOT / ('reports/2026-09-06-basic-zap/' + host + '-summary.json')).read_text())
        assert summary['complete'] and 'ReleaseSafe' in summary['build']
        for item in summary['medians']:
            values = item['median_rps']
            for name in ['app', 'zap']:
                assert statistics.median(item['rates'][name]) == values[name]
            rows[(host, item['connections'])] = (label, values['app'], values['zap'])
    table = []
    for connections in (32, 1):
        for host in ('macos', 'linux'):
            label, app, zap = rows[(host, connections)]
            table.append('<tr><td>{}</td><td>{} / {}</td><td>{:,.0f}</td><td>{:,.0f}</td><td>{:.3f}×</td></tr>'.format(
                label, connections, 2 if connections == 32 else 1, app, zap, app / zap))
    svg = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 900 290" class="diagram diagram-wide benchmark-chart" role="img" aria-labelledby="bench-title bench-desc">',
           '<title id="bench-title">Baz prototype and Zap, 32 connections</title>',
           '<desc id="bench-desc">Median requests per second: Mac Baz 254,261 and Zap 245,054; Linux Baz 363,594 and Zap 205,310. The table includes the one-connection results as well.</desc>']
    for tick in range(0, 400001, 100000):
        x = 210 + tick / 400000 * 550
        svg.append('<path class="gridline" d="M{0} 20v226"/><text x="{0}" y="276" text-anchor="middle">{1}</text>'.format(x, str(tick // 1000) + 'k' if tick else '0'))
    for index, host in enumerate(('macos', 'linux')):
        label, app, zap = rows[(host, 32)]
        y = 44 + index * 114
        svg.append('<text class="plot-label" x="0" y="{}">{}</text>'.format(y + 15, label.split(' · ')[0]))
        svg.append('<text x="0" y="{}">{}</text>'.format(y + 39, label.split(' · ')[1]))
        for offset, value, kind in [(0, app, 'baz'), (34, zap, 'zap')]:
            width = value / 400000 * 550
            svg.append('<rect class="{}-bar" x="210" y="{}" width="{:.3f}" height="24"/><text x="{:.3f}" y="{}">{:,.0f}</text>'.format(kind, y + offset, width, 220 + width, y + offset + 17, value))
    svg.append('</svg>')
    return '\n'.join(table), '\n'.join(svg)


def scroll_diagram(svg):
    return '<div class="image-scroll" tabindex="0" aria-label="Scrollable diagram">' + svg + '</div>'


def build():
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    if not re.fullmatch('[0-9a-f]{40}', revision):
        raise ValueError('Expected a full Git revision.')
    docs = documents()
    assets = ['docs/' + name for name in ('read.html', 'site.css', 'site.js', 'reader.css', 'reader.js', 'highlight-zig.js', 'favicon.svg')]
    assets.append('docs/assets/mustache-preview.png')
    assets += [str(path.relative_to(ROOT)) for path in sorted((ROOT / 'docs/diagrams').glob('*.svg'))]
    vendor = json.loads((ROOT / 'docs/vendor/manifest.json').read_text())
    assets.append('docs/vendor/manifest.json')
    for package in vendor:
        for filename, digest in package['files_sha256'].items():
            path = 'docs/vendor/' + filename
            if hashlib.sha256((ROOT / path).read_bytes()).hexdigest() != digest:
                raise ValueError('Vendor checksum mismatch: ' + path)
            assets.append(path)
    # All files must exist before replacing a previous successful artifact.
    for path in docs + assets:
        source = ROOT / path
        if not source.is_file() or source.is_symlink():
            raise ValueError('Expected regular site source: ' + path)
        if path in docs and source.stat().st_size > 1024 * 1024:
            raise ValueError('Document exceeds reader limit: ' + path)
    snippet = re.search(r'^const Hello = struct \{\n.*?^\};', (ROOT / 'src/app_demo.zig').read_text(), re.M | re.S)
    if not snippet:
        raise ValueError('Maintained Hello endpoint not found.')
    streaming = re.search(r'^fn progress\(.*?^}', (ROOT / 'examples/streaming.zig').read_text(), re.M | re.S)
    if not streaming:
        raise ValueError('Maintained streaming endpoint not found.')
    borrowed = re.search(r'^const Shared = struct \{\};\n.*?^fn index\(.*?^}', (ROOT / 'examples/serve.zig').read_text(), re.M | re.S)
    if not borrowed:
        raise ValueError('Maintained file-response handler not found.')
    cards = []
    for name, group, description in EXAMPLES:
        if 'examples/' + name + '.zig' not in docs:
            raise ValueError('Missing example: ' + name)
        cards.append('<a class="example-card" data-group="{}" href="docs/read.html?file=examples/{}.zig"><strong>{}<span aria-hidden="true">↗</span></strong><p>{}</p></a>'.format(group, name, name, html.escape(description)))
    results, chart = benchmark()
    replacements = {'HELLO': html.escape(snippet.group(0)), 'STREAMING': html.escape(streaming.group(0)), 'BORROWED': html.escape(borrowed.group(0).strip()), 'EXAMPLES': '\n'.join(cards),
                    'RESULTS': results, 'PERFORMANCE': scroll_diagram(chart)}
    for token, name in [('PARAMETERS', 'parameters'), ('LAYERS', 'layers'), ('LIFETIME', 'lifetime')]:
        replacements[token] = scroll_diagram((ROOT / ('docs/diagrams/' + name + '.svg')).read_text())
    page = (ROOT / 'docs/index.template.html').read_text()
    for key, value in replacements.items():
        if page.count('@@' + key + '@@') != 1:
            raise ValueError('Expected one template slot: ' + key)
        page = page.replace('@@' + key + '@@', value)
    if re.search(r'@@[A-Z]+@@', page):
        raise ValueError('Unfilled template slot.')
    tracked = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard'], cwd=ROOT, text=True).splitlines()
    directories = sorted({str(parent) for file in tracked for parent in Path(file).parents if str(parent) != '.'})
    config = {'documents': docs, 'documentUrls': DOCUMENT_URLS,
              'assets': assets + ['index.html'], 'directories': directories,
              'repository': REPOSITORY + '/blob/' + revision + '/'}
    if OUTPUT.exists():
        shutil.rmtree(OUTPUT)
    OUTPUT.mkdir(parents=True)
    for name in docs + assets:
        destination = OUTPUT / DOCUMENT_URLS.get(name, name)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / name, destination)
    (OUTPUT / 'docs/site-config.js').write_text('window.DOC_SITE = ' + json.dumps(config) + ';\n')
    (OUTPUT / 'index.html').write_text(page)
    (OUTPUT / '.nojekyll').write_text('')
    hashes = {str(p.relative_to(OUTPUT)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in sorted(OUTPUT.rglob('*')) if p.is_file()}
    (OUTPUT / 'publication.json').write_text(json.dumps({'revision': revision, 'files_sha256': hashes}, indent=2) + '\n')
    from check_site import check
    check(OUTPUT, docs, DOCUMENT_URLS)
    print('Pages artifact: {} files, {} documents, revision {}\n{}'.format(len(hashes) + 1, len(docs), revision, OUTPUT))


if __name__ == '__main__':
    build()
