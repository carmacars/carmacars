// Discount games (migrations 0069, 0081, 0094 and 0100): the rules that decide when a game may show (first, again after
// a close, in the request-to-book form), the rotation, and the layouts the games draw. Pure functions (no browser, no imports) so they are
// unit tested and shared by the trigger and the games. The prize itself is drawn by the database; nothing here can
// change it.

export type GameKind = 'wheel' | 'scratch' | 'blackjack' | 'cups' | 'plinko' | 'pack' | 'coin' | 'dice' | 'slots' | 'drop' | 'mystery';
/** The games, in the database's order (app.game_kinds; 0100 adds the last five). */
export const GAMES: GameKind[] = ['wheel', 'scratch', 'blackjack', 'cups', 'plinko', 'pack', 'coin', 'dice', 'slots', 'drop', 'mystery'];
/** The browser's settings (app.game_cfg): the first show (page views, any page, since 0100: the key keeps its old name
 *  car_pages; or seconds on the site; exit intent), the re-show after a close (page views since the close or seconds
 *  since the close, whichever first), the most shows in one visit and in one day in this browser
 *  (0094), and the offer in the request-to-book form. */
export interface GameCfg { on: boolean; car_pages: number; seconds: number; exit: boolean; reshow_pages: number; reshow_seconds: number; per_visit: number; per_day?: number | null; booking: boolean }
/** A prize this browser already won and has not claimed (0100): shown as "Your 5% off is saved", never as a new win. */
export interface SavedPrize { label: string; short: string; at: number }
/** What this browser remembers (localStorage, the visitor's own device only): a claim, a refusal from the server, the
 *  games shown in the current round, the code, the last game shown (0100), a prize won and not claimed yet (0100), and
 *  when a booking request was started or sent here (0100). dismissedAt is from 0069 and no longer read. */
export interface GameMemory { claimed?: boolean; never?: string; seen?: GameKind[]; last?: GameKind; dismissedAt?: number; code?: string; codeUntil?: string; day?: string; dayShows?: number;
  won?: SavedPrize; requested?: number }
/** This visit (sessionStorage): when it started, pages and car pages seen, how it began, the games shown, and when the
 *  last one was closed (with the car pages seen by then). */
export interface Visit { start: number; pages: number; cars: string[]; fromSearch: boolean; shows?: number; closedAt?: number; carsAtClose?: number; pagesAtClose?: number }

/** The browser's day (Toronto), for the most games in one day (0094). */
export const gameDay = (now: number) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date(now));
/** How many games this browser showed today (0094). */
export const shownToday = (m: GameMemory, now: number) => (m.day === gameDay(now) ? m.dayShows ?? 0 : 0);
/** The memory after one more game shown today. */
export const countShown = (m: GameMemory, now: number): Partial<GameMemory> => ({ day: gameDay(now), dayShows: shownToday(m, now) + 1 });
/** How long a won prize stays saved in this browser: the days the database keeps the prize drawn for a visitor
 *  (game_dismiss_days, 14 by default). */
export const SAVED_DAYS = 14;
/** The prize won in this browser and not claimed yet, while it lasts (0100). */
export const savedPrize = (m: GameMemory, now: number): SavedPrize | null =>
  (m.won && !m.claimed && now - m.won.at < SAVED_DAYS * 86_400_000 ? m.won : null);
/** The words of the saved badge: "Your 5% off is saved". */
export const savedWords = (p: { label: string }) => `Your ${p.label} is saved`;
/** How long a booking request in progress keeps the games away (0100). */
export const REQUEST_DAYS = 30;
/** A booking request in progress in this browser (0100): the request form's draft (localStorage cc.request.v2, with a
 *  step past the first or a saved draft), or a request sent here. Then no game shows on the site. */
export function requestInProgress(a: { mem: GameMemory; draft: { step?: number; token?: string | null; draftId?: string | null; at?: number } | null; now: number }): boolean {
  const recent = (t: number | undefined) => typeof t === 'number' && a.now - t < REQUEST_DAYS * 86_400_000;
  if (recent(a.mem.requested)) return true;
  const d = a.draft;
  return Boolean(d && recent(d.at) && ((d.step ?? 1) > 1 || d.token || d.draftId));
}
export type Trigger = 'pages' | 'time' | 'exit';
/** Why a game shows, and whether as the small slide-in (the first page of a phone visit from a search engine). */
export interface Fire { why: Trigger | 'saved'; slim: boolean }

/** How much later the small slide-in comes on the first page of a phone visit from a search engine. */
export const SEARCH_LANDING_DELAY = 15_000;

/** Pages where a game never shows: booking, checkout and paying, signing, sign-in, portals, documents, a request's own
 *  pages (0100: my-request, continue). The request-to-book form has its own game (bookingPath). */
const NEVER = /^\/(book|account|owner|admin|va|field|investor|sign|sign-in|sign-document|create-account|reset-password|update-password|two-step|choose-portal|read-only|link-expired|unsubscribe|guide-pdf|files|d|r|list-your-car\/apply|auth|my-request|continue|checkout|pay|payment)(\/|$)/;
const PAYSIGN = /\/(pay|payment|sign|checkout)(\/|$)/;
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

/** Why the site's game may not show to this visitor now (null: it may). Signed-in people never see it on the site.
 *  0100: never once a prize was won here (the saved badge shows instead) or a booking request is in progress. */
export function ineligible(a: { cfg: GameCfg | null; mem: GameMemory; signedIn: boolean; path: string; visit?: Visit | null; now?: number; busy?: boolean }): string | null {
  if (a.signedIn) return 'signed_in';
  if (a.mem.claimed) return 'claimed';
  if (a.mem.never) return a.mem.never;
  if (excludedPath(a.path)) return 'page';
  if (a.busy) return 'in_progress';
  if (savedPrize(a.mem, a.now ?? Date.now())) return 'saved';
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

/** After a close: the page views since the close (any page) or the time since the close, whichever comes first
 *  (0094, the owner's 0100 defaults: the 3rd page view or 2 minutes); a rule set to 0 is left out; both at 0: no game
 *  again in this visit. */
export function reshowDue(cfg: GameCfg, v: Visit, now: number): Trigger | null {
  if (v.closedAt === undefined) return null;
  if (cfg.reshow_pages > 0 && v.pages - (v.pagesAtClose ?? v.pages) >= cfg.reshow_pages) return 'pages';
  if (cfg.reshow_seconds > 0 && now - v.closedAt >= cfg.reshow_seconds * 1000) return 'time';
  return null;
}

/** Which rule fires now. The first game of a visit: enough page views (any page, 0100), enough time, or exit intent
 *  (computers only, when on), whichever first. After a close: enough page views or enough time since the close,
 *  whichever first. On the first page of a phone visit from a search engine there is no interstitial: the
 *  game waits for the second page, or comes SEARCH_LANDING_DELAY after its rule as the small slide-in. */
export function trigger(a: { cfg: GameCfg; visit: Visit; now: number; exit?: boolean; phone: boolean; today?: number }): Fire | null {
  const { cfg, visit: v, now } = a;
  const shows = v.shows ?? 0;
  if (shows >= Math.max(1, cfg.per_visit)) return null;
  if (cfg.per_day && (a.today ?? 0) >= cfg.per_day) return null;
  if (shows > 0) {
    if (v.closedAt === undefined) return null; // one is open
    const why = reshowDue(cfg, v, now);
    return why ? { why, slim: false } : null;
  }
  // 0100: page views on any page (the 2nd by default)
  const byPages = cfg.car_pages > 0 && v.pages >= cfg.car_pages;
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
export function nextCheck(a: { cfg: GameCfg; visit: Visit; now: number; phone: boolean; today?: number }): number | null {
  const { cfg, visit: v, now } = a;
  const shows = v.shows ?? 0;
  if (shows >= Math.max(1, cfg.per_visit)) return null;
  if (cfg.per_day && (a.today ?? 0) >= cfg.per_day) return null;
  let at: number | null = null;
  if (shows > 0) {
    // the time rule is the one a timer can wait for; the page rule is checked on each page
    if (v.closedAt !== undefined && cfg.reshow_seconds > 0) at = v.closedAt + cfg.reshow_seconds * 1000;
  } else {
    const byPages = cfg.car_pages > 0 && v.pages >= cfg.car_pages;
    const timeAt = cfg.seconds > 0 ? v.start + cfg.seconds * 1000 : null;
    if (a.phone && v.fromSearch && v.pages <= 1) at = byPages ? v.start + SEARCH_LANDING_DELAY : timeAt === null ? null : timeAt + SEARCH_LANDING_DELAY;
    else at = timeAt;
  }
  return at === null ? null : Math.max(0, at - now);
}

/** The visit after a game is shown, and after it is closed. */
export const shown = (v: Visit): Visit => ({ ...v, shows: (v.shows ?? 0) + 1, closedAt: undefined, carsAtClose: undefined, pagesAtClose: undefined });
export const closed = (v: Visit, now: number): Visit => ({ ...v, closedAt: now, carsAtClose: v.cars.length, pagesAtClose: v.pages });

/** The games this browser has shown in the current round, with one more: once every game on was shown, a new round
 *  starts with the one just shown (so the next is never the same twice in a row). */
export function addSeen(seen: GameKind[] | undefined, g: GameKind, on: GameKind[] = GAMES): GameKind[] {
  const s = (seen ?? []).filter((x) => on.includes(x));
  const next = s.includes(g) ? s : [...s, g];
  return on.every((x) => next.includes(x)) ? [g] : next;
}

/** The games that may come next (the server's own rule, app.game_next_kind): the ones still to come in this round
 *  (all of them again once the round is complete), never the game shown last while another is on (0100), so one
 *  visitor never gets the same game twice in a row. */
export function unseen(seen: GameKind[] | undefined, on: GameKind[] = GAMES, last?: GameKind): GameKind[] {
  const s = (seen ?? []).filter((x) => on.includes(x));
  let left = on.filter((x) => !s.includes(x));
  if (!left.length) left = on;
  const fresh = left.filter((x) => x !== last);
  return fresh.length ? fresh : left;
}
/** One pick by weight among the games that may come next. */
export function nextGame(a: { seen?: GameKind[]; last?: GameKind; on?: GameKind[]; weights?: Partial<Record<GameKind, number>>; r: () => number }): GameKind | null {
  const on = (a.on ?? GAMES).filter((g) => (a.weights ? (a.weights[g] ?? 0) > 0 : true));
  if (!on.length) return null;
  const pool = unseen(a.seen, on, a.last);
  const w = pool.map((g) => (a.weights ? a.weights[g] ?? 0 : 1));
  const total = w.reduce((x, y) => x + y, 0);
  let x = a.r() * total;
  for (let i = 0; i < pool.length; i++) { x -= w[i]!; if (x < 0) return pool[i]!; }
  return pool[pool.length - 1]!;
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

/** The slot machine (0100): three reels of the prize table's words (each prize at least once, the common ones more
 *  often, the rare ones once), and where each reel stops so the middle row shows the drawn prize three times. The
 *  first two reels often pass a bigger prize just before they stop. */
export function slotStrip(prizes: PrizeWord[], n = 12): PrizeWord[] { return wheelSlices(prizes, n); }
export function slotStops(strip: PrizeWord[], key: string, r: () => number, reels = 3): number[] {
  const at = strip.map((s, i) => (s.key === key ? i : -1)).filter((i) => i >= 0);
  const pick = () => (at.length ? at[Math.floor(r() * at.length)]! : 0);
  return Array.from({ length: reels }, pick);
}
/** A die's face (1 to 6). The dice and the coin are for show: whatever they land on, the prize is the one drawn. */
export const dieFace = (r: () => number) => 1 + Math.min(5, Math.floor(r() * 6));
export type CoinSide = 'heads' | 'tails';
export const coinFlip = (r: () => number): CoinSide => (r() < 0.5 ? 'heads' : 'tails');
/** The mystery boxes (0100): three closed boxes; whichever is picked opens on the drawn prize, the other two stay shut. */
export const MYSTERY_BOXES = 3;
