// Discount games (migrations 0069 and 0076): the rules that decide when a game may show (first, again after a close,
// in the request-to-book form), and the layouts the games draw. Pure functions (no browser, no imports) so they are
// unit tested and shared by the trigger and the games. The prize itself is drawn by the database; nothing here can
// change it.

export type GameKind = 'wheel' | 'scratch' | 'blackjack' | 'cups' | 'plinko' | 'pack';
export const GAMES: GameKind[] = ['wheel', 'scratch', 'blackjack', 'cups', 'plinko', 'pack'];
/** The browser's settings (app.game_cfg): the first show (car pages, seconds, exit intent), the re-show after a close
 *  (more car pages, seconds since the close), the most shows in one visit, and the offer in the request-to-book form. */
export interface GameCfg { on: boolean; car_pages: number; seconds: number; exit: boolean; reshow_pages: number; reshow_seconds: number; per_visit: number; booking: boolean }
/** What this browser remembers (localStorage, the visitor's own device only): a claim, a refusal from the server, the
 *  games shown in the current round, the code. dismissedAt is from 0069 and no longer read. */
export interface GameMemory { claimed?: boolean; never?: string; seen?: GameKind[]; dismissedAt?: number; code?: string; codeUntil?: string }
/** This visit (sessionStorage): when it started, pages and car pages seen, how it began, the games shown, and when the
 *  last one was closed (with the car pages seen by then). */
export interface Visit { start: number; pages: number; cars: string[]; fromSearch: boolean; shows?: number; closedAt?: number; carsAtClose?: number }
export type Trigger = 'pages' | 'time' | 'exit';
/** Why a game shows, and whether as the small slide-in (the first page of a phone visit from a search engine). */
export interface Fire { why: Trigger; slim: boolean }

/** How much later the small slide-in comes on the first page of a phone visit from a search engine. */
export const SEARCH_LANDING_DELAY = 15_000;

/** Pages where a game never shows: booking, paying, signing, sign-in, portals, documents. */
const NEVER = /^\/(book|account|owner|admin|va|field|investor|sign|sign-in|sign-document|create-account|reset-password|update-password|two-step|choose-portal|read-only|link-expired|unsubscribe|guide-pdf|files|d|r|list-your-car\/apply|auth)(\/|$)/;
const PAYSIGN = /\/(pay|sign|checkout)(\/|$)/;
export const excludedPath = (path: string) => NEVER.test(path) || PAYSIGN.test(path);
/** The request-to-book form (/book and /book/<car>), where the inline card is offered; never its sent page. */
export const bookingPath = (path: string) => /^\/book(\/[a-z0-9-]+)?\/?$/.test(path) && !/^\/book\/sent(\/|$)/.test(path) && !PAYSIGN.test(path);

/** A car page: /cars/<slug>. */
export function carSlug(path: string): string | null {
  const m = /^\/cars\/([a-z0-9-]+)\/?$/.exec(path);
  return m ? m[1]! : null;
}

export function isSearchReferrer(ref: string | null | undefined): boolean {
  if (!ref) return false;
  try { return /(^|\.)(google|bing|duckduckgo|yahoo|ecosia|baidu|yandex|brave|startpage|qwant)\.[a-z.]+$/i.test(new URL(ref).hostname); } catch { return false; }
}

/** Why the site's game may not show to this visitor now (null: it may). Signed-in people never see it on the site. */
export function ineligible(a: { cfg: GameCfg | null; mem: GameMemory; signedIn: boolean; path: string; visit?: Visit | null }): string | null {
  if (a.signedIn) return 'signed_in';
  if (a.mem.claimed) return 'claimed';
  if (a.mem.never) return a.mem.never;
  if (excludedPath(a.path)) return 'page';
  if (!a.cfg) return 'no_settings';
  if (!a.cfg.on) return 'off';
  if (a.visit && (a.visit.shows ?? 0) >= Math.max(1, a.cfg.per_visit)) return 'visit_cap';
  return null;
}

/** Why the request-to-book form may not offer the game (null: it may). Anyone who has not claimed, signed-in renters
 *  included; never staff (the server says so). A visitor the site leaves alone because they are known or signed in
 *  is welcome here; only a claim stops it. */
export function bookingIneligible(a: { cfg: GameCfg | null; mem: GameMemory; path: string; staff?: boolean; promoApplied?: boolean }): string | null {
  if (a.mem.claimed || a.mem.never === 'claimed') return 'claimed';
  if (a.staff) return 'staff';
  if (!bookingPath(a.path)) return 'page';
  if (!a.cfg) return 'no_settings';
  if (!a.cfg.on || !a.cfg.booking) return 'off';
  if (a.promoApplied) return 'has_code';
  return null;
}

/** Which rule fires now. The first game of a visit: enough car pages, enough time, or exit intent (computers only),
 *  whichever first. After a close: more car pages or more time since the close, whichever first. On the first page of
 *  a phone visit from a search engine there is no interstitial: the game waits for the second page, or comes
 *  SEARCH_LANDING_DELAY after its rule as the small slide-in that covers almost nothing. */
export function trigger(a: { cfg: GameCfg; visit: Visit; now: number; exit?: boolean; phone: boolean }): Fire | null {
  const { cfg, visit: v, now } = a;
  const shows = v.shows ?? 0;
  if (shows >= Math.max(1, cfg.per_visit)) return null;
  if (shows > 0) {
    if (v.closedAt === undefined) return null; // one is open
    if (cfg.reshow_pages > 0 && v.cars.length - (v.carsAtClose ?? v.cars.length) >= cfg.reshow_pages) return { why: 'pages', slim: false };
    if (cfg.reshow_seconds > 0 && now - v.closedAt >= cfg.reshow_seconds * 1000) return { why: 'time', slim: false };
    return null;
  }
  const byPages = cfg.car_pages > 0 && v.cars.length >= cfg.car_pages;
  if (a.phone && v.fromSearch && v.pages <= 1) {
    // when the rule would have fired: at once by pages (the landing page is a car page), or after the seconds
    const at = byPages ? v.start : cfg.seconds > 0 ? v.start + cfg.seconds * 1000 : null;
    if (at === null || now < at + SEARCH_LANDING_DELAY) return null;
    return { why: byPages ? 'pages' : 'time', slim: true };
  }
  if (byPages) return { why: 'pages', slim: false };
  if (cfg.seconds > 0 && now - v.start >= cfg.seconds * 1000) return { why: 'time', slim: false };
  if (a.exit && cfg.exit && !a.phone) return { why: 'exit', slim: false };
  return null;
}

/** When to look again (ms from now), so a timer can fire the time rule on time; null when no time rule is pending. */
export function nextCheck(a: { cfg: GameCfg; visit: Visit; now: number; phone: boolean }): number | null {
  const { cfg, visit: v, now } = a;
  const shows = v.shows ?? 0;
  if (shows >= Math.max(1, cfg.per_visit)) return null;
  let at: number | null = null;
  if (shows > 0) { if (v.closedAt !== undefined && cfg.reshow_seconds > 0) at = v.closedAt + cfg.reshow_seconds * 1000; }
  else {
    const byPages = cfg.car_pages > 0 && v.cars.length >= cfg.car_pages;
    const timeAt = cfg.seconds > 0 ? v.start + cfg.seconds * 1000 : null;
    if (a.phone && v.fromSearch && v.pages <= 1) at = byPages ? v.start + SEARCH_LANDING_DELAY : timeAt === null ? null : timeAt + SEARCH_LANDING_DELAY;
    else at = timeAt;
  }
  return at === null ? null : Math.max(0, at - now);
}

/** The visit after a game is shown, and after it is closed. */
export const shown = (v: Visit): Visit => ({ ...v, shows: (v.shows ?? 0) + 1, closedAt: undefined, carsAtClose: undefined });
export const closed = (v: Visit, now: number): Visit => ({ ...v, closedAt: now, carsAtClose: v.cars.length });

/** The games this browser has shown in the current round, with one more: once every game on was shown, a new round
 *  starts with the one just shown (so the next is never the same twice in a row). */
export function addSeen(seen: GameKind[] | undefined, g: GameKind, on: GameKind[] = GAMES): GameKind[] {
  const s = (seen ?? []).filter((x) => on.includes(x));
  const next = s.includes(g) ? s : [...s, g];
  return on.every((x) => next.includes(x)) ? [g] : next;
}

/** The games still to come in this round (all of them again once the round is complete), the server's own rule. */
export function unseen(seen: GameKind[] | undefined, on: GameKind[] = GAMES, last?: GameKind): GameKind[] {
  const s = (seen ?? []).filter((x) => on.includes(x));
  const left = on.filter((x) => !s.includes(x));
  if (left.length) return left;
  const fresh = on.filter((x) => x !== last);
  return fresh.length ? fresh : on;
}

/** The visit with one more page. */
export function addPage(v: Visit, path: string): Visit {
  const slug = carSlug(path);
  return { ...v, pages: v.pages + 1, cars: slug && !v.cars.includes(slug) ? [...v.cars, slug] : v.cars };
}

export interface PrizeWord { key: string; short: string; label: string }

/** The wheel's 12 slices: the most common prize on every other slice, the rest in turn between them (the rarest once
 *  or twice), so the wheel looks lively; the terms say the chances differ. Every prize is on the wheel: with more
 *  prizes than the slices between, some of the common prize's slices give way to them. */
export function wheelSlices(prizes: PrizeWord[], n = 12): PrizeWord[] {
  if (!prizes.length) return [];
  if (prizes.length === 1) return Array.from({ length: n }, () => prizes[0]!);
  const [top, ...rest] = prizes;
  // rest in the order of the table (most to least likely); the rarer ones appear less often
  const cycle: PrizeWord[] = [];
  rest.forEach((p, i) => { for (let k = 0; k < Math.max(1, rest.length - i); k++) cycle.push(p); });
  const spread: PrizeWord[] = [];
  const pool = [...cycle];
  // interleave so equal prizes are apart
  while (pool.length) { for (const p of rest) { const j = pool.indexOf(p); if (j >= 0) { spread.push(p); pool.splice(j, 1); } } }
  const out = Array.from({ length: n }, (_, i) => (i % 2 === 0 ? top! : spread[((i - 1) / 2) % spread.length]!));
  // a prize that found no slice takes one of the common prize's, from the far side
  const missing = rest.filter((p) => !out.includes(p));
  missing.forEach((p, k) => { out[n - 2 - 2 * k] = p; });
  return out;
}

/** Where the wheel stops: total degrees to turn so the pointer (at the top) rests inside a slice showing the prize.
 *  near: stop close to the edge next to another prize, for a near miss. */
export function wheelStop(slices: PrizeWord[], key: string, r: () => number, turns = 5, near = true): { index: number; degrees: number } {
  const matches = slices.map((s, i) => (s.key === key ? i : -1)).filter((i) => i >= 0);
  const index = matches.length ? matches[Math.floor(r() * matches.length)]! : 0;
  const size = 360 / slices.length;
  // inside the slice: 15% to 85% of its width, or 8% to 18% from an edge for a near miss
  const within = near ? (r() < 0.5 ? 0.08 + r() * 0.1 : 0.82 + r() * 0.1) : 0.15 + r() * 0.7;
  const at = index * size + within * size; // the angle of the slice point that must come to the top
  return { index, degrees: turns * 360 + (360 - at) };
}

/** Plinko's slots (rows + 1): the rarest prize in the middle, then the next rarest beside it, left and right in turn,
 *  the most common at the sides. Every prize has a slot while there are slots enough. */
export function plinkoSlots(prizes: PrizeWord[], rows = 8): PrizeWord[] {
  const n = rows + 1;
  if (!prizes.length) return [];
  const rarest = [...prizes].reverse(); // least likely first
  const mid = Math.floor(n / 2);
  const out: PrizeWord[] = Array.from({ length: n }, () => prizes[0]!);
  // the order outwards from the middle: mid, mid-1, mid+1, mid-2, mid+2, ...
  const order = [mid];
  for (let d = 1; order.length < n; d++) { if (mid - d >= 0) order.push(mid - d); if (mid + d < n) order.push(mid + d); }
  rarest.slice(0, n).forEach((p, i) => { out[order[i]!] = p; });
  return out;
}

/** A path down the pegs (true: right) that ends in a slot showing the prize. It stays near the middle as long as it
 *  can and turns off late, so the disc passes the big prizes (a near miss) and still lands where the draw says. */
export function plinkoPath(slots: PrizeWord[], key: string, r: () => number): { slot: number; moves: boolean[] } {
  const rows = slots.length - 1;
  const matches = slots.map((s, i) => (s.key === key ? i : -1)).filter((i) => i >= 0);
  const slot = matches.length ? matches[Math.floor(r() * matches.length)]! : Math.floor(rows / 2);
  let right = slot, left = rows - slot;
  const moves: boolean[] = [];
  for (let i = 0; i < rows; i++) {
    const remaining = rows - i;
    let go: boolean;
    if (right === remaining) go = true; // only rights left to reach the slot
    else if (left === remaining) go = false;
    else {
      const pos = moves.filter(Boolean).length - i / 2; // left of the middle when negative
      go = pos < 0 ? true : pos > 0 ? false : r() < 0.5;
    }
    moves.push(go);
    if (go) right--; else left--;
  }
  return { slot, moves };
}

/** Blackjack: the value of a hand (aces 1 or 11). */
export function handValue(cards: number[]): number {
  let total = 0, aces = 0;
  for (const c of cards) { if (c === 1) { aces++; total += 11; } else total += Math.min(c, 10); }
  while (total > 21 && aces) { total -= 10; aces--; }
  return total;
}

/** A shuffled deck of ranks 1 (ace) to 13 (king), four of each. */
export function deck(r: () => number): number[] {
  const d = Array.from({ length: 52 }, (_, i) => (i % 13) + 1);
  for (let i = d.length - 1; i > 0; i--) { const j = Math.floor(r() * (i + 1)); [d[i], d[j]] = [d[j]!, d[i]!]; }
  return d;
}

export type HandResult = 'blackjack' | 'win' | 'push' | 'lose' | 'bust';
/** The dealer draws to 17; the result of the hand (the prize is the same whatever happens). */
export function settle(player: number[], dealer: number[], draw: () => number): { dealer: number[]; result: HandResult } {
  const p = handValue(player);
  const d = [...dealer];
  if (p > 21) return { dealer: d, result: 'bust' };
  if (p === 21 && player.length === 2) return { dealer: d, result: 'blackjack' };
  while (handValue(d) < 17) d.push(draw());
  const dv = handValue(d);
  return { dealer: d, result: dv > 21 || p > dv ? 'win' : p === dv ? 'push' : 'lose' };
}

/** The cups' shuffle: a list of swaps (pairs of positions) for about three seconds of motion. */
export function cupSwaps(r: () => number, count = 7): Array<[number, number]> {
  const pairs: Array<[number, number]> = [[0, 1], [1, 2], [0, 2]];
  const out: Array<[number, number]> = [];
  for (let i = 0; i < count; i++) {
    let p = pairs[Math.floor(r() * 3)]!;
    if (out.length && out[out.length - 1]![0] === p[0] && out[out.length - 1]![1] === p[1]) p = pairs[(pairs.indexOf(p) + 1) % 3]!;
    out.push(p);
  }
  return out;
}

/** A first name, an email and an optional phone, checked before the server checks them again. */
export function claimProblems(v: { first: string; email: string; phone: string }): Record<string, string> {
  const e: Record<string, string> = {};
  if (!v.first.trim() || v.first.trim().length > 60) e.first = 'Enter your first name.';
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]{2,}$/.test(v.email.trim())) e.email = v.email.trim() ? 'Enter an email address like name@example.com.' : 'Enter your email so we can send the code.';
  const d = v.phone.replace(/\D/g, '');
  if (v.phone.trim() && !(d.length === 10 || (d.length === 11 && d.startsWith('1')) || (v.phone.trim().startsWith('+') && d.length >= 8 && d.length <= 15))) e.phone = 'Enter a mobile number with area code, or leave it empty.';
  return e;
}

/** A prize of the table (Settings, Discount games): a percentage, an amount or free days, its own minimum length and cap. */
export interface PrizeRow { key: string; percent_bps?: number; amount_cents?: number; free_days?: number; min_days?: number; max_cents?: number; weight: number }
/** What one prize takes off the average booking (net rental charge, billable days), as the database applies it: never
 *  on a shorter booking than its minimum, never above its cap (or the games' cap for a percentage or free days). */
export function prizeCost(p: PrizeRow, basis: { charge_cents: number; days: number }, defaultCap: number | null): number {
  const { charge_cents: c, days } = basis;
  if (c <= 0 || days <= 0) return 0;
  if (p.min_days && days < p.min_days) return 0;
  const cap = p.amount_cents ? null : (p.max_cents ?? defaultCap);
  const raw = p.percent_bps ? Math.round((c * p.percent_bps) / 10000) : p.free_days ? Math.round((c * Math.min(p.free_days, days)) / days) : (p.amount_cents ?? 0);
  return Math.min(raw, c, cap ?? c);
}
/** The expected discount of one claimed code: each prize's cost on the average booking, by its chance. */
export function expectedCost(prizes: PrizeRow[], basis: { charge_cents: number; days: number }, defaultCap: number | null): number {
  const total = prizes.reduce((a, p) => a + (p.weight > 0 ? p.weight : 0), 0);
  if (total <= 0) return 0;
  return prizes.reduce((a, p) => a + (p.weight > 0 ? (p.weight / total) * prizeCost(p, basis, defaultCap) : 0), 0);
}

/** The card pack: five cards, four CarmaCars picture cards (never a real trading card design) and the prize last. */
export type PackCard = { kind: 'art'; title: string; hue: number } | { kind: 'prize' };
const ART = ['City run', 'Highway', 'Airport pickup', 'Road trip', 'Weekend away', 'Night drive', 'Lake drive', 'Downtown'];
export function packCards(r: () => number, count = 5): PackCard[] {
  const pool = [...ART];
  const art: PackCard[] = [];
  for (let i = 0; i < count - 1; i++) {
    const j = Math.floor(r() * pool.length);
    art.push({ kind: 'art', title: pool.splice(j, 1)[0]!, hue: Math.floor(r() * 360) });
  }
  return [...art, { kind: 'prize' }];
}
/** How far the top strip is torn (0 to 1) after a drag from x0 to x across a pack w wide; open at 0.6. */
export const tearProgress = (x0: number, x: number, w: number) => (w <= 0 ? 0 : Math.max(0, Math.min(1, Math.abs(x - x0) / w)));
export const TORN = 0.6;
