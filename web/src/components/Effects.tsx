'use client';
import { usePathname } from 'next/navigation';
import { useEffect } from 'react';
import { motionOK } from '@/lib/motion';

// The site's motion runtime (src/styles/motion.css, docs/changes/2026-10-21-motion.md). One listener set for the
// whole app, no library:
// - scroll effects of the prototype (fx-*): scroll-driven animations natively, IntersectionObserver elsewhere;
// - page transitions: a link click inside the site runs as a View Transition (old page out, new page in) where the
//   browser has them, with a red progress line while the next page loads; elsewhere, or when the page takes longer
//   than the transition may wait, the new page settles in with a CSS entrance;
// - scroll reveals: cards and sections that are still below the viewport rise in once, staggered;
// - lazy images fade in from a blur when they arrive; numbers marked data-count count up when they come into view;
// - a ripple from the pointer on buttons.
// Nothing on screen at first paint is hidden or changed (no LCP or CLS cost), and nothing runs under
// prefers-reduced-motion (the end-to-end tests run that way).
const REVEAL = '.car-card, .section-head, .seq > li, .review, .twofacts > div, .band__copy, .how-full__step, .faq details, .pt-card, [data-reveal]';
const WAIT_MS = 220; // the longest a View Transition holds the old page while the next one loads

type DocVT = Document & { startViewTransition?: (cb: () => Promise<void>) => { finished: Promise<void>; ready: Promise<void> } };

export function Effects() {
  const path = usePathname();

  // prototype scroll effects (unchanged)
  useEffect(() => {
    document.documentElement.classList.add('js');
    const els = Array.from(document.querySelectorAll('.fx-wipe, .fx-line, .fx-grow-y'));
    const native = CSS.supports?.('animation-timeline: view()');
    const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (native || reduce || !('IntersectionObserver' in window)) { els.forEach((e) => e.classList.add('is-in')); return; }
    const io = new IntersectionObserver((es) => es.forEach((e) => { if (e.isIntersecting) { e.target.classList.add('is-in'); io.unobserve(e.target); } }), { rootMargin: '0px 0px -12% 0px', threshold: 0.08 });
    els.forEach((e) => io.observe(e));
    return () => io.disconnect();
  }, [path]);

  // page transitions: link clicks, back and forward
  useEffect(() => {
    if (!motionOK()) return;
    const bar = document.createElement('div'); bar.className = 'nav-progress'; bar.setAttribute('aria-hidden', 'true'); document.body.appendChild(bar);
    let timer = 0, raf = 0, resolve: (() => void) | null = null;
    const enter = () => {
      const main = document.getElementById('main'); if (!main) return;
      main.classList.remove('page-enter'); void main.offsetWidth; main.classList.add('page-enter');
      const off = () => main.classList.remove('page-enter');
      main.addEventListener('animationend', off, { once: true }); window.setTimeout(off, 700);
    };
    const stopBar = () => { window.clearTimeout(timer); if (bar.classList.contains('is-on')) { bar.classList.remove('is-on'); bar.classList.add('is-done'); } };
    // Next writes the new address when the new page is committed: that is the moment the page has changed
    const watch = (from: string, covered: { v: boolean }) => {
      cancelAnimationFrame(raf);
      const t0 = performance.now();
      const tick = () => {
        if (location.href !== from) {
          stopBar();
          if (resolve) resolve(); else if (!covered.v || performance.now() - t0 > WAIT_MS) enter();
          return;
        }
        if (performance.now() - t0 > 15000) { stopBar(); return; }
        raf = requestAnimationFrame(tick);
      };
      raf = requestAnimationFrame(tick);
    };
    const onClick = (e: MouseEvent) => {
      if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
      const a = (e.target as Element | null)?.closest?.('a[href]') as HTMLAnchorElement | null;
      if (!a || (a.target && a.target !== '_self') || a.hasAttribute('download') || a.dataset.noTransition !== undefined) return;
      const url = new URL(a.href, location.href);
      if (url.origin !== location.origin || url.pathname.startsWith('/api/') || /\.(pdf|xml|txt|csv|ics|zip|png|jpe?g|webp)$/i.test(url.pathname)) return;
      if (url.pathname === location.pathname && url.search === location.search) return; // a hash link or the same page
      window.clearTimeout(timer);
      timer = window.setTimeout(() => { bar.classList.remove('is-done'); void bar.offsetWidth; bar.classList.add('is-on'); }, 120);
      const covered = { v: false };
      const d = document as DocVT;
      if (d.startViewTransition && document.visibilityState === 'visible') {
        try {
          const t = d.startViewTransition(() => new Promise<void>((res) => {
            const done = () => { if (resolve === done) resolve = null; res(); };
            resolve = done; window.setTimeout(done, WAIT_MS);
          }));
          covered.v = true; t.ready.catch(() => {}); t.finished.catch(() => {});
        } catch { covered.v = false; }
      }
      watch(location.href, covered);
    };
    const onPop = () => { window.setTimeout(enter, 0); };
    document.addEventListener('click', onClick, true);
    window.addEventListener('popstate', onPop);
    return () => { document.removeEventListener('click', onClick, true); window.removeEventListener('popstate', onPop); window.clearTimeout(timer); cancelAnimationFrame(raf); bar.remove(); };
  }, []);

  // reveals, image fade-in, counters (and again for what client components add later)
  useEffect(() => {
    if (!motionOK() || !('IntersectionObserver' in window)) return;
    const vh = () => window.innerHeight || document.documentElement.clientHeight;
    const done = new WeakSet<Element>();
    const io = new IntersectionObserver((es) => {
      const inView = es.filter((e) => e.isIntersecting).map((e) => e.target as HTMLElement)
        .sort((x, y) => { const a = x.getBoundingClientRect(), b = y.getBoundingClientRect(); return a.top - b.top || a.left - b.left; });
      inView.forEach((el, i) => {
        io.unobserve(el);
        if (el.classList.contains('rv')) {
          el.style.setProperty('--rv-d', `${Math.min(i, 6) * 70}ms`);
          el.classList.add('is-in');
          const clean = () => { el.classList.remove('rv', 'is-in'); el.style.removeProperty('--rv-d'); };
          window.setTimeout(clean, 1300 + Math.min(i, 6) * 70);
        }
        if (el.dataset.count !== undefined) countUp(el);
      });
    }, { rootMargin: '0px 0px -8% 0px', threshold: 0.12 });

    const imgDone = (img: HTMLImageElement) => {
      img.classList.add('img-in');
      requestAnimationFrame(() => { img.classList.remove('img-wait'); window.setTimeout(() => img.classList.remove('img-in'), 950); });
    };
    const scan = () => {
      const h = vh();
      // read every position first, then write the classes (no forced layout between reads)
      const w = window.innerWidth || h;
      const later: HTMLElement[] = [];
      document.querySelectorAll<HTMLElement>(REVEAL).forEach((el) => {
        if (done.has(el)) return; done.add(el);
        if (el.closest('dialog, .popover, .filters, .menu-panel, [hidden]')) return;
        const r = el.getBoundingClientRect();
        // below the fold only, and never a card off to the side (a horizontal rail: it would wait for good)
        if (r.top > h && r.height > 0 && r.left < w && r.right > 0) later.push(el);
      });
      document.querySelectorAll<HTMLElement>('[data-count]').forEach((el) => {
        if (done.has(el)) return; done.add(el);
        if (el.getBoundingClientRect().top > h) io.observe(el);
      });
      later.forEach((el) => { el.classList.add('rv'); io.observe(el); });
      document.querySelectorAll<HTMLImageElement>('img[loading="lazy"]').forEach((img) => {
        if (done.has(img)) return; done.add(img);
        if (img.complete) return;
        img.classList.add('img-wait');
        const go = () => imgDone(img);
        img.addEventListener('load', go, { once: true }); img.addEventListener('error', go, { once: true });
      });
    };
    let raf = 0;
    const later = () => { if (!raf) raf = requestAnimationFrame(() => { raf = 0; scan(); }); };
    // the first scan when the browser is idle: off the hydration's main-thread work (only what is below the fold changes)
    const ric = typeof window.requestIdleCallback === 'function';
    const idle = ric ? window.requestIdleCallback(scan, { timeout: 600 }) : setTimeout(scan, 150);
    const mo = new MutationObserver(later);
    const main = document.getElementById('main');
    if (main) mo.observe(main, { childList: true, subtree: true });
    // a safety net: anything still waiting once it is above the bottom of the screen (a fast fling, a resize) shows
    let sraf = 0;
    const net = () => { if (sraf) return; sraf = requestAnimationFrame(() => {
      sraf = 0; const h = vh();
      document.querySelectorAll<HTMLElement>('.rv:not(.is-in)').forEach((el) => {
        if (el.getBoundingClientRect().top < h) { io.unobserve(el); el.classList.add('is-in'); window.setTimeout(() => el.classList.remove('rv', 'is-in'), 1300); }
      });
    }); };
    window.addEventListener('scroll', net, { passive: true });
    window.addEventListener('resize', net, { passive: true });
    return () => { if (ric) window.cancelIdleCallback(idle as number); else clearTimeout(idle as ReturnType<typeof setTimeout>); io.disconnect(); mo.disconnect(); cancelAnimationFrame(raf); cancelAnimationFrame(sraf); window.removeEventListener('scroll', net); window.removeEventListener('resize', net); };
  }, [path]);

  // ripple from the pointer on buttons
  useEffect(() => {
    if (!motionOK()) return;
    const on = (e: PointerEvent) => {
      const b = (e.target as Element | null)?.closest?.('.btn') as HTMLElement | null;
      if (!b || b.matches('[disabled], [aria-disabled="true"]')) return;
      const r = b.getBoundingClientRect();
      b.style.setProperty('--rx', `${e.clientX - r.left}px`); b.style.setProperty('--ry', `${e.clientY - r.top}px`);
      b.classList.remove('is-ripple'); void b.offsetWidth; b.classList.add('is-ripple');
      window.setTimeout(() => b.classList.remove('is-ripple'), 600);
    };
    document.addEventListener('pointerdown', on, { passive: true });
    return () => document.removeEventListener('pointerdown', on);
  }, []);

  return null;
}

// Counts the first number in the element up from zero, in the text node itself (React keeps its reference), and
// ends on the exact original text. The element keeps its width (it is a block, the digits are tabular).
function countUp(el: HTMLElement) {
  const w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
  let node: Text | null = null;
  while (w.nextNode()) { const t = w.currentNode as Text; if (/\d/.test(t.nodeValue ?? '')) { node = t; break; } }
  if (!node) return;
  const original = node.nodeValue ?? '';
  const m = original.match(/\d[\d,]*(\.\d+)?/); if (!m) return;
  const target = Number(m[0].replace(/,/g, '')); if (!Number.isFinite(target) || target === 0) return;
  const dec = m[1] ? m[1].length - 1 : 0; const grouped = m[0].includes(',');
  const before = original.slice(0, m.index), after = original.slice((m.index ?? 0) + m[0].length);
  const fmt = (v: number) => grouped ? v.toLocaleString('en-CA', { minimumFractionDigits: dec, maximumFractionDigits: dec }) : v.toFixed(dec);
  const t0 = performance.now(), dur = Math.min(1400, 700 + String(Math.round(target)).length * 120);
  el.classList.add('is-counting');
  let last = original;
  const step = (now: number) => {
    if (!node || node.nodeValue !== last) { el.classList.remove('is-counting'); return; } // React changed it: stop
    const p = Math.min(1, (now - t0) / dur); const e = 1 - Math.pow(1 - p, 3);
    last = p < 1 ? before + fmt(target * e) + after : original;
    node.nodeValue = last;
    if (p < 1) requestAnimationFrame(step); else el.classList.remove('is-counting');
  };
  requestAnimationFrame(step);
}
