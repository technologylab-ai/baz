#!/usr/bin/env python3
"""Check the generated site's links, anchors, allowlist, and source fidelity."""
from html.parser import HTMLParser
import json
from pathlib import Path
import re
from urllib.parse import parse_qs, unquote, urlsplit
import xml.etree.ElementTree as ET


class Page(HTMLParser):
    def __init__(self, text):
        super().__init__(convert_charrefs=True)
        self.ids, self.links = set(), []
        self.feed(text)

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if 'id' in attrs:
            assert attrs['id'] not in self.ids, 'Duplicate ID: ' + attrs['id']
            self.ids.add(attrs['id'])
        for attribute in ['href', 'src']:
            if attribute in attrs:
                self.links.append(attrs[attribute])
        if tag == 'img':
            assert 'alt' in attrs, 'Image without alternative text'
        if tag == 'svg':
            assert attrs.get('role') == 'img' and attrs.get('aria-labelledby'), 'Diagram needs an accessible name'


def check(output, documents):
    pages = {name: Page((output / name).read_text()) for name in ['index.html', 'docs/read.html']}
    for name, page in pages.items():
        for href in page.links:
            link = urlsplit(href)
            if link.scheme or link.netloc:
                assert link.scheme in ['https', 'http', 'mailto'], 'Unexpected URL scheme: ' + href
                continue
            target = (output / name).parent / unquote(link.path) if link.path else output / name
            target = target.resolve()
            assert output.resolve() in target.parents, 'Link escapes site: ' + href
            assert target.is_file(), 'Missing page asset: ' + href
            if target.name == 'read.html' and link.query:
                file = parse_qs(link.query).get('file', [''])[0]
                assert file in documents, 'Reader target not published: ' + file
            elif link.fragment and str(target.relative_to(output.resolve())) in pages:
                assert unquote(link.fragment) in pages[str(target.relative_to(output.resolve()))].ids, 'Missing anchor: ' + href
    for path in (output / 'docs/diagrams').glob('*.svg'):
        ET.parse(path)
    manifest = json.loads((output / 'publication.json').read_text())
    actual = {str(path.relative_to(output)) for path in output.rglob('*') if path.is_file()}
    assert actual == set(manifest['files_sha256']) | {'publication.json'}, 'Unexpected artifact files'
    index = (output / 'index.html').read_text()
    assert len(re.findall(r'class="example-card"', index)) == 20
    assert all(text in index for text in ['1.038×', '1.771×', '0.629×', '1.025×'])
    assert all((output / name).read_bytes() == (Path(__file__).resolve().parents[1] / name).read_bytes() for name in documents), 'Copied document changed'
    print('Site checks passed: links, anchors, diagrams, 20 examples, four benchmark profiles, and document identity.')


if __name__ == '__main__':
    from build_pages import OUTPUT, documents
    check(OUTPUT, documents())
