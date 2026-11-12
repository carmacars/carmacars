// The form guard on the page (r40-forms). One set of listeners on the document covers every form of the site, so no form needs
// its own code: when a form cannot be sent, the person sees (a) a summary near the submit button that lists what is missing or
// wrong, (b) each such field with aria-invalid, a red outline and a short message under it, and (c) the page scrolled to the
// first one with the focus in it.
//
// Where the problems come from, in one pass over the form after an attempt (a submit, a failed browser check, a click on a button
// of the form):
//   1. the browser's own check (required, type, pattern, length, range): forms without noValidate are stopped by the browser, whose
//      one-field bubble is replaced by this; a form with noValidate is stopped here before its handler when a visible field fails;
//   2. fields the form itself marked aria-invalid (the wizards, the contact forms, Act and SaveForm): listed in the summary with
//      the message the form wrote under them, and focused;
//   3. an error message the server sent, shown by the form as an alert: the field whose label the message names is marked.
// The guard is purely additive (r41): it never calls preventDefault or stopPropagation, so the browser's and the app's own
// validation and handlers run as without it; a form that shows its own errors (noValidate, aria-invalid set by the app) gets only
// the summary and the focus. The summary lists field LABELS (the message is under the field), so no message appears twice.
// A button outside any form (a wizard's Next) is covered too: the scope is the nearest block around it that holds fields.
// A form opts out with data-form-guard="off". The words and the matching are in guard.ts (unit tested).
import { cleanLabel, fieldsNamedIn, humanName, problemSig, summaryTitle, validityMessage, type ControlFacts, type FieldRef, type Problem } from './guard';

type Control = HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement;
interface State {
  native: boolean; button: Element | null; until: number; focusPending: boolean; seen: Set<string>; stale: Set<string>; forced: Set<Element>;
  dismissed: WeakMap<Element, string>; obs: MutationObserver; timer: number | undefined; beganAt: number;
}

const WINDOW_MS = 10_000;
const states = new WeakMap<Scope, State>();
let counter = 0;

const off = (form: Scope) => form.dataset.formGuard === 'off';
type Scope = HTMLElement;
const FIELDS = 'input:not([type="hidden"]):not([type="submit"]):not([type="button"]), select, textarea';
/** The form of an element; for a button outside any form, the nearest block around it that holds fields. */
const formOf = (el: Element | null): Scope | null => {
  if (!el) return null;
  const f = (el as Control).form ?? el.closest('form');
  if (f) return f;
  if (el.closest('header, footer, nav, [role="dialog"], [data-fg]')) return null;
  for (let n = el.parentElement; n && n !== document.body; n = n.parentElement) if (n.querySelector(FIELDS)) return n;
  return null;
};
/** The scope with a running state that holds this element (a field of a wizard has no form). */
const stateOwner = (el: Element): Scope | null => { for (let n: Element | null = el; n; n = n.parentElement) if (states.has(n as Scope)) return n as Scope; return null; };
const isControl = (el: Element): el is Control => /^(INPUT|SELECT|TEXTAREA)$/.test(el.tagName) && !['hidden', 'submit', 'button', 'reset', 'image'].includes((el as HTMLInputElement).type);
const visible = (el: Element) => (el as HTMLElement).getClientRects().length > 0 && getComputedStyle(el).visibility !== 'hidden' && !el.closest('[hidden], [inert]');
const ensureId = (el: Element): string => { if (!el.id) el.id = `fg-${++counter}`; return el.id; };
const reduceMotion = () => { try { return matchMedia('(prefers-reduced-motion: reduce)').matches; } catch { return false; } };
const text = (el: Element | null) => (el?.textContent ?? '').replace(/\s+/g, ' ').trim();

function kindOf(c: Control): ControlFacts['kind'] {
  if (c.tagName === 'SELECT') return 'select';
  if (c.tagName === 'TEXTAREA') return 'textarea';
  const t = (c as HTMLInputElement).type;
  return (['email', 'url', 'tel', 'number', 'date', 'checkbox', 'radio', 'file'].includes(t) ? t : 'text') as ControlFacts['kind'];
}

function labelOf(el: Element): string {
  const kind = isControl(el) ? kindOf(el) : 'other';
  const legend = () => text(el.closest('fieldset')?.querySelector('legend') ?? null);
  if (kind === 'radio' && legend()) return cleanLabel(legend());
  const labels = (el as Control).labels;
  const l = labels && labels[0];
  if (l) {
    const c = l.cloneNode(true) as HTMLElement;
    c.querySelectorAll('input, select, textarea, button, .opt, [data-fg]').forEach((n) => n.remove());
    const t = cleanLabel(c.textContent ?? '');
    if (t) return t;
  }
  const aria = el.getAttribute('aria-label');
  if (aria) return cleanLabel(aria);
  const by = el.getAttribute('aria-labelledby');
  if (by) { const t = cleanLabel(by.split(/\s+/).map((i) => text(document.getElementById(i))).join(' ')); if (t) return t; }
  if (legend()) return cleanLabel(legend());
  const ph = el.getAttribute('placeholder')?.trim();
  if (ph) return cleanLabel(ph);
  const n = el.getAttribute('name');
  if (n) { const h = humanName(n); return h.charAt(0).toUpperCase() + h.slice(1); }
  return '';
}

/** The message the form itself wrote for a field it marked aria-invalid (its describedby error, or the error in its field). */
function appMessage(el: Element): string {
  for (const id of (el.getAttribute('aria-describedby') ?? '').split(/\s+/).filter(Boolean)) {
    const n = document.getElementById(id);
    if (n && !n.hasAttribute('data-fg') && n.matches('.error, [role="alert"], [id$="-err"]') && text(n)) return text(n);
  }
  const f = el.closest('.field, fieldset');
  const e = f ? Array.from(f.querySelectorAll('.error')).find((n) => !n.hasAttribute('data-fg') && text(n)) : undefined;
  return e ? text(e) : ((el as Control).validationMessage || 'Check this field.');
}

const NOT_STEP = (v: ValidityState) => v.valueMissing || v.typeMismatch || v.patternMismatch || v.badInput || v.rangeUnderflow || v.rangeOverflow || v.tooShort || v.tooLong || v.customError;
function nativeMessage(c: Control): string {
  const v = c.validity;
  return validityMessage(v, { kind: kindOf(c), min: (c as HTMLInputElement).min || undefined, max: (c as HTMLInputElement).max || undefined,
    minLength: (c as HTMLInputElement).minLength > 0 ? (c as HTMLInputElement).minLength : undefined, maxLength: (c as HTMLInputElement).maxLength > 0 ? (c as HTMLInputElement).maxLength : undefined,
    title: c.getAttribute('title') ?? undefined, message: c.validationMessage || undefined });
}
const failsNative = (c: Control, st: State) => c.willValidate && !c.validity.valid && visible(c) && (NOT_STEP(c.validity) || st.forced.has(c));

/** The alerts a form shows (a server error, a failed save): not the field messages and not the guard's own parts. */
function alertsOf(form: Scope): Array<{ el: Element; text: string }> {
  const out: Array<{ el: Element; text: string }> = [];
  form.querySelectorAll('[role="alert"], .alert--error').forEach((el) => {
    if (el.hasAttribute('data-fg') || el.closest('[data-fg]') || el.classList.contains('error') || el.closest('.error')) return;
    const t = text(el);
    if (t) out.push({ el, text: t });
  });
  return out;
}

function clearMark(c: Element) {
  const own = c as HTMLElement;
  if (!own.hasAttribute('data-fg-own')) return;
  own.removeAttribute('data-fg-own'); own.removeAttribute('aria-invalid'); own.classList.remove('fg-invalid');
  const d = own.dataset.fgDesc; delete own.dataset.fgDesc;
  if (d) own.setAttribute('aria-describedby', d); else own.removeAttribute('aria-describedby');
  document.getElementById(`${own.id}-fgerr`)?.remove();
}

function applyMark(c: Control, message: string, src: 'native' | 'server') {
  const id = ensureId(c);
  const eid = `${id}-fgerr`;
  if (!c.hasAttribute('data-fg-own')) {
    c.setAttribute('data-fg-own', '1'); c.dataset.fgDesc = c.getAttribute('aria-describedby') ?? '';
    c.setAttribute('aria-invalid', 'true'); c.classList.add('fg-invalid');
    if (src === 'native') c.setAttribute('aria-describedby', [c.dataset.fgDesc, eid].filter(Boolean).join(' '));
  }
  c.dataset.fgSrc = src; c.dataset.fgMsg = message;
  // a server message is already on the page as the form's own alert: the field is marked, the words are not repeated
  if (src === 'server') return;
  let m = document.getElementById(eid);
  if (!m) {
    m = document.createElement('p'); m.id = eid; m.className = 'error fg-msg'; m.setAttribute('data-fg', '');
    const k = kindOf(c);
    const box = k === 'radio' || k === 'checkbox' ? c.closest('fieldset') : c.closest('.field');
    if (box && box !== c) box.appendChild(m); else (c.closest('label') ?? c).insertAdjacentElement('afterend', m);
  }
  if (m.textContent !== message) m.textContent = message;
}

function submitSpot(form: Scope, hint: Element | null): { parent: Node; before: Node | null } {
  const btns = Array.from(form.querySelectorAll<HTMLElement>('button[type="submit"], input[type="submit"], button:not([type])')).filter((b) => !b.closest('[data-fg]'));
  const b = form instanceof HTMLFormElement ? btns[btns.length - 1] : (hint instanceof HTMLElement && form.contains(hint) ? hint : btns[btns.length - 1]);
  if (!b) return { parent: form, before: null };
  let anchor: HTMLElement = b;
  while (anchor.parentElement && anchor.parentElement !== form && anchor.parentElement.children.length <= 3 && !anchor.parentElement.matches('.field, fieldset, .ad-fields')) anchor = anchor.parentElement;
  return { parent: anchor.parentNode ?? form, before: anchor };
}

function renderSummary(form: Scope, problems: Problem[], hint: Element | null) {
  let box = form.querySelector<HTMLElement>('.fg-summary');
  if (!problems.length) { box?.remove(); return; }
  const sig = problemSig(problems);
  if (box && box.dataset.sig === sig) return;
  const fresh = !box;
  if (!box) {
    box = document.createElement('div'); box.className = 'alert fg-summary'; box.setAttribute('data-fg', ''); box.setAttribute('role', 'status'); box.setAttribute('aria-live', 'assertive'); box.tabIndex = -1;
  }
  box.dataset.sig = sig;
  box.replaceChildren();
  const title = document.createElement('span'); title.className = 'alert__title'; title.textContent = summaryTitle(problems.length);
  const ul = document.createElement('ul'); ul.className = 'fg-summary__list';
  for (const p of problems) {
    const li = document.createElement('li'); const a = document.createElement('a');
    a.href = `#${p.id}`; a.setAttribute('data-fg-go', p.id); a.textContent = p.label || 'This field'; li.appendChild(a); ul.appendChild(li);
  }
  box.append(title, ul);
  if (fresh) { const s = submitSpot(form, hint); s.parent.insertBefore(box, s.before); }
}

/** Scroll to the field and put the focus in it. */
export function goTo(id: string) {
  const el = document.getElementById(id) as HTMLElement | null;
  if (!el) return;
  (el.closest('.field, label, fieldset') ?? el).scrollIntoView({ block: 'center', behavior: reduceMotion() ? 'auto' : 'smooth' });
  try { el.focus({ preventScroll: true }); } catch { /* a field that cannot take the focus */ }
}

const OBS: MutationObserverInit = { childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: ['aria-invalid'] };

function evaluate(form: Scope) {
  const st = states.get(form);
  if (!st) return;
  st.timer = undefined;
  const expired = Date.now() > st.until;
  if (expired) st.focusPending = false;
  st.obs.disconnect();
  let count = 0;
  try {
    const controls = Array.from(form.querySelectorAll<Element>('input, select, textarea')).filter(isControl);
    const alerts = alertsOf(form);
    const desired = new Map<Control, { message: string; stale: boolean; src: 'native' | 'server' }>();
    if (st.native && form instanceof HTMLFormElement && !form.noValidate) {
      const groups = new Set<string>();
      for (const c of controls) {
        if (!failsNative(c, st)) continue;
        if (c.type === 'radio') { if (groups.has(c.name)) continue; groups.add(c.name); }
        desired.set(c, { message: nativeMessage(c), stale: false, src: 'native' });
      }
    }
    const refs: FieldRef[] = controls.filter((c) => !desired.has(c) && visible(c)).map((c) => ({ id: ensureId(c), label: labelOf(c), name: c.name || undefined }));
    for (const a of alerts) {
      for (const id of fieldsNamedIn(a.text, refs)) {
        const c = document.getElementById(id) as Control | null;
        if (c && st.dismissed.get(c) !== a.text && !desired.has(c)) desired.set(c, { message: a.text, stale: st.stale.has(a.text), src: 'server' });
      }
    }
    for (const c of controls) if (c.hasAttribute('data-fg-own') && !desired.has(c)) clearMark(c);
    for (const [c, d] of desired) applyMark(c, d.message, d.src);

    const problems: Array<Problem & { stale: boolean }> = [];
    const seenIds = new Set<string>();
    form.querySelectorAll<Element>('input, select, textarea, [aria-invalid="true"]').forEach((el) => {
      if (el.hasAttribute('data-fg') || el.closest('[data-fg]')) return;
      const d = isControl(el) ? desired.get(el) : undefined;
      const flagged = el.getAttribute('aria-invalid') === 'true';
      if (!d && !(flagged && !el.hasAttribute('data-fg-own'))) return;
      const id = ensureId(el);
      if (seenIds.has(id)) return;
      seenIds.add(id);
      problems.push({ id, label: labelOf(el), message: d ? d.message : appMessage(el), stale: d?.stale ?? false });
    });
    count = problems.length;
    renderSummary(form, problems, st.button);

    // focus: once for an attempt (the first problem), and again for a problem that appears later (a server answer)
    const keys = problems.map((p) => `${p.id}|${p.message}`);
    const fresh = problems.filter((p, i) => !st.seen.has(keys[i]!) && !p.stale);
    keys.forEach((k) => st.seen.add(k));
    const pick = st.focusPending ? problems.find((p) => !p.stale) : fresh[0];
    if (pick) { st.focusPending = false; goTo(pick.id); }
    else if (!problems.length) {
      const a = alerts.find((x) => !st.stale.has(x.text) && !st.seen.has(`alert|${x.text}`));
      if (a) a.el.scrollIntoView({ block: 'nearest', behavior: reduceMotion() ? 'auto' : 'smooth' });
    }
    for (const a of alerts) st.seen.add(`alert|${a.text}`);
  } finally {
    if (!expired || count > 0) st.obs.observe(form, OBS);
  }
  if (expired && count === 0) { states.delete(form); return; }
  if (!expired) st.timer = window.setTimeout(() => schedule(form, 0), Math.max(50, st.until - Date.now() + 50));
}

function schedule(form: Scope, delay = 80) {
  const st = states.get(form);
  if (!st) return;
  if (st.timer !== undefined) clearTimeout(st.timer);
  st.timer = window.setTimeout(() => evaluate(form), delay);
}

function begin(form: Scope, native: boolean, button: Element | null = null): State {
  let st = states.get(form);
  if (!st) {
    const obs = new MutationObserver(() => schedule(form));
    st = { native: false, button: null, until: 0, focusPending: false, seen: new Set(), stale: new Set(), forced: new Set(), dismissed: new WeakMap(), obs, timer: undefined, beganAt: 0 };
    states.set(form, st);
  }
  st.button = button; st.beganAt = Date.now(); st.until = Date.now() + WINDOW_MS; st.focusPending = true; st.dismissed = new WeakMap(); st.seen = new Set();
  if (native) st.native = true;
  st.stale = new Set(alertsOf(form).map((a) => a.text));
  schedule(form, 0);
  window.setTimeout(() => schedule(form, 0), 400);
  return st;
}

let installed = false;
/** Install the listeners once (FormGuard.tsx, in the root layout). Returns the function that removes them. */
export function installFormGuard(): () => void {
  if (installed || typeof document === 'undefined') return () => undefined;
  installed = true;
  // the browser's check failed on a field (the browser still shows its own bubble and stops the send; the guard lists every field)
  const onInvalid = (e: Event) => {
    const c = e.target as Element;
    const form = formOf(c);
    if (!form || off(form)) return;
    const st = states.get(form);
    if (!st || Date.now() - st.beganAt > 200) begin(form, true).forced.add(c); else { st.native = true; st.forced.add(c); }
  };
  // a send: the app's own checks run as usual (the guard is first in line but changes nothing); its errors are listed when they appear
  const onSubmit = (e: Event) => {
    const form = e.target as HTMLFormElement;
    if (!(form instanceof HTMLFormElement) || off(form) || form.method === 'dialog') return;
    begin(form, false);
  };
  // a click on a button of a form that is not a submit (a wizard's Next): the form's own errors are listed too
  const onClick = (e: Event) => {
    const b = (e.target as Element | null)?.closest?.('button, [role="button"]');
    if (!b) return;
    if (b.closest('[data-fg]')) return;
    const form = formOf(b);
    if (!form || off(form) || (b as HTMLButtonElement).type === 'submit' || !form.contains(b)) return;
    if ((b as HTMLButtonElement).type === 'reset') return;
    begin(form, false, b);
  };
  // the person fixes a field: its mark goes, the summary follows
  const onEdit = (e: Event) => {
    const c = e.target as Element;
    const form = stateOwner(c);
    const st = form && states.get(form);
    if (!form || !st) return;
    // a server message that named this field is answered by the edit: it stays off the field until the next attempt
    if (c.hasAttribute('data-fg-own') && (c as HTMLElement).dataset.fgSrc === 'server') st.dismissed.set(c, (c as HTMLElement).dataset.fgMsg ?? '');
    schedule(form);
  };
  const onGo = (e: Event) => {
    const a = (e.target as Element | null)?.closest?.('a[data-fg-go]');
    if (!a) return;
    e.preventDefault();
    goTo(a.getAttribute('data-fg-go') ?? '');
  };
  document.addEventListener('invalid', onInvalid, true);
  document.addEventListener('submit', onSubmit, true);
  document.addEventListener('click', onClick, true);
  document.addEventListener('click', onGo);
  document.addEventListener('input', onEdit, true);
  document.addEventListener('change', onEdit, true);
  return () => {
    installed = false;
    document.removeEventListener('invalid', onInvalid, true);
    document.removeEventListener('submit', onSubmit, true);
    document.removeEventListener('click', onClick, true);
    document.removeEventListener('click', onGo);
    document.removeEventListener('input', onEdit, true);
    document.removeEventListener('change', onEdit, true);
  };
}
