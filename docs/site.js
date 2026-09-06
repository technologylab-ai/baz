/* Progressive enhancements; all guides and examples remain usable without JS. */
(() => {
  'use strict';
  const menu = document.querySelector('.mobile-menu');
  const nav = document.querySelector('#navigation');
  function closeMenu() { nav.classList.remove('is-open'); menu.setAttribute('aria-expanded', 'false'); }
  menu?.addEventListener('click', () => {
    const open = nav.classList.toggle('is-open'); menu.setAttribute('aria-expanded', String(open));
  });
  nav?.addEventListener('click', event => { if (event.target.closest('a')) closeMenu(); });
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape' && nav?.classList.contains('is-open')) { closeMenu(); menu.focus(); }
  });
  document.querySelectorAll('pre code').forEach(code => {
    if (window.hljs) hljs.highlightElement(code);
    const button = code.closest('.codebox')?.querySelector('.copy');
    button?.addEventListener('click', async () => {
      try { await navigator.clipboard.writeText(code.textContent); button.textContent = 'Copied'; }
      catch (_) { button.textContent = 'Select to copy'; }
    });
    if (button) button.hidden = false;
  });
  const filters = document.querySelector('.filter-bar');
  if (filters) {
    filters.hidden = false;
    filters.addEventListener('click', event => {
      const button = event.target.closest('button[data-filter]');
      if (!button) return;
      filters.querySelectorAll('button').forEach(item => item.setAttribute('aria-pressed', String(item === button)));
      let count = 0;
      document.querySelectorAll('.example-card').forEach(card => {
        card.hidden = button.dataset.filter !== 'all' && card.dataset.group !== button.dataset.filter;
        if (!card.hidden) count++;
      });
      document.querySelector('#example-count').textContent = count + ' of 20 examples';
    });
  }
  if ('IntersectionObserver' in window && document.querySelector('.hero')) {
    const observer = new IntersectionObserver(entries => {
      for (const entry of entries) if (entry.isIntersecting) {
        nav.querySelectorAll('a').forEach(link => {
          if (link.hash === '#' + entry.target.id) link.setAttribute('aria-current', 'location');
          else link.removeAttribute('aria-current');
        });
      }
    }, {rootMargin: '-10% 0px -60% 0px'});
    document.querySelectorAll('section[id]').forEach(section => observer.observe(section));
  }
})();
