// r48: the "squished text" check. squishScan runs inside the page (page.evaluate) and returns every place where text is
// squeezed: a word broken mid-word, a label with one word per line, a short button or chip that wraps, text cut off by
// its own box, a table cell too narrow for its words, text running past the window. Shared by scripts/squish-audit.mjs
// (the site-wide crawl) and tests/e2e/squish.spec.ts (a representative set of pages).
export function squishScan() {
  const vw = window.innerWidth;
  const out = [];
  const seen = new Set();
  const sel = (e) => {
    const parts = [];
    for (let n = e, i = 0; n && n.nodeType === 1 && n !== document.body && i < 4; n = n.parentElement, i++) {
      const c = String(n.getAttribute('class') || '').trim().split(/\s+/).filter(Boolean).slice(0, 3).join('.');
      parts.unshift(n.tagName.toLowerCase() + (n.id && !/\d{4,}/.test(n.id) ? '#' + n.id : '') + (c ? '.' + c : ''));
    }
    return parts.join(' > ');
  };
  const visible = (e) => {
    if (!(e instanceof Element)) return false;
    const st = getComputedStyle(e);
    if (st.display === 'none' || st.visibility === 'hidden' || Number(st.opacity) === 0) return false;
    const r = e.getBoundingClientRect();
    if (r.width < 1 || r.height < 1) return false;
    // clipped by an sr-only style
    if (st.position === 'absolute' && (st.clip === 'rect(0px, 0px, 0px, 0px)' || st.clipPath === 'inset(50%)')) return false;
    const th = e.closest('thead'); if (th && th.getBoundingClientRect().width <= 2) return false; // a table head hidden in the card layout
    return !e.closest('[aria-hidden="true"], [hidden], .vh, .sr-only, svg, script, style, noscript, [data-squish-skip]');
  };
  const add = (kind, el, text, extra = '') => {
    const key = kind + '|' + sel(el);
    if (seen.has(key)) return;
    seen.add(key);
    out.push({ kind, sel: sel(el), text: String(text).replace(/\s+/g, ' ').trim().slice(0, 50), extra });
  };
  const lineTops = (rects) => {
    const tops = [];
    for (const r of rects) if (r.width > 0.5 && r.height > 0.5 && !tops.some((t) => Math.abs(t - r.top) < r.height * 0.5)) tops.push(r.top);
    return tops;
  };
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  const range = document.createRange();
  let count = 0;
  for (let n = walker.nextNode(); n; n = walker.nextNode()) {
    const text = n.nodeValue.replace(/\s+/g, ' ').trim();
    if (text.length < 2) continue;
    const el = n.parentElement;
    if (!el || !visible(el)) continue;
    if (++count > 2500) break;
    const st = getComputedStyle(el);
    const fs = parseFloat(st.fontSize) || 16;
    range.selectNodeContents(n);
    const rects = [...range.getClientRects()];
    if (!rects.length) continue;
    const tops = lineTops(rects);
    const words = text.split(' ').filter((w) => w.length > 0);
    // 1. a word broken across lines (a long link or address on its own is allowed to break, anything else is a squeeze)
    if (tops.length > 1) {
      const raw = n.nodeValue;
      let idx = 0;
      let brokenWord = '';
      for (const w of raw.split(/\s+/)) {
        if (!w) continue;
        const at = raw.indexOf(w, idx); idx = at + w.length;
        if (w.length < 4 || w.length > 24 || /[@/:_\\\-\u2011(]|^\d|\d{5,}/.test(w)) continue; // a hyphenated word may break at its hyphen
        range.setStart(n, at); range.setEnd(n, at + w.length);
        if (lineTops([...range.getClientRects()]).length > 1) { brokenWord = w; break; }
      }
      if (brokenWord) add('word-broken', el, text, `"${brokenWord}" w=${Math.round(el.getBoundingClientRect().width)} fs=${fs}`);
      // 2. one word (or two) per line in a text of several words
      else if (words.length >= 3 && tops.length >= words.length - 1 && tops.length >= 3 && el.getBoundingClientRect().width < fs * 6.5) add('word-per-line', el, text, `${tops.length} lines w=${Math.round(el.getBoundingClientRect().width)}`);
      // 3. a short control or chip wrapping
      const ctl = el.closest('button, a[class*="btn"], [role="button"], [class*="chip"], [class*="badge"], [class*="pill"], [class*="tag"], th, [class*="tab"]');
      if (ctl && !ctl.closest('.hd-act, .gd-frame-links') && !/^(th|td)$/i.test(ctl.tagName) && text.length <= 22 && words.length <= 3 && tops.length >= 2 && ctl.textContent.trim().length <= 24) {
        if (ctl.getBoundingClientRect().width < fs * 8.5) add('wrap-short-control', ctl, ctl.textContent, `${tops.length} lines w=${Math.round(ctl.getBoundingClientRect().width)}`);
      }
    }
    // 4. a text box far narrower than a few characters while the text is longer
    const box = el.getBoundingClientRect();
    const widest = Math.max(...rects.map((r) => r.width));
    if (text.length >= 8 && box.width > 0 && box.width < fs * 2.2 && st.display !== 'inline' && !/^(td|th)$/i.test(el.tagName)) add('narrow-box', el, text, `w=${Math.round(box.width)} fs=${fs}`);
    if (text.length >= 8 && words.length >= 2 && widest < fs * 1.6 && tops.length >= 4) add('narrow-box', el, text, `widest line ${Math.round(widest)} fs=${fs}`);
    // 5. text past the window, or cut off by an ancestor that hides overflow
    const r0 = rects[0];
    if (r0.right > vw + 1 || r0.left < -1) {
      let scroller = false;
      for (let a = el; a && a !== document.documentElement; a = a.parentElement) { const o = getComputedStyle(a).overflowX; if (o === 'auto' || o === 'scroll') { scroller = true; break; } }
      if (!scroller && !el.closest('[class*="sr-only"], [class*="skip"], [class*="visually"], [style*="position: fixed"]')) add('past-window', el, text, `${Math.round(r0.left)}..${Math.round(r0.right)} in ${vw}`);
    }
    for (let a = el, i = 0; a && a !== document.body && i < 6; a = a.parentElement, i++) {
      const cs = getComputedStyle(a);
      if (a.matches('[class*="rail"], [class*="carousel"], [class*="slider"]')) break; // text scrolled out of view on purpose
      if (cs.overflowX === 'hidden' || cs.overflowX === 'clip') {
        const ar = a.getBoundingClientRect();
        const tr = rects.reduce((m, r) => ({ l: Math.min(m.l, r.left), r: Math.max(m.r, r.right) }), { l: 1e9, r: -1e9 });
        if (ar.width > 0 && (tr.r > ar.right + 2 || tr.l < ar.left - 2) && cs.textOverflow === 'ellipsis' && a.closest('label, th') && text.length <= 40) { add('truncated-label', a, a.textContent, `text ${Math.round(tr.l)}..${Math.round(tr.r)} in ${Math.round(ar.left)}..${Math.round(ar.right)}`); break; }
        if (ar.width > 0 && (tr.r > ar.right + 2 || tr.l < ar.left - 2) && !(cs.textOverflow === 'ellipsis' && a === el)) { add('clipped', a, text, `text ${Math.round(tr.l)}..${Math.round(tr.r)} in ${Math.round(ar.left)}..${Math.round(ar.right)}`); break; }
        if (a === el && cs.textOverflow === 'ellipsis' && el.scrollWidth > el.clientWidth + 1 && text.length <= 20 && el.closest('button, th, label, a[class*="btn"], [class*="chip"], [class*="badge"], [class*="pill"], [class*="tab"], [class*="label"]')) { add('truncated-label', el, text, `${el.clientWidth} of ${el.scrollWidth}`); break; }
      }
    }
  }
  // 6. table cells crushed
  for (const c of document.querySelectorAll('td, th')) {
    if (!visible(c)) continue;
    const t = c.textContent.replace(/\s+/g, ' ').trim();
    const w = c.getBoundingClientRect().width;
    const fs = parseFloat(getComputedStyle(c).fontSize) || 14;
    const longest = Math.max(0, ...t.split(' ').map((x) => x.length));
    if (t.length >= 6 && w > 0 && w < fs * 3.2 && longest >= 4) add('crushed-cell', c, t, `w=${Math.round(w)} fs=${fs}`);
  }
  // 7. a button or link-button whose content is wider than itself (text sticking out of the box)
  for (const b of document.querySelectorAll('button, a[class*="btn"], [role="button"], [class*="chip"], [class*="badge"], [class*="pill"]')) {
    if (!visible(b)) continue;
    const cs = getComputedStyle(b);
    if (!b.matches('.info__btn, .fleet-bar__toggle') && cs.overflowX === 'visible' && b.scrollWidth > b.clientWidth + 2 && b.clientWidth > 0 && b.textContent.trim().length > 0 && cs.display !== 'inline') add('control-overflow', b, b.textContent, `${b.clientWidth} of ${b.scrollWidth}`);
  }
  return out;
}

/** The pages of the public site that are the same for everyone. */
export const PUBLIC = ['/', '/cars', '/cars/mercedes-benz-c300', '/cars/tesla-model-3', '/cars/toyota/corolla', '/how-it-works', '/requirements', '/delivery', '/faq', '/contact', '/terms', '/privacy', '/cancellation-policy', '/list-your-car', '/investors', '/sign-in', '/create-account', '/reset-password', '/book', '/book/mercedes-benz-c300', '/about', '/careers', '/chauffeur', '/events', '/guides', '/car-rental', '/airport-car-rental', '/body-shop', '/detailing', '/gps-tracker', '/rent-vs-own', '/credit-card-rental-coverage', '/makes', '/choose-portal', '/my-request'];
