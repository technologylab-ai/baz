/* Presentation only: Zig owns symbol resolution, search, and source rendering. */
(() => {
  // The viewer owns URL fragments; the shared skip link must only move focus.
  document.querySelector('.skip').addEventListener('click', event => {
    event.preventDefault();
    document.getElementById('main').focus();
  });
  const title = document.querySelector('title');
  function brandTitle() {
    const next = document.title.replace(/ - Zig Documentation$/, ' · Baz API');
    if (next !== document.title) document.title = next;
  }
  new MutationObserver(brandTitle).observe(title, {childList: true});
  brandTitle();
  const viewer = document.querySelector('.api-viewer');
  function scrollRegions() {
    for (const element of viewer.querySelectorAll('pre, .source-code')) {
      if (element.closest('.source-code') && !element.matches('.source-code')) continue;
      element.tabIndex = 0;
      element.setAttribute('aria-label', element.matches('.source-code') ? 'Scrollable source code' : 'Scrollable code');
    }
  }
  new MutationObserver(scrollRegions).observe(viewer, {childList: true, subtree: true});
  scrollRegions();
  setTimeout(() => {
    const status = document.getElementById('status');
    if (!status.classList.contains('hidden') && status.textContent === 'Loading...') {
      status.textContent = 'The API is still loading. Reload to retry, or use the guides and public source links above.';
    }
  }, 20000);
})();
