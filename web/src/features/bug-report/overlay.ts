'use client';

// r50 (3900): "Report a bug" must work while a pop-up is open. A native modal dialog (showModal) makes everything outside it
// inert, so the header's button cannot be pressed; a sheet, drawer or panel can cover it. This finds the pop-up on top:
//   inside: a native modal dialog; the button is rendered inside it (the top layer), the only place not inert
//   above:  any other pop-up (aria-modal, or a dialog covering the header's button); the button is rendered at the end of
//           the page above everything (z-index), never inside a part a pop-up made inert
// The app lock (data-app-lock) is left alone: it is a security screen, not a pop-up.
export type Overlay = { el: HTMLElement; mode: 'inside' | 'above' };

const SKIP = '[data-bug-report-ui], [data-app-lock]';

function shown(el: Element): boolean {
  if (!(el instanceof HTMLElement) || el.closest(SKIP)) return false;
  if (!el.getClientRects().length) return false;
  const cs = getComputedStyle(el);
  return cs.visibility !== 'hidden' && cs.display !== 'none' && Number(cs.opacity) !== 0;
}

function onTop(el: HTMLElement): boolean {
  const r = el.getBoundingClientRect();
  const x = Math.min(Math.max(r.left + r.width / 2, 0), window.innerWidth - 1);
  const y = Math.min(Math.max(r.top + Math.min(r.height / 2, 40), 0), window.innerHeight - 1);
  const hit = document.elementFromPoint(x, y);
  return !!hit && el.contains(hit);
}

function modalDialogs(own: HTMLDialogElement | null): HTMLDialogElement[] {
  return Array.from(document.querySelectorAll<HTMLDialogElement>('dialog[open]')).filter((d) => d !== own && !d.closest(SKIP) && (() => { try { return d.matches(':modal'); } catch { return false; } })());
}

/** The pop-up the button must be shown in or above, or null when the header's button can be pressed. */
export function topOverlay(trigger: HTMLElement | null, own: HTMLDialogElement | null): Overlay | null {
  if (typeof document === 'undefined') return null;
  // the bug report form itself is open: nothing to add
  if (own?.open) return null;
  const modals = modalDialogs(own);
  if (modals.length) return { el: modals.find(onTop) ?? modals[modals.length - 1]!, mode: 'inside' };
  const ariaModal = Array.from(document.querySelectorAll<HTMLElement>('[aria-modal="true"]')).filter(shown);
  if (ariaModal.length) return { el: ariaModal[ariaModal.length - 1]!, mode: 'above' };
  if (!trigger) return null;
  // the header's button made inert by a pop-up, or covered by a drawer or panel
  if (trigger.closest('[inert]')) {
    const any = Array.from(document.querySelectorAll<HTMLElement>('[role="dialog"], dialog[open]')).filter(shown);
    return any.length ? { el: any[any.length - 1]!, mode: 'above' } : null;
  }
  const r = trigger.getBoundingClientRect();
  if (!r.width || !r.height || r.bottom < 0 || r.top > window.innerHeight) return null;
  const covering = Array.from(document.querySelectorAll<HTMLElement>('[role="dialog"], dialog[open]')).filter(shown);
  if (!covering.length || onTop(trigger)) return null;
  const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
  const by = covering.find((c) => hit && c.contains(hit));
  return by ? { el: by, mode: 'above' } : null;
}

function titleOf(el: HTMLElement): string {
  const by = el.getAttribute('aria-labelledby');
  const t = el.getAttribute('aria-label') || (by ? by.split(/\s+/).map((id) => document.getElementById(id)?.textContent ?? '').join(' ') : '')
    || el.querySelector('h1, h2, h3, legend')?.textContent || '';
  return t.replace(/\s+/g, ' ').trim().slice(0, 80);
}

/** The pop-ups open when the report was started, for its log: kind, title and test id ("" when none). The server
 *  cleans it again (logs.ts cleanContext) like every other fact the browser sends. */
export function describeOverlays(own: HTMLDialogElement | null): string {
  if (typeof document === 'undefined') return '';
  const seen = new Set<Element>();
  const out: string[] = [];
  const add = (el: HTMLElement, kind: string) => {
    if (seen.has(el) || el === own || el.closest(SKIP)) return;
    seen.add(el);
    const id = el.getAttribute('data-testid');
    out.push(`${kind}: ${titleOf(el) || 'untitled'}${id ? ` [${id}]` : ''}`);
  };
  modalDialogs(own).forEach((d) => add(d, 'modal dialog'));
  document.querySelectorAll<HTMLElement>('[aria-modal="true"]').forEach((el) => { if (shown(el)) add(el, 'modal'); });
  document.querySelectorAll<HTMLElement>('dialog[open], [role="dialog"]').forEach((el) => { if (shown(el)) add(el, 'panel'); });
  return out.slice(0, 5).join(' | ');
}
