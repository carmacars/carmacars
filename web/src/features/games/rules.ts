// Discount games (migration 0069): the rules that decide when a game may show, and the layouts the games draw. Pure
// functions (no browser, no imports) so they are unit tested and shared by the trigger and the games. The prize itself
// is drawn by the database; nothing here can change it.

export type GameKind = 'wheel' | 'scratch' | 'blackjack' | 'cups' | 'plinko';
export const GAMES: GameKind[] = ['wheel', 'scratch', 'blackjack', 'cups', 'plinko'];
export interface GameCfg { on: boolean; car_pages: number; seconds: number; exit: boolean; dismiss_days: number }
/** What this browser remembers (localStorage, the visitor's own device only). */
export interface GameMemory { claimed?: boolean; never?: string; dismissedAt?: number; code?: string; codeUntil?: string }
/** This visit (sessionStorage): when it started, pages and car pages seen, how it began. */
export interface Visit { start: number; pages: number; cars: string[]; fromSearch: boolean }

const DAY = 86_400_000;

/** Pages where a game never shows: booking, paying, signing, sign-in, portals, documents. */
const NEVER = /^\/(book|account|owner|admin|va|field|investor|sign|sign-in|sign-document|create-account|reset-password|update-password|two-step|choose-portal|read-only|link-expired|unsubscribe|guide-pdf|files|d|r|list-your-car\/apply|auth)(\/|$)/;
export const excludedPath = (path: string) => NEVER.test(path) || /\/(pay|sign|checkout)(\/|$)/.test(path);

/** A car page: /cars/<slug>. */
export function carSlug(path: string): string | null {
  const m = /^\/cars\/([a-z0-9-]+)\/?$/.exec(path);
  return m ? m[1]! : null;
}

export function isSearchReferrer(ref: string | null | undefined): boolean {
  if (!ref) return false;
  try { return /(^|\.)(google|bing|duckduckgo|yahoo|ecosia|baidu|yandex|brave|startpage|qwant)\.[a-z.]+$/i.test(new URL(ref).hostname); } catch { return false; }
}

/** Why the game may not show to this visitor now (null: it may). */
export function ineligible(a: { cfg: GameCfg | null; mem: GameMemory; signedIn: boolean; path: string; now: number }): string | null {
  if (a.signedIn) return 'signed_in';
  if (a.mem.claimed) return 'claimed';
  if (a.mem.never) return a.mem.never;
  if (excludedPath(a.path)) return 'page';
  if (!a.cfg) return 'no_settings';
  if (!a.cfg.on) return 'off';
  if (a.mem.dismissedAt && a.now - a.mem.dismissedAt < a.cfg.dismiss_days * DAY) return 'dismissed';
  return null;
}

/** Which rule fires now: enough car pages, enough time, or exit intent (computers only). Never on the first page of a
 *  visit that came from a search engine on a phone (no interstitial on a search landing). */
export function trigger(a: { cfg: GameCfg; visit: Visit; now: number; exit?: boolean; phone: boolean }): 'pages' | 'time' | 'exit' | null {
  if (a.phone && a.visit.fromSearch && a.visit.pages <= 1) return null;
  if (a.cfg.car_pages > 0 && a.visit.cars.length >= a.cfg.car_pages) return 'pages';
  if (a.cfg.seconds > 0 && a.now - a.visit.start >= a.cfg.seconds * 1000) return 'time';
  if (a.exit && a.cfg.exit && !a.phone) return 'exit';
  return null;
}

/** The visit with one more page. */
export function addPage(v: Visit, path: string): Visit {
  const slug = carSlug(path);
  return { ...v, pages: v.pages + 1, cars: slug && !v.cars.includes(slug) ? [...v.cars, slug] : v.cars };
}

export interface PrizeWord { key: string; short: string; label: string }

/** The wheel's 12 slices: the most common prize on every other slice, the rest in turn between them (the rarest once
 *  or twice), so the wheel looks lively; the terms say the chances differ. */
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
  return Array.from({ length: n }, (_, i) => (i % 2 === 0 ? top! : spread[((i - 1) / 2) % spread.length]!));
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

/** Plinko's slots (rows + 1): the rarest prize in the middle, the next rarest beside it, the most common at the sides. */
export function plinkoSlots(prizes: PrizeWord[], rows = 8): PrizeWord[] {
  const n = rows + 1;
  if (!prizes.length) return [];
  const rarest = [...prizes].reverse(); // least likely first
  const mid = Math.floor(n / 2);
  return Array.from({ length: n }, (_, i) => {
    const d = Math.abs(i - mid);
    // distance 0: rarest; 1: next; 2: most common; 3: the third rarest; beyond: the most common
    const pick = d === 0 ? rarest[0] : d === 1 ? rarest[1] : d === 3 ? rarest[2] : prizes[0];
    return pick ?? prizes[0]!;
  });
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
