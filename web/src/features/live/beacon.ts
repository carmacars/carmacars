'use client';
// Live visitors (migration 0060): the site's own first-party beacon. Loaded after the page, it batches page views and
// a few key events and posts them to /api/t (answered by the Worker entry in one database call). With analytics
// consent it records the pages, cars and dates a visitor looks at; without it, only a known customer's own booking
// pages (offer, change proposal, pay page) and the email link that brought them, which the privacy policy describes.
// No third-party script, no fingerprinting, no network address kept.

type Ev = { k: string; path?: string; slug?: string; bn?: string; m?: string; ms?: number; d?: Record<string, string> };
export interface BeaconReply { ok?: boolean; invite?: { token: string; number: string; message: string; from?: string } | null; cfg?: { chat: boolean; greet_after: number; greet_text: string } }

const SID = 'cc_sid', VID = 'cc_vid', CHOICE = 'cc_cookie_choice';
const IDLE_MS = 30 * 60 * 1000, FLUSH_MS = 4000, BEAT_MS = 30_000;
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
export function onBeaconReply(f: (r: BeaconReply) => void) { listeners.add(f); return () => listeners.delete(f); }

let queue: Ev[] = [];
let timer: ReturnType<typeof setTimeout> | undefined;
let started = false;
let current = { path: '', at: 0, slug: undefined as string | undefined, bn: undefined as string | undefined, kind: 'page', requestStarted: false };
let lastBookSlug: string | undefined;
let chatOpen = false;
export function setChatOpen(v: boolean) { chatOpen = v; }

function batch(events: Ev[]) {
  const ref = document.referrer && !document.referrer.startsWith(location.origin) ? new URL(document.referrer).host : undefined;
  const q = new URLSearchParams(location.search);
  const utm: Record<string, string> = {};
  for (const k of ['source', 'medium', 'campaign', 'term', 'content']) { const v = q.get('utm_' + k); if (v) utm[k] = v; }
  return { sid: sessionId(), vid: visitorId(), consent: analyticsOn() ? 'analytics' : 'essential', ref, landing: location.pathname, utm, events };
}

/** Without analytics consent, only what the privacy policy allows leaves the browser. */
function allowed(e: Ev): boolean {
  if (analyticsOn()) return true;
  return e.k === 'email_link_opened' || e.k === 'pay_left' || (e.k === 'page_view' && Boolean(e.bn)) || e.k === 'chat_opened';
}

async function send(keepalive = false) {
  if (timer) { clearTimeout(timer); timer = undefined; }
  const events = queue.filter(allowed);
  queue = [];
  // a heartbeat (no events) only matters when the visitor may be shown: consent, a known customer page, or an open chat
  if (!events.length && !analyticsOn() && !chatOpen && !current.bn) return;
  try {
    const r = await fetch('/api/t', { method: 'POST', keepalive, headers: { 'content-type': 'application/json' }, body: JSON.stringify(batch(events)), credentials: 'same-origin' });
    if (!keepalive && r.ok) { const j = (await r.json()) as BeaconReply; for (const f of listeners) f(j); }
  } catch { /* the next batch carries on */ }
}
function push(e: Ev, soon = true) {
  queue.push(e);
  if (queue.length >= 25) void send();
  else if (soon && !timer) timer = setTimeout(() => void send(), FLUSH_MS);
}
export function track(k: string, extra: Omit<Ev, 'k'> = {}) { push({ k, path: location.pathname, ...extra }); }

function leave(final: boolean) {
  if (!current.path) return;
  const ms = Date.now() - current.at;
  push({ k: 'page_leave', path: current.path, slug: current.slug, bn: current.bn, ms }, false);
  if (current.kind === 'book' && current.requestStarted) push({ k: 'request_abandoned', path: current.path, slug: current.slug }, false);
  if (current.kind === 'pay') push({ k: 'pay_left', path: current.path, bn: current.bn, ms }, false);
  if (final) void send(true);
}

function view() {
  const path = location.pathname;
  if (path === current.path) return;
  const ctx = pageContext(path);
  // leaving the form for the "sent" page is a submission, not an abandoned request
  if (current.path && !(current.kind === 'book' && ctx.kind === 'sent')) leave(false);
  current = { path, at: Date.now(), slug: ctx.slug, bn: ctx.bn, kind: ctx.kind, requestStarted: false };
  if (ctx.kind === 'book') lastBookSlug = ctx.slug;
  push({ k: 'page_view', path, slug: ctx.kind === 'sent' ? lastBookSlug : ctx.slug, bn: ctx.bn });
  const q = new URLSearchParams(location.search);
  if (q.get('from') && q.get('to')) push({ k: 'search', path, d: { pickup: q.get('from')!, return: q.get('to')! } });
  // the outbox row an email link carries (?m=), also inside a sign-in page's next=
  let m = q.get('m');
  if (!m) { const next = q.get('next'); if (next) m = new URLSearchParams(next.split('?')[1] ?? '').get('m'); }
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
  // a booking request form: the first field touched starts it
  document.addEventListener('focusin', (e) => {
    if (current.kind !== 'book' || current.requestStarted) return;
    const t = e.target as HTMLElement | null;
    if (t && t.closest('form') && /^(INPUT|SELECT|TEXTAREA)$/.test(t.tagName)) { current.requestStarted = true; track('request_started', { slug: current.slug }); }
  });
  addEventListener('pagehide', () => leave(true));
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'hidden') void send(true); });
  addEventListener('cc:consent', () => { void send(); });
  view();
  void send();
  setInterval(() => { if (document.visibilityState === 'visible') void send(); }, BEAT_MS);
}
