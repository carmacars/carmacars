// The feedback half of the motion kit (release 50, docs/changes/2026-11-25-r50-motion-complete.md): what a person sees
// after they press something, on every page and portal, with no per-page code. Portable: DOM only, no framework or brand
// import; a build talks to it through events and data attributes:
//   - window event "mo:action" {phase: 'start' | 'end'}: a request to the server began or answered (the build's fetch
//     wrapper sends it). The button pressed just before shows the busy state, then a success morph ("Saved" and a tick)
//     or, when an error appeared on the page, the error nudge. Only finishing actions morph (feedback.ts doneWord);
//     a button with data-mo-explicit is left to its component, which calls moResult() itself;
//   - moResult(button, ok, word?): the morph or the nudge, from a component that knows the answer (Act, SaveForm);
//   - nudge(el) and the element event "mo:nudge": the short shake (4 oscillations, 280 ms); a field that turns
//     aria-invalid after a press shakes by itself (the first of a form), a code field on a wrong code too;
//   - copy: navigator.clipboard.writeText answered: the pressed button says "Copied" with the icon swap;
//   - inline validation: a field left with a valid value that has a rule (required, type, pattern) gets a tick;
//   - prices and steppers ([data-mo-bump] and the build's list): a changed figure rolls in;
//   - a row removed from a list (one or two at once) collapses instead of vanishing;
//   - content that replaces a skeleton fades in; an empty state that appears pops its icon in once;
//   - bottom sheets on a phone (the build's list, modal dialogs) follow a drag down and close past a threshold;
//   - window event "mo:feedback" {kind: 'success' | 'error' | 'light'}: sent on each result, for the app's haptics.
// Everything that moves checks motionAllowed(); under reduced motion an error is colour and focus only, a success is
// the word and the tick without the pop. Nothing on screen at first paint is changed.
import { doneWord, isRemoval, SHAKE_MS } from './feedback.ts';

export interface FeedbackHooks {
  /** figures that roll when they change (prices, totals, a stepper's count) */
  bumps?: string;
  /** empty states whose icon pops in when they appear */
  empties?: string;
  /** sheets (besides modal dialogs on a phone) that follow a drag down */
  sheets?: string;
}

const allowed = () => typeof window !== 'undefined' && !window.matchMedia('(prefers-reduced-motion: reduce)').matches
  && document.documentElement.dataset.motion !== 'reduced';
const owned = (el: Element) => Object.keys(el).some((k) => k.startsWith('__reactFiber$'));
const shown = (el: Element | null | undefined): el is HTMLElement => !!el && el.isConnected && (el as HTMLElement).getClientRects().length > 0 && !el.closest('[hidden], [inert]');
const feedback = (kind: 'success' | 'error' | 'light') => { try { window.dispatchEvent(new CustomEvent('mo:feedback', { detail: { kind } })); } catch { /* old browser */ } };
const BTN = 'button, [role="button"], input[type="submit"], input[type="button"], a.btn';
const labelOf = (b: Element) => (b instanceof HTMLInputElement ? b.value : (b.getAttribute('aria-label') || b.textContent || '')).replace(/\s+/g, ' ').trim();

// ---------------------------------------------------------------- the nudge
/** The error nudge on one element (a field, a button): a short horizontal shake; nothing under reduced motion. */
export function nudge(el: Element | null | undefined) {
  if (!(el instanceof HTMLElement) || !allowed()) return;
  const now = Date.now();
  if (now - Number(el.dataset.moShakeAt ?? 0) < 400) return;
  el.dataset.moShakeAt = String(now);
  el.classList.remove('mo-shake'); void el.offsetWidth; el.classList.add('mo-shake');
  const end = () => el.classList.remove('mo-shake');
  el.addEventListener('animationend', end, { once: true }); window.setTimeout(end, SHAKE_MS + 120);
}

// ---------------------------------------------------------------- the success morph
const dialogOpener = new WeakMap<Element, HTMLElement>();
/** A button's answer: ok shows the word ("Saved") and a tick for a moment; not ok nudges it and rings it in the
 *  error colour. A button that is gone (its dialog closed) hands the morph to the button that opened the dialog. */
export function moResult(el: Element | null | undefined, ok: boolean, word?: string | null) {
  if (!el) return;
  let b = el as HTMLElement;
  if (!shown(b)) { const d = (el as Element).closest('dialog'); const o = d ? dialogOpener.get(d) : undefined; if (!shown(o)) return; b = o; }
  b.dataset.moResultAt = String(Date.now());
  window.clearTimeout(Number(b.dataset.moResultT ?? 0));
  if (ok) {
    const w = word ?? doneWord(labelOf(b)) ?? 'Done';
    const cs = getComputedStyle(b);
    if (cs.position === 'static') { b.style.position = 'relative'; b.dataset.moPos = '1'; }
    b.setAttribute('data-mo-done', w.replace(/\.$/, ''));
    b.setAttribute('data-mo-result', 'ok');
    feedback('success');
  } else {
    b.setAttribute('data-mo-result', 'error');
    nudge(b);
    feedback('error');
  }
  b.dataset.moResultT = String(window.setTimeout(() => {
    b.removeAttribute('data-mo-result'); b.removeAttribute('data-mo-done');
    if (b.dataset.moPos) { b.style.position = ''; delete b.dataset.moPos; }
  }, ok ? 1500 : 1200));
}

// the error texts on the page now (alerts and invalid fields), to tell a failed answer from a good one
const ERR = '[role="alert"], .alert--error, .ad-err, [aria-invalid="true"], .fg-summary';
function errorsNow(): Set<string> {
  const out = new Set<string>();
  document.querySelectorAll(ERR).forEach((e) => { if (shown(e)) out.add(`${e.tagName}|${e.id}|${(e.textContent ?? '').trim().slice(0, 140)}`); });
  return out;
}

/** Starts the feedback listeners; returns the function that stops them. */
export function startFeedback(hooks: FeedbackHooks = {}): () => void {
  const off: Array<() => void> = [];
  const on = <K extends string>(t: EventTarget, type: K, fn: (e: Event) => void, opts?: AddEventListenerOptions | boolean) => { t.addEventListener(type, fn, opts); off.push(() => t.removeEventListener(type, fn, opts)); };
  const bumpSel = ['[data-mo-bump]', hooks.bumps].filter(Boolean).join(',');
  const emptySel = ['[data-mo-empty]', hooks.empties].filter(Boolean).join(',');
  const sheetSel = ['[data-mo-sheet]', hooks.sheets].filter(Boolean).join(',');

  // the last press (a click on a button, or the button that sent a form)
  let last: { el: HTMLElement; at: number } | null = null;
  let touched = 0;
  on(document, 'click', (e) => {
    const b = (e.target as Element | null)?.closest?.<HTMLElement>(BTN);
    if (b) { last = { el: b, at: Date.now() }; touched = Date.now(); }
  }, true);
  on(document, 'submit', (e) => {
    touched = Date.now();
    const s = (e as SubmitEvent).submitter as HTMLElement | null ?? (e.target as HTMLFormElement).querySelector<HTMLElement>('button[type="submit"], button:not([type]), input[type="submit"]');
    if (s) last = { el: s, at: Date.now() };
  }, true);
  // Enter in a field sends its form (a submit event); other keys are typing, not a press
  on(document, 'keydown', (e) => { if ((e as KeyboardEvent).key === 'Enter') touched = Date.now(); }, true);

  // ---------------------------------------------------------------- server requests: busy, then the answer
  let active = 0;
  let run: { el: HTMLElement; before: Set<string>; busy: boolean } | null = null;
  on(window, 'mo:action', (e) => {
    const phase = (e as CustomEvent<{ phase?: string }>).detail?.phase;
    if (phase === 'start') {
      active++;
      if (run || !last || Date.now() - last.at > 1200 || !last.el.isConnected) return;
      const el = last.el; last = null;
      if (el.closest('[data-mo-explicit]')) return;
      const busy = !el.hasAttribute('aria-busy');
      if (busy) { el.setAttribute('aria-busy', 'true'); el.setAttribute('data-bl-busy', ''); el.setAttribute('data-mo-busy', ''); }
      run = { el, before: errorsNow(), busy };
    } else if (phase === 'end') {
      active = Math.max(0, active - 1);
      if (active || !run) return;
      const r = run; run = null;
      if (r.busy) { r.el.removeAttribute('data-mo-busy'); r.el.removeAttribute('data-bl-busy'); if (r.el.getAttribute('aria-busy') === 'true') r.el.removeAttribute('aria-busy'); }
      // React shows the answer a moment after the request ends
      window.setTimeout(() => {
        if (Number(r.el.dataset.moResultAt ?? 0) > Date.now() - 1500) return; // its component answered
        const now = errorsNow();
        const failed = [...now].some((k) => !r.before.has(k));
        if (failed) { moResult(r.el, false); const code = r.el.closest('form, [role="dialog"], dialog')?.querySelector('input[autocomplete="one-time-code"]'); if (code) nudge(code); return; }
        const w = doneWord(labelOf(r.el));
        if (w) moResult(r.el, true, w);
      }, 280);
    }
  });

  // ---------------------------------------------------------------- copy: "Copied" on the pressed button
  const clip = navigator.clipboard as (Clipboard & { writeText: (t: string) => Promise<void> }) | undefined;
  if (clip && typeof clip.writeText === 'function') {
    const real = clip.writeText;
    const wrapped = function (this: Clipboard, t: string) {
      const by = last && Date.now() - last.at < 1500 ? last.el : null;
      return real.call(clip, t).then((r) => { if (by) moResult(by, true, 'Copied'); return r; });
    };
    try { clip.writeText = wrapped; off.push(() => { if (clip.writeText === wrapped) clip.writeText = real; }); } catch { /* read-only in this browser */ }
  }

  // ---------------------------------------------------------------- inline validation: a tick on a good field left
  const RULED = 'input:not([type="checkbox"]):not([type="radio"]):not([type="file"]):not([type="range"]):not([type="color"]):not([type="hidden"]):not([type="search"]):not([type="date"]):not([type="datetime-local"]):not([type="time"]), textarea';
  const hasRule = (c: HTMLInputElement | HTMLTextAreaElement) => c.required || c.hasAttribute('pattern') || c.minLength > 0
    || (c instanceof HTMLInputElement && ['email', 'tel', 'url', 'number'].includes(c.type));
  on(document, 'focusout', (e) => {
    const c = e.target as HTMLInputElement | HTMLTextAreaElement;
    if (!(c instanceof HTMLElement) || !c.matches?.(RULED) || c.readOnly || c.disabled) return;
    if (c.value.trim() && hasRule(c) && c.validity.valid && c.getAttribute('aria-invalid') !== 'true') c.setAttribute('data-mo-valid', ''); else c.removeAttribute('data-mo-valid');
  }, true);
  on(document, 'input', (e) => { const c = e.target as Element; if (c instanceof HTMLElement && c.hasAttribute('data-mo-valid')) c.removeAttribute('data-mo-valid'); }, true);

  // ---------------------------------------------------------------- the nudge, asked for by any script
  on(document, 'mo:nudge', (e) => nudge(e.target as Element));

  // a dialog remembers the button that opened it (the morph goes there when the dialog closes on success)
  const opened = new MutationObserver((ms) => ms.forEach((m) => {
    const d = m.target as HTMLElement;
    if (d.tagName === 'DIALOG' && d.hasAttribute('open') && last && Date.now() - last.at < 1500 && !d.contains(last.el)) dialogOpener.set(d, last.el);
  }));
  opened.observe(document.body, { subtree: true, attributes: true, attributeFilter: ['open'] });
  off.push(() => opened.disconnect());

  // ---------------------------------------------------------------- what changes after a press
  let ready = false;
  const bumped = new WeakMap<Element, number>();
  const bump = (el: Element) => {
    if (!ready || !allowed() || !(el instanceof HTMLElement) || el.dataset.moCounting) return;
    const t = bumped.get(el) ?? 0; if (Date.now() - t < 320) return;
    bumped.set(el, Date.now());
    el.classList.remove('mo-bump'); void el.offsetWidth; el.classList.add('mo-bump');
    window.setTimeout(() => el.classList.remove('mo-bump'), 320);
  };
  const SKEL = /\b(skeleton|skp|sk-stack|sk-line|bl-sh|nav-skel)\b/;
  const isSkeleton = (n: Node) => n instanceof Element && (SKEL.test(n.className?.toString?.() ?? '') || n.hasAttribute('data-skeleton'));
  const ROWISH = (el: Element) => el.tagName === 'TR' || el.tagName === 'LI' || el.hasAttribute('data-mo-row') || !!el.parentElement?.matches('[data-mo-list]');
  const collapse = (gone: HTMLElement, parent: Element, next: Node | null) => {
    const h = gone.dataset.moH ? Number(gone.dataset.moH) : 0;
    if (!h || !parent.isConnected) return;
    const ghost = gone.cloneNode(true) as HTMLElement;
    ghost.setAttribute('aria-hidden', 'true'); ghost.setAttribute('inert', ''); ghost.removeAttribute('id');
    ghost.querySelectorAll('[id]').forEach((n) => n.removeAttribute('id'));
    ghost.classList.add('mo-collapse');
    ghost.style.setProperty('--mo-h', `${h}px`);
    try { parent.insertBefore(ghost, next && next.parentNode === parent ? next : null); } catch { return; }
    window.setTimeout(() => ghost.remove(), 300);
  };
  // the rows' heights, kept when they are pressed (the clone needs its height after it is gone)
  on(document, 'pointerdown', (e) => {
    const row = (e.target as Element | null)?.closest?.<HTMLElement>('tr, li, [data-mo-row]');
    if (row && ROWISH(row)) row.dataset.moH = String(Math.round(row.getBoundingClientRect().height));
  }, true);

  const mo = new MutationObserver((ms) => {
    if (!ready) return;
    const unskel = new Set<Node>();
    const perParent = new Map<Node, { removed: Array<{ el: HTMLElement; next: Node | null }>; added: number }>();
    for (const m of ms) {
      if (m.type === 'attributes') {
        const t = m.target as HTMLElement;
        // a field turned invalid after a press: the nudge (a code field on a wrong code, a field the app refused)
        if (m.attributeName === 'aria-invalid' && t.getAttribute('aria-invalid') === 'true' && Date.now() - touched < 4_000 && /^(INPUT|SELECT|TEXTAREA)$/.test(t.tagName)) {
          const scope = t.closest('form, dialog, [role="dialog"]') ?? document;
          const first = scope.querySelector('[aria-invalid="true"]');
          if (first === t || t.getAttribute('autocomplete') === 'one-time-code') nudge(t);
        }
        continue;
      }
      if (m.type === 'characterData') { const p = m.target.parentElement?.closest(bumpSel); if (p) bump(p); continue; }
      const entry = perParent.get(m.target) ?? { removed: [], added: 0 };
      m.removedNodes.forEach((n) => {
        if (isSkeleton(n) || (n instanceof Element && n.querySelector('[data-skeleton], .skp, .sk-stack'))) unskel.add(m.target);
        if (n instanceof HTMLElement && n.dataset.moH && ROWISH(n) && !n.classList.contains('mo-collapse')) entry.removed.push({ el: n, next: m.nextSibling });
      });
      m.addedNodes.forEach((n) => { if (n.nodeType === 1 && !(n as Element).classList.contains('mo-collapse')) entry.added++; });
      perParent.set(m.target, entry);
      if (m.target instanceof Element && bumpSel && m.target.closest(bumpSel) && m.addedNodes.length) bump(m.target.closest(bumpSel)!);
    }
    if (!allowed()) return;
    for (const [parent, e] of perParent) {
      if (isRemoval(e.removed.length, e.added) && parent instanceof Element && parent.isConnected) e.removed.forEach((r) => collapse(r.el, parent, r.next));
    }
    for (const m of ms) {
      if (m.type !== 'childList') continue;
      m.addedNodes.forEach((n) => {
        if (!(n instanceof HTMLElement) || !owned(n)) return;
        // content in place of a skeleton fades in
        if (unskel.has(m.target) && !isSkeleton(n)) { n.classList.remove('mo-fade-in'); void n.offsetWidth; n.classList.add('mo-fade-in'); }
        // an empty state that appears: its icon pops in, once
        if (emptySel) (n.matches(emptySel) ? [n] : [...n.querySelectorAll<HTMLElement>(emptySel)]).forEach((x) => x.classList.add('mo-appear'));
      });
    }
  });
  mo.observe(document.body, { subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: ['aria-invalid'] });
  off.push(() => mo.disconnect());

  // ---------------------------------------------------------------- bottom sheets: drag down to close (phones)
  const narrow = () => window.matchMedia('(max-width: 40rem)').matches;
  let drag: { el: HTMLElement; y0: number; t0: number; dy: number } | null = null;
  const sheetOf = (t: Element | null): HTMLElement | null => {
    if (!t || !narrow()) return null;
    const d = t.closest<HTMLElement>(`dialog[open]${sheetSel ? `, ${sheetSel}` : ''}`);
    if (!d || (d.tagName === 'DIALOG' && !d.matches(':modal')) || d.closest('[data-mo-sheet="off"]')) return null;
    return d;
  };
  // touch events, not pointer events: the browser takes a vertical pan for itself (pointercancel), touches keep coming
  on(document, 'touchstart', (e) => {
    const te = e as TouchEvent;
    if (te.touches.length !== 1) { drag = null; return; }
    const t = te.target as Element | null;
    const s = sheetOf(t); if (!s) return;
    // from the sheet's top part, or anywhere while its content is scrolled to the top (never from a field)
    const r = s.getBoundingClientRect(), y = te.touches[0]!.clientY;
    if (t?.closest('input, select, textarea, [contenteditable], .k-carousel, [data-mo-nodrag]')) return;
    if (y - r.top > 56 && s.scrollTop > 0) return;
    drag = { el: s, y0: y, t0: performance.now(), dy: 0 };
  }, { capture: true, passive: true });
  on(document, 'touchmove', (e) => {
    if (!drag) return;
    const dy = Math.max(0, (e as TouchEvent).touches[0]!.clientY - drag.y0);
    if (dy > 4 && drag.el.scrollTop <= 0) { drag.dy = dy; drag.el.classList.add('mo-dragging'); drag.el.style.translate = `0 ${dy}px`; }
  }, { capture: true, passive: true });
  const release = () => {
    if (!drag) return;
    const { el, dy, t0 } = drag; drag = null;
    el.classList.remove('mo-dragging');
    const v = dy / Math.max(1, performance.now() - t0);
    if (dy > 90 || (dy > 30 && v > 0.6)) {
      el.style.translate = '0 100%';
      window.setTimeout(() => {
        el.style.translate = '';
        if (el instanceof HTMLDialogElement) el.close();
        else el.querySelector<HTMLElement>('[data-close], [aria-label^="Close" i], .x, [class*="__x"]')?.click();
      }, 200);
      feedback('light');
    } else el.style.translate = '';
  };
  on(document, 'touchend', release, true); on(document, 'touchcancel', release, true);

  // ready after the first paint: from now on what is added or changed was caused by the person or the page's data
  const r = window.setTimeout(() => { ready = true; }, 600);
  off.push(() => window.clearTimeout(r));
  return () => off.forEach((f) => f());
}
