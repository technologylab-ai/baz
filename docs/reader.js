/* Source is data. Only allowlisted documents are fetched; Markdown is sanitized. */
(() => {
  'use strict';
  const config = window.DOC_SITE;
  const root = new URL('../', location.href);
  const reader = new URL('docs/read.html', root);
  const article = document.querySelector('#document');
  const status = document.querySelector('#status');
  const documents = new Set(config.documents);
  const assets = new Set(config.assets);
  const directories = new Set(config.directories);
  const maxBytes = 1024 * 1024;
  function pathOf(url) {
    if (url.origin !== root.origin || !url.pathname.startsWith(root.pathname)) return null;
    let path;
    try { path = decodeURIComponent(url.pathname.slice(root.pathname.length)); } catch (_) { return null; }
    return /^[A-Za-z0-9_./-]+$/.test(path) && !path.split('/').some(x => x === '.' || x === '..') ? path : null;
  }
  function sourceLink(path, fragment = '') {
    return (directories.has(path.replace(/\/$/, '')) ? config.repository.replace('/blob/', '/tree/') : config.repository) + path + fragment;
  }
  function links(source, container) {
    container.querySelectorAll('a[href]').forEach(link => {
      const href = link.getAttribute('href');
      if (href.startsWith('#')) return;
      let target;
      try { target = new URL(href, source); } catch (_) { link.removeAttribute('href'); return; }
      if (!['http:', 'https:', 'mailto:'].includes(target.protocol)) { link.removeAttribute('href'); return; }
      const path = pathOf(target);
      if (path !== null && documents.has(path)) {
        const destination = new URL(reader); destination.searchParams.set('file', path); destination.hash = target.hash; link.href = destination.href;
      } else if (path !== null && !assets.has(path)) {
        link.href = sourceLink(path, target.hash); link.title = 'View on GitHub';
      } else link.href = target.href;
    });
    container.querySelectorAll('img').forEach(img => {
      let target;
      try { target = new URL(img.getAttribute('src'), source); } catch (_) { img.remove(); return; }
      if (!assets.has(pathOf(target))) { img.replaceWith(document.createTextNode(img.alt || 'Image unavailable.')); return; }
      img.src = target.href; img.removeAttribute('srcset');
    });
  }
  function contents() {
    const counts = new Map();
    const toc = document.querySelector('#contents');
    article.querySelectorAll('h1,h2,h3,h4,h5,h6').forEach(heading => {
      const slug = heading.textContent.trim().toLowerCase().replace(/[^\p{L}\p{N}_ -]/gu, '').replace(/ /g, '-');
      const count = counts.get(slug) || 0; counts.set(slug, count + 1);
      heading.id = slug + (count ? '-' + count : '');
      if (heading.tagName !== 'H2' && heading.tagName !== 'H3') return;
      const link = document.createElement('a'); link.href = '#' + heading.id; link.textContent = heading.textContent;
      if (heading.tagName === 'H3') link.className = 'sub'; toc.append(link);
    });
    toc.hidden = !toc.children.length;
  }
  function decorate() {
    article.querySelectorAll('pre code').forEach(code => {
      const language = [...code.classList].find(x => x.startsWith('language-'))?.slice(9);
      if (language && hljs.getLanguage(language)) hljs.highlightElement(code);
      code.parentElement.tabIndex = 0;
      const button = document.createElement('button'); button.className = 'copy'; button.type = 'button'; button.textContent = 'Copy';
      button.setAttribute('aria-label', 'Copy code');
      button.addEventListener('click', async () => {
        try { await navigator.clipboard.writeText(code.textContent); button.textContent = 'Copied'; }
        catch (_) { button.textContent = 'Select to copy'; }
      });
      code.parentElement.prepend(button);
    });
    article.querySelectorAll('table').forEach(table => {
      const wrap = document.createElement('div'); wrap.className = 'table-scroll'; wrap.tabIndex = 0;
      wrap.setAttribute('aria-label', 'Scrollable table'); table.replaceWith(wrap); wrap.append(table);
    });
  }
  async function load() {
    const file = new URLSearchParams(location.search).get('file') || 'docs/APP-API.md';
    // Check before URL normalization, which would erase traversal segments.
    if (!/^[A-Za-z0-9_./-]+$/.test(file) || file.startsWith('/') || file.split('/').some(x => x === '.' || x === '..') || !documents.has(file)) {
      throw new Error('Choose a published guide or example from the navigation.');
    }
    const source = new URL(config.documentUrls[file] || file, root);
    const controller = new AbortController(); const timer = setTimeout(() => controller.abort(), 10000);
    let body;
    try {
      const response = await fetch(source, {signal: controller.signal, credentials: 'omit', redirect: 'error'});
      if (!response.ok) throw new Error('The document could not be loaded (HTTP ' + response.status + ').');
      if (Number(response.headers.get('Content-Length')) > maxBytes) throw new Error('This file exceeds the reader’s size limit.');
      body = await response.text();
      if (new TextEncoder().encode(body).length > maxBytes) throw new Error('This file exceeds the reader’s size limit.');
    } finally { clearTimeout(timer); }
    document.querySelector('#file-name').textContent = file;
    const raw = document.querySelector('#raw'); raw.href = source.href; raw.hidden = false;
    const github = document.querySelector('#source'); github.href = sourceLink(file); github.hidden = false;
    if (file.endsWith('.md')) {
      const fragment = DOMPurify.sanitize(marked.parse(body), {
        USE_PROFILES: {html: true}, FORBID_TAGS: ['style', 'form', 'input', 'button', 'textarea', 'select', 'video', 'audio', 'source'],
        FORBID_ATTR: ['style', 'id', 'name', 'srcset'], ALLOW_DATA_ATTR: false, RETURN_DOM_FRAGMENT: true
      });
      links(new URL(file, root), fragment); article.replaceChildren(fragment); contents();
    } else {
      const title = document.createElement('h1'); title.textContent = file.split('/').pop();
      const pre = document.createElement('pre'); const code = document.createElement('code');
      const extension = file.split('.').pop();
      const language = {zon: 'zig', py: 'python', sh: 'bash', yml: 'yaml', js: 'javascript'}[extension] || extension;
      code.className = 'language-' + language; code.textContent = body; pre.append(code); article.append(title, pre);
    }
    decorate();
    document.title = (article.querySelector('h1')?.textContent || file) + ' · Baz';
    status.hidden = true;
    if (location.hash) {
      let fragment; try { fragment = decodeURIComponent(location.hash.slice(1)); } catch (_) { fragment = ''; }
      requestAnimationFrame(() => {
        article.querySelectorAll('[id]').forEach(el => { if (el.id === fragment) el.scrollIntoView({behavior: 'instant'}); });
        document.documentElement.dataset.readerReady = 'true';
      });
    } else {
      document.documentElement.dataset.readerReady = 'true';
    }
  }
  document.querySelector('#print').addEventListener('click', () => window.print());
  load().catch(error => {
    status.textContent = error.name === 'AbortError' ? 'Loading timed out. Retry or open the guides on GitHub.' : (error.message || 'The document could not be loaded.');
    status.setAttribute('role', 'alert'); document.documentElement.dataset.readerReady = 'error';
  });
})();
