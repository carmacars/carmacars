// The investor video's stage (render.mjs drives it; docs/investor-video/script.md). The deck's own slides, moved by a
// frame clock: window.__init(timeline) lays them out, window.__seek(t) sets every style for the moment t (seconds), so
// the same t always gives the same picture. Nothing moves by itself: CSS animations and transitions are off.
(function () {
  'use strict';
  const clamp = (x) => (x < 0 ? 0 : x > 1 ? 1 : x);
  const outCubic = (x) => 1 - Math.pow(1 - clamp(x), 3);
  const inOut = (x) => { x = clamp(x); return x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2; };
  const PIECES = ['.dk-kicker', '.dk-title', '.dk-lead', '.dk-wordmark', '.dk-big', '.dk-card', '.dk-flow > li', '.dk-tbl thead tr', '.dk-tbl tbody tr',
    '.dk-body > .dk-list > li', '.dk-cols > .dk-list > li', '.dk-note', '.dk-shot', '.dk-feature__words > div', '.dk-legend', '.dk-chart', '.dk-stat > *',
    '.dk-calc__form > *', '.dk-calc__out > *', '.dk-noshot', '.dk-screen-only', '.dk-calc__table'].join(', ');
  const COUNT = '.dk-big, .dk-card h3, .dk-tbl td.n, .dk-tbl td.n b, .dk-flow b, .dk-stat b';
  const NUM = /^([^\d]*?)(\d[\d,]*(?:\.\d+)?)([\s\S]*)$/;
  const YEAR = /\b(19|20)\d\d\b|January|February|March|April|May|June|July|August|September|October|November|December/;

  let T = null;
  const layers = [];

  function prepare(slide, n) {
    const layer = document.createElement('div');
    layer.className = 'layer';
    layer.appendChild(slide);
    slide.querySelectorAll('.dk-foot__n').forEach((e) => e.setAttribute('data-n', String(n)));
    const all = Array.from(slide.querySelectorAll(PIECES));
    const set = new Set(all);
    const pieces = all.filter((el) => { for (let p = el.parentElement; p && p !== slide; p = p.parentElement) if (set.has(p)) return false; return true; });
    const counts = Array.from(slide.querySelectorAll(COUNT)).filter((el) => el.children.length === 0 && NUM.test(el.textContent || '') && !YEAR.test(el.textContent || ''))
      .map((el) => {
        const m = NUM.exec(el.textContent || '');
        const digits = m[2];
        const dec = (digits.split('.')[1] || '').length;
        const owner = pieces.find((p) => p.contains(el)) || null;
        return { el, text: el.textContent, pre: m[1], post: m[3], value: parseFloat(digits.replace(/,/g, '')), dec, commas: digits.includes(','), owner };
      }).filter((c) => c.value > 0);
    const bars = Array.from(slide.querySelectorAll('.dk-chart rect')).filter((r) => r.getAttribute('fill') !== '#F0F0F0');
    const imgs = Array.from(slide.querySelectorAll('.dk-shot img'));
    return { layer, slide, pieces, counts, bars, imgs };
  }

  window.__init = function (timeline) {
    T = timeline;
    const stage = document.getElementById('stage');
    const slides = Array.from(document.querySelectorAll('#deck .dk-slide'));
    slides.forEach((s, i) => { const L = prepare(s, i + 1); layers.push(L); stage.appendChild(L.layer); });
    const bar = document.createElement('div'); bar.id = 'bar'; stage.appendChild(bar);
    const black = document.createElement('div'); black.id = 'black'; stage.appendChild(black);
    return slides.length;
  };

  window.__ready = async function () {
    await document.fonts.ready;
    await Promise.all(Array.from(document.images).map((im) => (im.complete ? (im.decode ? im.decode().catch(() => {}) : null) : new Promise((r) => { im.onload = im.onerror = r; }))));
    return document.images.length;
  };

  // one piece's entrance: fade and rise, shots rise further and settle in scale
  function entrance(L, local, speed) {
    const n = L.pieces.length;
    const step = Math.min(0.085, 1.3 / Math.max(1, n)) * speed;
    const base = 0.2 * speed, dur = 0.55 * Math.max(0.6, speed);
    L.pieces.forEach((el, k) => {
      const p = outCubic((local - base - k * step) / dur);
      const shot = el.classList.contains('dk-shot');
      const dy = (1 - p) * (shot ? 60 : 28);
      const sc = shot ? 0.96 + 0.04 * p : 1;
      el.style.opacity = String(p);
      el.style.transform = p >= 1 ? '' : `translateY(${dy.toFixed(2)}px) scale(${sc.toFixed(4)})`;
      el.__at = base + k * step;
    });
    L.counts.forEach((c) => {
      const start = (c.owner && c.owner.__at !== undefined ? c.owner.__at : base) + 0.1 * speed;
      const p = outCubic((local - start) / (1.1 * Math.max(0.6, speed)));
      if (p >= 1) { if (c.el.textContent !== c.text) c.el.textContent = c.text; return; }
      const v = c.value * p;
      const s = c.commas ? v.toLocaleString('en-US', { minimumFractionDigits: c.dec, maximumFractionDigits: c.dec }) : v.toFixed(c.dec);
      c.el.textContent = c.pre + s + c.post;
    });
    const chart = L.slide.querySelector('.dk-chart');
    const c0 = chart && chart.__at !== undefined ? chart.__at : base;
    L.bars.forEach((r, k) => { const p = outCubic((local - c0 - 0.2 - k * 0.07) / 0.7); r.style.transform = `scaleY(${p.toFixed(4)})`; });
  }

  // where a layer is during its transition in (pIn) and out (pOut)
  function place(L, kind, pIn, pOut, z) {
    const st = L.layer.style;
    let x = 0, s = 1, o = 1, dim = 0;
    if (pIn < 1) {
      const e = inOut(pIn);
      if (kind === 'fade') o = e;
      else if (kind === 'slide' || kind === 'push') x = (1 - e) * 1920;
      else if (kind === 'zoom') { o = e; s = 1.08 - 0.08 * e; }
    }
    if (pOut > 0) {
      const e = inOut(pOut);
      if (kind === 'slide') { x = -e * 480; dim = e * 0.5; }
      else if (kind === 'push') x = -e * 1920;
      else if (kind === 'zoom') { s = 1 - 0.06 * e; o = 1 - e; }
    }
    st.display = 'block';
    st.zIndex = String(z);
    st.opacity = String(o);
    st.transform = x || s !== 1 ? `translateX(${x.toFixed(1)}px) scale(${s.toFixed(4)})` : '';
    st.filter = dim ? `brightness(${(1 - dim).toFixed(3)})` : '';
  }

  window.__seek = function (t) {
    const beats = T.beats;
    const on = new Set();
    for (let i = 0; i < beats.length; i++) {
      const b = beats[i];
      if (t < b.start || t >= b.end) continue;
      const L = layers[b.slide];
      const local = t - b.start;
      const pIn = i === 0 ? 1 : clamp(local / b.tin);
      const next = beats[i + 1];
      const pOut = next ? clamp((t - next.start) / next.tin) : 0;
      // the incoming layer is on top; its kind decides how both move
      place(L, b.kin, pIn, next ? 0 : 0, 10 + i);
      if (next && pOut > 0) place(L, next.kin, 1, pOut, 10 + i);
      entrance(L, local - (i === 0 ? 0 : b.tin * 0.45), b.speed);
      L.imgs.forEach((im) => { const k = clamp(local / (b.end - b.start)); im.style.transform = `scale(${(1 + 0.05 * k).toFixed(4)})`; });
      on.add(b.slide);
    }
    layers.forEach((L, i) => { if (!on.has(i)) L.layer.style.display = 'none'; });
    document.getElementById('bar').style.transform = `scaleX(${clamp(t / T.total).toFixed(5)})`;
    const fadeIn = 1 - clamp(t / 0.6), fadeOut = clamp((t - (T.total - 0.9)) / 0.9);
    document.getElementById('black').style.opacity = String(Math.max(fadeIn, fadeOut).toFixed(3));
    return on.size;
  };
})();
