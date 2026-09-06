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
  const exampleTabs = document.querySelector('.example-tabs');
  if (exampleTabs) {
    const tabs = [...exampleTabs.querySelectorAll('[role=tab]')];
    function select(tab, focus = false) {
      tabs.forEach(item => {
        const selected = item === tab;
        item.setAttribute('aria-selected', String(selected)); item.tabIndex = selected ? 0 : -1;
        document.getElementById(item.dataset.panel).hidden = !selected;
      });
      if (focus) tab.focus();
    }
    exampleTabs.hidden = false;
    select(tabs[0]);
    exampleTabs.addEventListener('click', event => {
      const tab = event.target.closest('[role=tab]');
      if (tab) select(tab);
    });
    exampleTabs.addEventListener('keydown', event => {
      const index = tabs.indexOf(document.activeElement);
      if (index < 0 || !['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
      event.preventDefault();
      const next = event.key === 'Home' ? 0 : event.key === 'End' ? tabs.length - 1
        : (index + (event.key === 'ArrowRight' ? 1 : tabs.length - 1)) % tabs.length;
      select(tabs[next], true);
    });
    function revealStreaming() {
      if (location.hash !== '#streaming') return;
      select(tabs.find(tab => tab.dataset.panel === 'streaming'));
      document.getElementById('streaming').scrollIntoView({behavior: 'instant'});
    }
    window.addEventListener('hashchange', revealStreaming);
    // Repeated clicks must also reveal a tab hidden since the last deep link.
    document.querySelectorAll('a[href="#streaming"]').forEach(link => link.addEventListener('click', () => {
      select(tabs.find(tab => tab.dataset.panel === 'streaming'));
    }));
    revealStreaming();
  }
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
      document.querySelector('#example-count').textContent = count + ' of ' + document.querySelectorAll('.example-card').length + ' examples';
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
