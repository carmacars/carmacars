/* Single-file build only: swaps <template data-view> into <main> by hash. */
(function () {
  'use strict';
  var CC = window.CC; var main = document.getElementById('main'); var first = true; var current = null;
  function photos(root) {
    root.querySelectorAll('[data-src]').forEach(function (el) { el.setAttribute('src', CC.photo(el.getAttribute('data-src'))); });
    root.querySelectorAll('[data-srcset]').forEach(function (el) { el.setAttribute('srcset', CC.photo(el.getAttribute('data-srcset'))); });
  }
  function toAnchor(id) { var t = id && document.getElementById(id); if (t) { t.scrollIntoView({ block: 'start', behavior: 'instant' }); return true; } return false; }
  function render() {
    var raw = location.hash;
    if (raw && raw.indexOf('#/') !== 0) return; // a plain in-page anchor, not a route
    var r = CC.route(); var key = r.page + '?' + r.query;
    var tpl = document.querySelector('template[data-view="' + r.page.replace(/"/g, '') + '"]') || document.querySelector('template[data-view="404.html"]');
    if (key === current && !first) { if (!toAnchor(r.anchor)) window.scrollTo({ top: 0, behavior: 'instant' }); return; }
    current = key;
    main.innerHTML = ''; main.appendChild(tpl.content.cloneNode(true));
    photos(main);
    document.title = tpl.dataset.title; document.body.className = tpl.dataset.body;
    var m = document.querySelector('meta[name="description"]'); if (m) m.setAttribute('content', tpl.dataset.desc);
    if (CC.closeMenu) CC.closeMenu();
    CC.markNav(tpl.dataset.view); CC.init(main);
    if (!toAnchor(r.anchor)) window.scrollTo({ top: 0, behavior: 'instant' });
    if (!first) main.focus({ preventScroll: true });
    first = false;
  }
  photos(document);
  CC.boot();
  window.addEventListener('hashchange', render);
  render();
})();
