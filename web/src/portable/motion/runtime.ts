// The micro-interaction runtime (release 48 AN): one listener set for the whole app, no library. Portable: DOM only, no
// framework or brand import; hooks are data attributes and roles, plus the selector lists a build passes in.
//   - motionAllowed(): the system setting and the page's pause control (html[data-motion="reduced"], WCAG 2.2.2);
//   - tabs: a pill that slides to the current tab ([role=tablist] and the build's tab bars);
//   - success ticks: a status that says "Saved" gets a tick (role=status, aria-live, the build's list);
//   - count-up: dashboard figures count up once when they come into view;
//   - stagger: list items added after the first paint rise in, one after another;
//   - press highlight: a soft flash from the pointer on buttons marked mo-ripple;
//   - drive-off: a cut-out car leaves its frame on hover (desktop) or once when scrolled into view (touch).
// Nothing on screen at first paint is hidden or moved (no layout shift); everything stops under reduced motion.

export interface MotionHooks {
  /** extra tab bars (each is the parent of its tabs) */
  tabs?: string;
  /** extra figures to count up */
  counters?: string;
  /** extra lists whose new items stagger in */
  lists?: string;
  /** extra save statuses */
  statuses?: string;
  /** extra carousels that rubber-band at their ends */
  carousels?: string;
}

const PAUSE_KEY = 'mo-motion';
export const motionAllowed = () => typeof window !== 'undefined' && !window.matchMedia('(prefers-reduced-motion: reduce)').matches
  && document.documentElement.dataset.motion !== 'reduced';

/** The pause control (WCAG 2.2.2): remembered per browser; returns the new state. */
export function setMotionPaused(paused: boolean): boolean {
  const html = document.documentElement;
  if (paused) html.dataset.motion = 'reduced'; else delete html.dataset.motion;
  try { localStorage.setItem(PAUSE_KEY, paused ? 'reduced' : 'full'); } catch { /* private mode */ }
  return paused;
}
export function motionPaused(): boolean { return document.documentElement.dataset.motion === 'reduced'; }
/** An inline script for <head>: the remembered choice before the first paint. */
export const MOTION_PAUSE_SCRIPT = `try{if(localStorage.getItem('${PAUSE_KEY}')==='reduced')document.documentElement.dataset.motion='reduced'}catch(e){}`;

// ---------------------------------------------------------------- hydration
// r48: a part streamed in after the shell (a loading.tsx boundary) sits in the page before React hydrates it, and the
// observer below sees it at once: a node added to it then (the tab pill, the burst) or a number counted up made React's
// hydration fail (React #418 on most portal pages, CI 44884254738). React marks each element it owns with a fiber key, so
// nothing is added or rewritten in an element without one; it is tried again a moment later.
export function hydrated(el: Element): boolean {
  return Object.keys(el).some((k) => k.startsWith('__reactFiber$'));
}
let later: (el: Element) => void = () => undefined;

// ---------------------------------------------------------------- tabs
const CURRENT = ':scope > :is([aria-current="page"],[aria-current="true"],[aria-selected="true"],[aria-pressed="true"],.is-on,.is-active)';
function placeTabs(bar: HTMLElement, target?: HTMLElement | null) {
  const cur = target ?? bar.querySelector<HTMLElement>(CURRENT);
  if (bar.dataset.moTabs === 'none') return;
  let ind = bar.querySelector<HTMLElement>(':scope > .mo-tab-ind');
  if (!cur) { ind?.remove(); return; }
  if (!ind) {
    if (!hydrated(bar)) { later(bar); return; }
    ind = document.createElement('span'); ind.className = 'mo-tab-ind'; ind.setAttribute('aria-hidden', 'true');
    // the current tab's own fill, handed to the pill
    const fill = getComputedStyle(cur).backgroundColor;
    bar.style.setProperty('--mo-tab-fill', fill && fill !== 'rgba(0, 0, 0, 0)' ? fill : 'currentColor');
    if (fill === 'rgba(0, 0, 0, 0)') { bar.dataset.moTabs = 'none'; return; } // no filled current tab: left as it is
    bar.prepend(ind); bar.dataset.moTabs = 'on';
  }
  const b = bar.getBoundingClientRect(), r = cur.getBoundingClientRect();
  const x = r.left - b.left + bar.scrollLeft, y = r.top - b.top, w = r.width;
  const prevW = Number(ind.dataset.w || 0);
  if (!prevW || !motionAllowed()) {
    ind.style.transition = 'none';
    Object.assign(ind.style, { width: `${w}px`, height: `${r.height}px`, transform: `translate(${x}px, ${y}px)` });
    ind.dataset.w = String(w); void ind.offsetWidth; ind.style.transition = '';
    return;
  }
  // slide: move and stretch with transform only; the width settles at the end without a transition
  ind.style.height = `${r.height}px`;
  ind.style.transform = `translate(${x}px, ${y}px) scaleX(${w / prevW})`;
  const done = () => { ind!.style.transition = 'none'; ind!.style.width = `${w}px`; ind!.style.transform = `translate(${x}px, ${y}px)`; ind!.dataset.w = String(w); void ind!.offsetWidth; ind!.style.transition = ''; };
  ind.addEventListener('transitionend', done, { once: true });
  window.setTimeout(done, 400);
}

// ---------------------------------------------------------------- count-up
function countUp(el: HTMLElement) {
  if (el.dataset.moCounted) return;
  if (!hydrated(el)) { later(el.parentElement ?? el); return; } // the parent: a rescan finds the counter inside it
  el.dataset.moCounted = '1';
  const node = [...el.childNodes].find((n) => n.nodeType === 3 && /\d/.test(n.nodeValue ?? '')) as Text | undefined;
  if (!node || el.children.length) return;
  const text = node.nodeValue ?? '';
  const m = /-?[\d,]*\.?\d+/.exec(text); if (!m) return;
  const target = Number(m[0].replace(/,/g, '')); if (!Number.isFinite(target) || target === 0) return;
  const dec = (m[0].split('.')[1] ?? '').length, comma = m[0].includes(',');
  const fmt = (v: number) => { const s = v.toFixed(dec); return comma ? Number(s).toLocaleString('en-US', { minimumFractionDigits: dec, maximumFractionDigits: dec }) : s; };
  const t0 = performance.now(), ms = 300;
  el.style.fontVariantNumeric = 'tabular-nums';
  const tick = (t: number) => {
    if (node.nodeValue !== text && !node.nodeValue?.startsWith(text.slice(0, m.index))) return; // the app changed it
    const p = Math.min(1, (t - t0) / ms), e = 1 - Math.pow(1 - p, 3);
    node.nodeValue = text.slice(0, m.index) + fmt(target * e) + text.slice(m.index + m[0].length);
    if (p < 1) requestAnimationFrame(tick); else node.nodeValue = text;
  };
  requestAnimationFrame(tick);
}

// ---------------------------------------------------------------- drive-off
function driveOff(root: HTMLElement) {
  if (!motionAllowed() || root.classList.contains('is-off')) return;
  root.classList.remove('is-back'); void root.offsetWidth; root.classList.add('is-off');
}
function driveBack(root: HTMLElement) {
  if (!root.classList.contains('is-off')) return;
  root.classList.remove('is-off'); root.classList.add('is-back');
  const end = () => root.classList.remove('is-back');
  root.addEventListener('animationend', end, { once: true }); window.setTimeout(end, 400);
}

/** Starts the runtime; returns a function that stops it. */
export function startMotion(hooks: MotionHooks = {}): () => void {
  const off: Array<() => void> = [];
  const tabSel = ['[role="tablist"]', '[data-mo-tablist]', hooks.tabs].filter(Boolean).join(',');
  const countSel = ['[data-count-up]', hooks.counters].filter(Boolean).join(',');
  const listSel = ['[data-mo-list]', hooks.lists].filter(Boolean).join(',');
  const statusSel = ['[role="status"]', '[aria-live="polite"]', hooks.statuses].filter(Boolean).join(',');
  const fine = window.matchMedia('(hover: hover) and (pointer: fine)').matches;

  // the remembered pause choice
  try { if (localStorage.getItem(PAUSE_KEY) === 'reduced') document.documentElement.dataset.motion = 'reduced'; } catch { /* private mode */ }

  // tabs: placed now, on resize, and slid on a click before the next page or panel shows
  const scanTabs = () => document.querySelectorAll<HTMLElement>(tabSel).forEach((b) => placeTabs(b));
  const onTabClick = (e: Event) => {
    const t = (e.target as Element | null)?.closest<HTMLElement>('a, button, [role="tab"]');
    const bar = t?.parentElement; if (!t || !bar || !bar.matches(tabSel) || bar.dataset.moTabs !== 'on') return;
    // the clicked tab looks current at once (the app sets it again when its page or panel shows)
    const old = bar.querySelector<HTMLElement>(':scope > [aria-current]');
    if (old && old !== t && t.tagName === 'A') { const v = old.getAttribute('aria-current')!; old.removeAttribute('aria-current'); t.setAttribute('aria-current', v); }
    placeTabs(bar, t);
  };
  document.addEventListener('click', onTabClick, true); off.push(() => document.removeEventListener('click', onTabClick, true));
  const onResize = () => scanTabs();
  window.addEventListener('resize', onResize, { passive: true }); off.push(() => window.removeEventListener('resize', onResize));

  // counters: once, when in view
  const io = 'IntersectionObserver' in window ? new IntersectionObserver((es) => es.forEach((e) => {
    if (!e.isIntersecting) return; io!.unobserve(e.target);
    const el = e.target as HTMLElement;
    if (el.classList.contains('mo-drive')) { if (!fine) { driveOff(el); window.setTimeout(() => driveBack(el), 700); } return; }
    if (motionAllowed()) countUp(el);
  }), { threshold: 0.6 }) : null;
  off.push(() => io?.disconnect());
  const watchCounters = (root: ParentNode) => { if (io && countSel) root.querySelectorAll<HTMLElement>(countSel).forEach((el) => { if (!el.dataset.moCounted && !el.hasAttribute('data-count')) io.observe(el); }); };

  // drive-off: hover on desktop, once in view on touch
  const watchDrives = (root: ParentNode) => root.querySelectorAll<HTMLElement>('.mo-drive:not([data-mo-drive])').forEach((el) => {
    el.dataset.moDrive = '1';
    const host = el.closest<HTMLElement>('[data-mo-drive-host]') ?? el;
    if (fine) {
      host.addEventListener('pointerenter', (e) => { if ((e as PointerEvent).pointerType === 'mouse') driveOff(el); });
      host.addEventListener('pointerleave', () => driveBack(el));
      host.addEventListener('focusin', () => driveOff(el)); host.addEventListener('focusout', () => driveBack(el));
    } else io?.observe(el);
  });

  // success ticks: a status that now says "Saved"
  const markSaved = (el: Element) => { if (el.children.length) return; // a plain-text status only (never a toast stack)
    if (/^\s*saved\b/i.test(el.textContent ?? '') && !el.querySelector('[data-mo-saved]')) (el as HTMLElement).setAttribute('data-mo-saved', ''); else if (!/^\s*saved\b/i.test(el.textContent ?? '')) el.removeAttribute('data-mo-saved'); };

  // a line drawing that has played: not again this session (a client navigation back mounts it again)
  const onDrawn = (e: AnimationEvent) => { if ((e.target as Element | null)?.classList?.contains('mo-draw__fill')) document.documentElement.dataset.moDraw = 'done'; };
  document.addEventListener('animationend', onDrawn); off.push(() => document.removeEventListener('animationend', onDrawn));

  // the press highlight
  const onDown = (e: PointerEvent) => {
    const b = (e.target as Element | null)?.closest<HTMLElement>('.mo-ripple'); if (!b || !motionAllowed()) return;
    const r = b.getBoundingClientRect();
    b.style.setProperty('--mo-x', `${e.clientX - r.left}px`); b.style.setProperty('--mo-y', `${e.clientY - r.top}px`);
    b.classList.remove('is-mo-pressed'); void b.offsetWidth; b.classList.add('is-mo-pressed');
  };
  document.addEventListener('pointerdown', onDown, { passive: true }); off.push(() => document.removeEventListener('pointerdown', onDown));

  // menus, popovers and dialogs grow from the element that opened them
  let lastTrigger: DOMRect | null = null;
  const onPress = (e: Event) => { const t = (e.target as Element | null)?.closest('button, summary, [aria-haspopup], [aria-expanded], a'); lastTrigger = t ? t.getBoundingClientRect() : null; };
  document.addEventListener('pointerdown', onPress, { capture: true, passive: true }); off.push(() => document.removeEventListener('pointerdown', onPress, { capture: true }));
  const popIn = (el: HTMLElement) => {
    if (!motionAllowed() || !lastTrigger) return;
    const r = el.getBoundingClientRect(); if (!r.width || !r.height) return;
    const x = Math.min(Math.max(lastTrigger.left + lastTrigger.width / 2 - r.left, 0), r.width), y = Math.min(Math.max(lastTrigger.top + lastTrigger.height / 2 - r.top, 0), r.height);
    el.style.setProperty('--mo-origin', `${Math.round(x)}px ${Math.round(y)}px`);
    el.classList.remove('mo-pop-in'); void el.offsetWidth; el.classList.add('mo-pop-in');
  };
  const pops = new MutationObserver((ms) => ms.forEach((m) => {
    const t = m.target as HTMLElement;
    if (m.type === 'attributes' && m.attributeName === 'open' && t.hasAttribute('open')) {
      if (t.tagName === 'DIALOG') popIn(t); else t.querySelectorAll<HTMLElement>(':scope > :not(summary)').forEach(popIn);
    }
  }));
  pops.observe(document.body, { subtree: true, attributes: true, attributeFilter: ['open'] }); off.push(() => pops.disconnect());

  // a burst on the big moments (a booking confirmed, a request sent): data-mo-burst on the heading
  const burst = (el: HTMLElement) => {
    if (el.dataset.moBurstDone || !motionAllowed()) return;
    if (!hydrated(el)) { later(el); return; }
    el.dataset.moBurstDone = '1';
    el.classList.add('mo-burst');
    for (let i = 0; i < 10; i++) {
      const p = document.createElement('span'); p.className = 'mo-burst__p'; p.setAttribute('aria-hidden', 'true');
      const a = (i / 10) * Math.PI * 2, d = 26 + (i % 3) * 8;
      p.style.setProperty('--bx', '1.2em'); p.style.setProperty('--by', '50%');
      p.style.setProperty('--dx', `${Math.round(Math.cos(a) * d)}px`); p.style.setProperty('--dy', `${Math.round(Math.sin(a) * d)}px`);
      el.appendChild(p); window.setTimeout(() => p.remove(), 400);
    }
  };

  // rubber band: a carousel pushed past its end gives a little, then springs back
  const onWheel = (e: WheelEvent) => {
    const t = (e.target as Element | null)?.closest<HTMLElement>(['.k-carousel', '[data-mo-rubber]', hooks.carousels].filter(Boolean).join(',')); if (!t || !motionAllowed() || Math.abs(e.deltaX) < Math.abs(e.deltaY)) return;
    const atStart = t.scrollLeft <= 0 && e.deltaX < 0, atEnd = t.scrollLeft + t.clientWidth >= t.scrollWidth - 1 && e.deltaX > 0;
    if (!atStart && !atEnd) return;
    t.classList.add('mo-rubber'); t.style.translate = `${Math.max(-18, Math.min(18, -e.deltaX * 0.25))}px 0`;
    window.clearTimeout(Number(t.dataset.moRubberT)); t.dataset.moRubberT = String(window.setTimeout(() => { t.style.translate = ''; }, 90));
  };
  document.addEventListener('wheel', onWheel, { passive: true }); off.push(() => document.removeEventListener('wheel', onWheel));

  // the attributes phones need, where a form left them out (the app's own values always win)
  const polish = (root: ParentNode) => root.querySelectorAll<HTMLInputElement | HTMLTextAreaElement>('input, textarea').forEach((el) => {
    if (el.dataset.moPolished) return;
    if (!hydrated(el)) { later(el.parentElement ?? el); return; }
    el.dataset.moPolished = '1';
    const t = (el.getAttribute('type') ?? 'text').toLowerCase(), name = `${el.name} ${el.id} ${el.getAttribute('autocomplete') ?? ''}`.toLowerCase();
    if (t === 'email' && !el.hasAttribute('autocomplete')) el.setAttribute('autocomplete', 'email');
    if (t === 'tel' && !el.hasAttribute('autocomplete')) el.setAttribute('autocomplete', 'tel');
    const step = el.getAttribute('step');
    if (t === 'number' && !el.hasAttribute('inputmode')) el.setAttribute('inputmode', step && step !== '1' ? 'decimal' : 'numeric');
    if (/(otp|one-time-code|sign-?in[-_ ]?code|sms[-_ ]?code|verify[-_ ]?code)/.test(name) && t !== 'hidden' && !el.hasAttribute('inputmode')) { el.setAttribute('inputmode', 'numeric'); if (!el.hasAttribute('autocomplete')) el.setAttribute('autocomplete', 'one-time-code'); }
    if (el.closest('[data-chat], .ccw-panel, .chat, [aria-label*="message" i]') && !el.hasAttribute('enterkeyhint')) el.setAttribute('enterkeyhint', 'send');
  });

  // what the app adds later: statuses, list items, counters, tab bars, cars
  let queued = false;
  const pending = new Set<Element>();
  const flush = () => {
    queued = false;
    const items = [...pending]; pending.clear();
    let i = 0, tabs = false;
    for (const n of items) {
      if (!n.isConnected) continue;
      const st = n.closest(statusSel); if (st) markSaved(st);
      if (listSel && n.parentElement?.matches(listSel) && motionAllowed() && n instanceof HTMLElement && hydrated(n)) { n.style.setProperty('--mo-i', String(Math.min(i++, 8))); n.classList.add('mo-stagger-in'); }
      watchCounters(n); watchDrives(n); polish(n);
      if (n.matches('[role="menu"], [role="listbox"], .mo-pop')) popIn(n as HTMLElement);
      (n.matches('[data-mo-burst]') ? [n] : [...n.querySelectorAll('[data-mo-burst]')]).forEach((b) => burst(b as HTMLElement));
      if (!tabs && (n.matches(tabSel) || !!n.closest(tabSel) || !!n.querySelector(tabSel))) tabs = true;
    }
    if (tabs) scanTabs();
  };
  // not hydrated yet: the element again in a moment (at most for ten seconds after it was first seen)
  const seen = new WeakMap<Element, number>();
  let retryT = 0;
  later = (el) => {
    const first = seen.get(el) ?? Date.now(); seen.set(el, first);
    if (Date.now() - first > 10_000) return;
    pending.add(el);
    if (!retryT) retryT = window.setTimeout(() => { retryT = 0; flush(); }, 250);
  };
  off.push(() => { window.clearTimeout(retryT); later = () => undefined; });
  const mo = new MutationObserver((ms) => {
    for (const m of ms) {
      if (m.type === 'characterData') { const p = m.target.parentElement; if (p) pending.add(p); continue; }
      m.addedNodes.forEach((n) => { if (n.nodeType === 1) pending.add(n as Element); else if (n.parentElement) pending.add(n.parentElement); });
    }
    if (!queued && pending.size) { queued = true; requestAnimationFrame(flush); }
  });
  mo.observe(document.body, { childList: true, subtree: true, characterData: true });
  off.push(() => mo.disconnect());

  // the first scan, when the browser is idle (off the hydration's main-thread work)
  const first = () => { scanTabs(); watchCounters(document); watchDrives(document); polish(document); document.querySelectorAll<HTMLElement>('[data-mo-burst]').forEach(burst); };
  const ric = (window as Window & { requestIdleCallback?: (cb: () => void, o?: { timeout: number }) => number }).requestIdleCallback;
  if (ric) ric(first, { timeout: 1200 }); else window.setTimeout(first, 200);
  return () => off.forEach((f) => f());
}
