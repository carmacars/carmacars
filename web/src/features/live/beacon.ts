'use client';
// Live visitors (migration 0060): the site's own first-party beacon. Loaded after the page, it batches page views and
// a few key events and posts them to /api/t (answered by the Worker entry in one database call). With analytics
// consent it records the pages, cars and dates a visitor looks at; without it, only a known customer's own booking
// pages (offer, change proposal, pay page) and the email link that brought them, which the privacy policy describes.
// No third-party script, no fingerprinting, no network address kept.
// 0086 adds a few low-cost events, with analytics consent only (the list in allowed() is unchanged): the price shown
// (from Estimate), the request form step reached and its errors, a question opened in a FAQ (its topic only), a tap
// to call, text, WhatsApp or email us or a copied phone number, photos looked through (from Gallery), sorting and
// filters on the fleet list, dates changed without a page load, repeated taps, and a flag when the visit came from an
// ad click (the click id never leaves the browser). Never what a visitor types.
// 0103: a visitor reading one page stayed on Live visitors only 3 minutes. While the page is visible a heartbeat
// (heartbeat.ts, every 45 seconds, an Admin setting) updates the session alone (/api/t answers it with one UPDATE, no
// event); it stops while the tab is hidden, and when the page closes navigator.sendBeacon sends its last events with
// "end", so the session ends. Heartbeats follow the same consent as page beacons: only a visitor who may be shown.
// A batch the network lost is sent again once; a heartbeat that finds no session sends the page view again.
import { beatMs, createHeartbeat } from './heartbeat';
import { takeWaitingTracks } from '@/lib/track/emit';

type Ev = { k: string; path?: string; slug?: string; bn?: string; m?: string; ms?: number; d?: Record<string, string> };
export interface BeaconReply { ok?: boolean; invite?: { token: string; number: string; message: string; from?: string } | null; cfg?: { chat: boolean; greet_after: number; greet_text: string; beat?: number };
  /** a heartbeat's answer (0103): written, and whether the database has the session */
  seen?: boolean; known?: boolean }

const SID = 'cc_sid', VID = 'cc_vid', CHOICE = 'cc_cookie_choice', AD = 'cc_ad';
const IDLE_MS = 30 * 60 * 1000, FLUSH_MS = 4000;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

const readCookie = (n: string) => document.cookie.split('; ').find((c) => c.startsWith(n + '='))?.split('=').slice(1).join('=');
const writeCookie = (n: string, v: string) => { document.cookie = `${n}=${v}; path=/; max-age=${60 * 60 * 24 * 365}; samesite=lax${location.protocol === 'https:' ? '; secure' : ''}`; };
function analyticsOn(): boolean {
  try { return Boolean((JSON.parse(decodeURIComponent(readCookie(CHOICE) ?? '')) as { analytics?: boolean }).analytics); } catch { return false; }
}
export function visitorId(): string {
  let v = readCookie(VID);
  if (!v || !UUID.test(v)) { v = crypto.randomUUID(); writeCookie(VID, v); }
  return v;
}
export function sessionId(): string {
  try {
    const raw = JSON.parse(sessionStorage.getItem(SID) ?? 'null') as { id: string; at: number } | null;
    const id = raw && UUID.test(raw.id) && Date.now() - raw.at < IDLE_MS ? raw.id : crypto.randomUUID();
    sessionStorage.setItem(SID, JSON.stringify({ id, at: Date.now() }));
    return id;
  } catch { return crypto.randomUUID(); }
}

/** What the page is about, from its address alone. */
export function pageContext(path: string): { slug?: string; bn?: string; kind: string } {
  let m = /^\/cars\/([a-z0-9-]+)\/?$/.exec(path);
  if (m) return { slug: m[1], kind: 'car' };
  m = /^\/book\/(?!sent)([a-z0-9-]+)\/?$/.exec(path);
  if (m) return { slug: m[1], kind: 'book' };
  if (/^\/book\/sent\//.test(path)) return { kind: 'sent' };
  m = /^\/account\/bookings\/([A-Za-z0-9-]+)(?:\/(offer|change|pay|sign))?/.exec(path);
  if (m) return { bn: decodeURIComponent(m[1]!), kind: m[2] ?? 'booking' };
  return { kind: 'page' };
}

const listeners = new Set<(r: BeaconReply) => void>();
export function onBeaconReply(f: (r: BeaconReply) => void) { listeners.add(f); return () => { listeners.delete(f); }; }

let queue: Ev[] = [];
let timer: ReturnType<typeof setTimeout> | undefined;
let started = false;
let current = { path: '', at: 0, slug: undefined as string | undefined, bn: undefined as string | undefined, kind: 'page', requestStarted: false };
let lastBookSlug: string | undefined;
let chatOpen = false;
export function setChatOpen(v: boolean) { chatOpen = v; }
let beatEvery = beatMs(undefined);
let resent = false;
const hb = createHeartbeat({ visible: () => document.visibilityState === 'visible', beat: () => void beat(), intervalMs: () => beatEvery });

function batch(events: Ev[]) {
  const ref = document.referrer && !document.referrer.startsWith(location.origin) ? new URL(document.referrer).host : undefined;
  const q = new URLSearchParams(location.search);
  const utm: Record<string, string> = {};
  for (const k of ['source', 'medium', 'campaign', 'term', 'content']) { const v = q.get('utm_' + k); if (v) utm[k] = v; }
  let ad: '1' | undefined;
  try { ad = sessionStorage.getItem(AD) === '1' ? '1' : undefined; } catch { /* none */ }
  return { sid: sessionId(), vid: visitorId(), consent: analyticsOn() ? 'analytics' : 'essential', ref, landing: location.pathname, utm, ad, events };
}

/** Without analytics consent, only what the privacy policy allows leaves the browser. */
function allowed(e: Ev): boolean {
  if (analyticsOn()) return true;
  return e.k === 'email_link_opened' || e.k === 'pay_left' || (e.k === 'page_view' && Boolean(e.bn)) || e.k === 'chat_opened';
}

/** The visitor may be shown on Live visitors: analytics consent, a known customer's booking page, or an open chat. */
const shown = () => analyticsOn() || chatOpen || Boolean(current.bn);
function heard(j: BeaconReply) {
  if (j.cfg?.beat && beatMs(j.cfg.beat) !== beatEvery) { beatEvery = beatMs(j.cfg.beat); hb.reset(); }
  for (const f of listeners) f(j);
}

async function send(keepalive = false) {
  if (timer) { clearTimeout(timer); timer = undefined; }
  const events = queue.filter(allowed);
  queue = [];
  if (!events.length && !shown()) return;
  hb.reset();
  try {
    const r = await fetch('/api/t', { method: 'POST', keepalive, headers: { 'content-type': 'application/json' }, body: JSON.stringify(batch(events)), credentials: 'same-origin' });
    // 204: the database is slow and the batch is being stored in the background
    if (!keepalive && r.status === 200) heard((await r.json()) as BeaconReply);
    else if (r.status >= 500) requeue(events);
  } catch { requeue(events); }
}
/** A batch the network lost goes once more with the next one (marked, so it is never sent a third time). */
function requeue(events: Ev[]) {
  const again = events.filter((e) => !(e as Ev & { again?: 1 }).again).slice(0, 20).map((e) => ({ ...e, again: 1 as const }));
  if (!again.length) return;
  queue = [...again, ...queue].slice(0, 30);
  if (!timer) timer = setTimeout(() => void send(), FLUSH_MS * 2);
}

/** The heartbeat: the session's last seen and page, nothing else. Events waiting go as a batch instead. */
async function beat() {
  if (!shown()) return;
  if (queue.some(allowed)) { void send(); return; }
  try {
    const r = await fetch('/api/t', { method: 'POST', headers: { 'content-type': 'application/json' }, credentials: 'same-origin',
      body: JSON.stringify({ beat: 1, sid: sessionId(), vid: visitorId(), path: location.pathname }) });
    if (r.status !== 200) return;
    const j = (await r.json()) as BeaconReply;
    heard(j);
    // the database has no session for this tab (its first batch was lost): the page view once more
    if (j.seen === false && j.known === false && !resent && current.path) {
      resent = true;
      push({ k: 'page_view', path: current.path, slug: current.slug, bn: current.bn });
      void send();
    }
  } catch { /* the next beat carries on */ }
}

/** The page is closing: its last events and the end of the session, with sendBeacon (it survives the page). */
function final() {
  if (timer) { clearTimeout(timer); timer = undefined; }
  hb.stop();
  const events = queue.filter(allowed);
  queue = [];
  if (!events.length && !shown()) return;
  const body = JSON.stringify(events.length ? { ...batch(events), end: '1' } : { beat: 1, end: '1', sid: sessionId(), vid: visitorId() });
  try { if (navigator.sendBeacon?.('/api/t', body)) return; } catch { /* below */ }
  void fetch('/api/t', { method: 'POST', keepalive: true, headers: { 'content-type': 'application/json' }, body, credentials: 'same-origin' }).catch(() => undefined);
}
function push(e: Ev, soon = true) {
  queue.push(e);
  if (queue.length >= 25) void send();
  else if (soon && !timer) timer = setTimeout(() => void send(), FLUSH_MS);
}
export function track(k: string, extra: Omit<Ev, 'k'> = {}) { push({ k, path: location.pathname, ...extra }); }

function leave(closing: boolean) {
  if (!current.path) return;
  const ms = Date.now() - current.at;
  push({ k: 'page_leave', path: current.path, slug: current.slug, bn: current.bn, ms }, false);
  if (current.kind === 'book' && current.requestStarted) push({ k: 'request_abandoned', path: current.path, slug: current.slug }, false);
  if (current.kind === 'pay') push({ k: 'pay_left', path: current.path, bn: current.bn, ms }, false);
  if (closing) final();
}

// ---------------------------------------------------------------- 0086: what changes on the page without a load
let page = { dates: '', sort: '', filters: '', max: 0, step: 0, errs: 0, frictions: 0, rage: { t: null as EventTarget | null, n: 0, at: 0 } };
let browseTimer: ReturnType<typeof setTimeout> | undefined;
let browseNext: Record<string, string> = {};
/** The address changed on the same page (dates picked, the fleet list sorted or filtered): one event after a pause. */
function queryChanged(first: boolean) {
  const q = new URLSearchParams(location.search);
  const from = q.get('from'), to = q.get('to');
  const dates = from && to ? `${from}|${to}` : '';
  const sort = q.get('sort') ?? '';
  const filters = ['cls', 'seats', 'trans', 'q', 'mode'].map((k) => q.get(k) ?? '').join('|');
  const max = Number(q.get('max') ?? 0) || 0;
  if (!first) {
    if (dates && dates !== page.dates) browseNext.dates = dates;
    if (sort !== page.sort && sort) browseNext.sort = sort === 'price-asc' || sort === 'price-desc' ? sort : 'other';
    if (filters !== page.filters) browseNext.filter = '1';
    if (max && (!page.max || max < page.max)) browseNext.maxp = '1';
    if (Object.keys(browseNext).length) {
      if (browseTimer) clearTimeout(browseTimer);
      browseTimer = setTimeout(() => {
        const n = browseNext; browseNext = {};
        if (n.dates) { const [p, r] = n.dates.split('|'); track('search', { slug: current.slug, d: { pickup: p!, return: r! } }); }
        const d: Record<string, string> = {};
        for (const k of ['sort', 'filter', 'maxp']) if (n[k]) d[k] = n[k]!;
        if (Object.keys(d).length) track('browse', { d });
      }, 1500);
    }
  }
  page.dates = dates; page.sort = sort; page.filters = filters; page.max = max;
}
const TOPICS: Array<[RegExp, string]> = [[/cancel|refund/i, 'cancel'], [/deposit|\bhold\b/i, 'deposit'], [/(additional|second|another|extra) driver|add a driver/i, 'drivers'],
  [/insur|coverage|protection|damage/i, 'insurance'], [/young|under 2[15]|how old|\bage\b/i, 'young'], [/deliver|airport|drop.?off/i, 'delivery'],
  [/kilomet|\bkm\b|mileage/i, 'km'], [/licen[cs]e|requir|document|credit card|debit/i, 'requirements'], [/price|cost|rate|fee|pay|tax|hst/i, 'price']];
export const topicOf = (q: string) => TOPICS.find(([re]) => re.test(q))?.[1] ?? 'other';
const CONTACT = (h: string) => (/^tel:/i.test(h) ? 'call' : /^sms:/i.test(h) ? 'sms' : /^mailto:/i.test(h) ? 'email' : /wa\.me|whatsapp/i.test(h) ? 'whatsapp' : null);
/** The request form: the step on screen and its errors, read after a tap (nothing typed is read). */
function formCheck() {
  if (current.kind !== 'book') return;
  const n = Number((document.querySelector('[data-step]:not([hidden])') as HTMLElement | null)?.dataset.step ?? 0);
  if (n > page.step) { page.step = n; if (n > 1) track('request_step', { slug: current.slug, d: { step: String(n) } }); }
  const errs = document.querySelectorAll('form .has-error').length;
  if (errs > 0 && errs !== page.errs && page.frictions < 3) { page.frictions++; track('friction', { slug: current.slug, d: { type: 'error' } }); }
  page.errs = errs;
}

function view() {
  const path = location.pathname;
  if (path === current.path) { queryChanged(false); return; }
  page = { dates: '', sort: '', filters: '', max: 0, step: 0, errs: 0, frictions: 0, rage: { t: null, n: 0, at: 0 } };
  queryChanged(true);
  const ctx = pageContext(path);
  // leaving the form for the "sent" page is a submission, not an abandoned request
  if (current.path && !(current.kind === 'book' && ctx.kind === 'sent')) leave(false);
  current = { path, at: Date.now(), slug: ctx.slug, bn: ctx.bn, kind: ctx.kind, requestStarted: false };
  resent = false;
  if (ctx.kind === 'book') lastBookSlug = ctx.slug;
  push({ k: 'page_view', path, slug: ctx.kind === 'sent' ? lastBookSlug : ctx.slug, bn: ctx.bn });
  const q = new URLSearchParams(location.search);
  if (q.get('from') && q.get('to')) push({ k: 'search', path, slug: ctx.slug, d: { pickup: q.get('from')!, return: q.get('to')! } });
  // the outbox row an email link carries (?m=), also inside a sign-in page's next=
  let m = q.get('m');
  if (!m) { const next = q.get('next'); if (next) m = new URLSearchParams(next.split('?')[1] ?? '').get('m'); }
  // kept by the Worker through a sign-in redirect (cookie cc_m), read once
  if (!m) { const c = readCookie('cc_m'); if (c && UUID.test(c)) { m = c; document.cookie = 'cc_m=; path=/; max-age=0'; } }
  if (m && UUID.test(m)) {
    push({ k: 'email_link_opened', path, m, bn: ctx.bn });
    if (q.get('m')) { q.delete('m'); history.replaceState(history.state, '', `${path}${q.size ? '?' + q : ''}${location.hash}`); }
  }
}

export function startBeacon() {
  if (started) return;
  started = true;
  // client-side navigation (the app router) changes the address without a load
  for (const k of ['pushState', 'replaceState'] as const) {
    const orig = history[k].bind(history);
    history[k] = (...a: Parameters<History['pushState']>) => { const r = orig(...a); queueMicrotask(view); return r; };
  }
  addEventListener('popstate', () => queueMicrotask(view));
  try { if (/[?&](gclid|gbraid|wbraid|msclkid|dclid)=/.test(location.search)) sessionStorage.setItem(AD, '1'); } catch { /* none */ }
  // 0086: events from the components (the price shown, photos looked through), and taps, copies and questions opened
  addEventListener('cc:track', (e) => {
    const x = (e as CustomEvent<{ k?: string; d?: Record<string, string> }>).detail;
    if (x?.k && ['quote_seen', 'photos'].includes(x.k)) track(x.k, { slug: current.slug, d: x.d });
  });
  document.addEventListener('click', (e) => {
    const a = (e.target as Element | null)?.closest?.('a[href]');
    const via = a ? CONTACT(a.getAttribute('href') ?? '') : null;
    if (via) track('contact_click', { d: { via } });
    // the same thing tapped four times in quick succession: something did not respond
    const r = page.rage, now = Date.now();
    if (e.target === r.t && now - r.at < 700) r.n++; else { r.t = e.target; r.n = 1; }
    r.at = now;
    if (r.n === 4 && page.frictions < 3) { page.frictions++; track('friction', { d: { type: 'rage' } }); }
    if (current.kind === 'book') setTimeout(formCheck, 120);
  }, true);
  document.addEventListener('invalid', () => { if (page.frictions < 3 && !page.errs) { page.frictions++; page.errs = 1; track('friction', { slug: current.slug, d: { type: 'error' } }); } }, true);
  document.addEventListener('copy', () => {
    const t = String(getSelection() ?? '');
    if (t.length < 40 && /(\+?1[\s.-]?)?\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}/.test(t)) track('contact_click', { d: { via: 'copy' } });
  });
  document.addEventListener('toggle', (e) => {
    const d = e.target;
    if (d instanceof HTMLDetailsElement && d.open && d.closest('.faq')) track('help_open', { d: { topic: topicOf(d.querySelector('summary')?.textContent ?? '') } });
  }, true);
  // a booking request form: the first field touched starts it (focused, or changed without a focus first: a value picked
  // by the browser's autofill or a tap on a radio that does not take focus)
  const requestStart = (e: Event) => {
    if (current.kind !== 'book' || current.requestStarted) return;
    const t = e.target as HTMLElement | null;
    if (t && t.closest?.('form') && /^(INPUT|SELECT|TEXTAREA)$/.test(t.tagName)) { current.requestStarted = true; track('request_started', { slug: current.slug }); }
  };
  for (const k of ['focusin', 'input', 'change'] as const) document.addEventListener(k, requestStart, true);
  addEventListener('pagehide', () => leave(true));
  // back from the back-forward cache: the session lives again (the page's end is undone by the next write)
  addEventListener('pageshow', (e) => { if ((e as PageTransitionEvent).persisted) { hb.start(); void beat(); } });
  document.addEventListener('visibilitychange', () => {
    // hidden: what is waiting goes now (the tab may never come back); the heartbeat stops
    if (document.visibilityState === 'hidden' && queue.some(allowed)) void send(true);
    hb.visibility();
  });
  addEventListener('cc:consent', () => { void send(); });
  view();
  // what happened on this page before the beacon loaded (it loads once the page is idle): the price already shown, and
  // a field of the request form already in use
  for (const x of takeWaitingTracks()) if (['quote_seen', 'photos'].includes(x.k)) track(x.k, { slug: current.slug, d: x.d });
  const active = document.activeElement as HTMLElement | null;
  if (current.kind === 'book' && active?.closest?.('form') && /^(INPUT|SELECT|TEXTAREA)$/.test(active.tagName)) { current.requestStarted = true; track('request_started', { slug: current.slug }); }
  void send();
  hb.start();
}
