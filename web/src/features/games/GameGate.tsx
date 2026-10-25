'use client';
import './games.css';
import { useCallback, useEffect, useRef, useState, type ComponentType } from 'react';
import { usePathname } from 'next/navigation';
import { browserRpc } from '@/lib/browser-rpc';
import { addPage, addSeen, claimMemory, claimWait, closed, countShown, excludedPath, shownToday, ineligible, isReplay, isSearchReferrer, nextCheck, requestInProgress, savedPrize, savedWords, shown, trigger, type Fire, type GameCfg, type GameKind, type GameMemory, type PrizeWord, type Visit } from './rules';
import type { GamePopupProps } from './GamePopup';

// Discount games (migrations 0069, 0081, 0094, 0100, 0171 and 0172): the watcher. Loaded after the page is idle (with the beacon and
// the chat), it counts this visit's pages and time in the browser only (sessionStorage: nothing leaves the device for
// this). 0100 (the owner's defaults, all Admin settings): the first game on the 2nd page view (any page) or after 30
// seconds, whichever first; after a close another game, never the one just shown, on the 3rd page view after the close
// or 2 minutes later, whichever first; at most 4 a visit, no daily cap unless one is set; and again on later visits.
// After a claim (0172) not again in that visit, and back on a later visit once the wait after it ends (a day by default,
// the server's again_after); never once a booking request is in progress in this browser, and never as a new win once a
// prize was won here: a small badge "Your 5% off is saved" opens its claim form, and (0171) the card itself pops up again
// with that prize ("Your 5% off is still waiting") on the same rules as a game. Never for a signed-in visitor (they get it in the request-to-book
// form only), never on booking, pay, sign, sign-in or portal pages, never over the cookie banner. On the first page of
// a phone visit from a search engine it waits for the second page, or comes 15 seconds later as a small slide-in. The
// game's code is fetched in idle time once the visitor can get one, so it opens at once.
const MEM = 'cc_game', VISIT = 'cc_game_visit', CFG = 'cc_game_cfg', BADGE_CLOSED = 'cc_game_saved_closed', REQUEST = 'cc.request.v2';
const read = <T,>(s: Storage | undefined, k: string): T | null => { try { return JSON.parse(s?.getItem(k) ?? 'null') as T | null; } catch { return null; } };
const write = (s: Storage | undefined, k: string, v: unknown) => { try { s?.setItem(k, JSON.stringify(v)); } catch { /* private mode */ } };
export const memory = (): GameMemory => { try { return read<GameMemory>(globalThis.localStorage, MEM) ?? {}; } catch { return {}; } };
export const remember = (m: Partial<GameMemory>) => { try { write(globalThis.localStorage, MEM, { ...memory(), ...m }); } catch { /* none */ } };
/** A game was on screen: this browser has seen it (the round), and it is the last one shown (0100: never twice in a row). */
export const rememberSeen = (g: GameKind) => remember({ seen: addSeen(memory().seen, g), last: g });
/** A prize won here and not claimed yet (0100): later pages show the saved badge, never a new win. */
export const rememberWon = (p: PrizeWord) => {
  // 0171: the replay prize is a second game, never a discount to keep
  if (isReplay(p)) return;
  const m = memory(); if (!m.won || m.won.label !== p.label) remember({ won: { label: p.label, short: p.short, at: Date.now() } });
};
export const forgetSaved = () => remember({ won: undefined });
/** 0172: a code claimed here (or the server said this person claimed one): no more games this visit, and none until the
 *  server's again_after; an old memory without a time never stops a game. */
export const rememberClaim = (againAfter?: string | null, extra: Partial<GameMemory> = {}) => {
  remember({ ...claimMemory(againAfter, Date.now()), ...extra });
  const v = visitNow(); if (v) saveVisit({ ...v, claimed: true });
};

/** A game card is on screen (0100): the chat's greeting waits for it to close. */
export const GAME_EVENT = 'cc:game';
export const gameOnScreen = () => document.documentElement.hasAttribute('data-cc-game');
const announce = (on: boolean) => {
  if (on) document.documentElement.setAttribute('data-cc-game', ''); else document.documentElement.removeAttribute('data-cc-game');
  dispatchEvent(new CustomEvent(GAME_EVENT, { detail: { open: on } }));
};
/** A booking request started or sent in this browser (0100). */
const requestDraft = () => { try { return JSON.parse(localStorage.getItem(REQUEST) ?? 'null') as { step?: number; token?: string | null; draftId?: string | null; at?: number } | null; } catch { return null; } };
const busy = () => requestInProgress({ mem: memory(), draft: requestDraft(), now: Date.now() });
/** Signed in: Supabase's session cookie (readable by the page), or the local stack's hint. */
export const signedIn = () => /(^|;\s*)(sb-[a-z0-9]+-auth-token(\.0)?|cc-local-in)=/.test(document.cookie);
const answeredCookies = () => /(^|;\s*)cc_cookie_choice=/.test(document.cookie);
const phone = () => matchMedia('(max-width: 599px)').matches;
// automated browsers (tests, the guides' screenshots, audits) never get a game unless a test asks for it
export const automated = () => { try { return navigator.webdriver && localStorage.getItem('cc_games_e2e') !== '1'; } catch { return navigator.webdriver; } };
const visitNow = () => read<Visit>(globalThis.sessionStorage, VISIT);
const saveVisit = (v: Visit) => write(globalThis.sessionStorage, VISIT, v);
const idle = (f: () => void) => ('requestIdleCallback' in window ? requestIdleCallback(f, { timeout: 4000 }) : setTimeout(f, 1200));

/** The settings (kept 30 minutes in this tab). An automated browser a test let play may set its own timings
 *  (localStorage cc_games_e2e_cfg); a person's browser never reads it. */
export async function gameSettings(): Promise<GameCfg | null> {
  const c = read<{ at: number; v: GameCfg }>(globalThis.sessionStorage, CFG);
  let v: GameCfg | null = c && Date.now() - c.at < 30 * 60_000 && typeof c.v.per_visit === 'number' ? c.v : null;
  if (!v) { try { v = await browserRpc<GameCfg>('game_cfg', {}); write(globalThis.sessionStorage, CFG, { at: Date.now(), v }); } catch { return null; } }
  try { if (v && navigator.webdriver) { const o = read<Partial<GameCfg>>(globalThis.localStorage, 'cc_games_e2e_cfg'); if (o) v = { ...v, ...o }; } } catch { /* none */ }
  return v;
}

type PopupMod = typeof import('./GamePopup');
let popupMod: Promise<PopupMod> | null = null;
/** The game's code (the card and the five games): fetched once, in idle time, retried once if the network drops it. */
export function loadPopup(): Promise<PopupMod> {
  if (!popupMod) {
    const load = () => import('./GamePopup');
    popupMod = load().catch(() => new Promise<PopupMod>((ok, ko) => setTimeout(() => load().then(ok, ko), 3000)));
    popupMod.then((m) => m.preloadGames()).catch(() => { popupMod = null; });
  }
  return popupMod;
}

export function GameGate() {
  const path = usePathname() ?? '/';
  const [Popup, setPopup] = useState<ComponentType<GamePopupProps> | null>(null);
  const [fired, setFired] = useState<Fire | null>(null);
  const cfg = useRef<GameCfg | null>(null);
  const open = useRef(false);
  const pathRef = useRef(path);
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  // the latest check, for timers and listeners set up earlier
  const again = useRef<(exit?: boolean) => void>(() => undefined);

  const [badge, setBadge] = useState<{ label: string } | null>(null);
  const may = useCallback(() => !automated() && !ineligible({ cfg: cfg.current, mem: memory(), signedIn: signedIn(), path: pathRef.current, visit: visitNow(), now: Date.now(), busy: busy() }), []);
  // 0100: a prize won here and not claimed: the small badge between cards (closed: not again this visit); 0171: the
  // card itself still pops up again with that prize on the usual rules
  const showBadge = useCallback(() => {
    const p = savedPrize(memory(), Date.now());
    let hidden = false;
    try { hidden = sessionStorage.getItem(BADGE_CLOSED) === '1'; } catch { /* private mode */ }
    setBadge(p && !automated() && !signedIn() && !hidden && !excludedPath(pathRef.current) && cfg.current?.on !== false ? { label: p.label } : null);
  }, []);

  const fire = useCallback((f: Fire) => {
    if (open.current || !may()) return;
    // the cookie banner first: one thing at a time
    if (!answeredCookies()) { addEventListener('cc:consent', () => again.current(), { once: true }); return; }
    open.current = true;
    const v = visitNow();
    if (v) saveVisit(shown(v));
    remember(countShown(memory(), Date.now()));
    setFired(f);
    announce(true);
    void loadPopup().then((m) => setPopup(() => m.GamePopup)).catch(() => { open.current = false; });
  }, [may]);

  const check = useCallback((exit = false) => {
    if (timer.current) { clearTimeout(timer.current); timer.current = undefined; }
    const c = cfg.current, v = visitNow();
    if (!c || !v || open.current || !may()) return;
    const today = shownToday(memory(), Date.now());
    const f = trigger({ cfg: c, visit: v, now: Date.now(), exit, phone: phone(), today });
    if (f) { fire(f); return; }
    const wait = nextCheck({ cfg: c, visit: v, now: Date.now(), phone: phone(), today });
    if (wait !== null) timer.current = setTimeout(() => again.current(), wait + 250);
  }, [fire, may]);
  useEffect(() => { again.current = check; }, [check]);

  // the visit: one more page on every address, then look again
  useEffect(() => {
    pathRef.current = path;
    // 0100: a request sent here (its sent page, or its own page): no more games on the site
    if (/^\/(book\/sent|my-request)(\/|$)/.test(path)) remember({ requested: Date.now() });
    // a page where games never show closes an open one (it counts as closed)
    if (open.current && excludedPath(path)) { open.current = false; setPopup(null); setFired(null); announce(false); const o = visitNow(); if (o) saveVisit(closed(o, Date.now())); }
    let v = visitNow();
    if (!v) v = { start: Date.now(), pages: 0, cars: [], fromSearch: isSearchReferrer(document.referrer), shows: 0 };
    // a game left open by a full page load (or a closed tab) counts as closed when this page starts
    else if (!open.current && (v.shows ?? 0) > 0 && v.closedAt === undefined) v = closed(v, Date.now());
    saveVisit(addPage(v, path));
    check();
    showBadge();
  }, [path, check, showBadge]);

  // once: the settings, the exit intent, and the game's code in idle time when this visitor can get one
  useEffect(() => {
    let live = true;
    const onLeave = (e: MouseEvent) => { if (!e.relatedTarget && e.clientY <= 0) check(true); };
    (async () => {
      if (automated() || signedIn() || claimWait(memory(), Date.now()) !== null) return;
      cfg.current = await gameSettings();
      if (live) showBadge();
      if (!live || !cfg.current || !may()) return;
      idle(() => { if (live && may()) void loadPopup().catch(() => undefined); });
      if (cfg.current.exit && !phone()) { document.documentElement.addEventListener('mouseleave', onLeave); }
      check();
    })();
    return () => { live = false; if (timer.current) clearTimeout(timer.current); document.documentElement.removeEventListener('mouseleave', onLeave); };
  }, [check, may, showBadge]);

  const done = useCallback((how: 'closed' | 'claimed' | 'failed') => {
    const wasSaved = fired?.why === 'saved';
    setPopup(null); setFired(null); open.current = false;
    announce(false);
    // the saved prize's card does not count as a game shown
    if (!wasSaved) { const v = visitNow(); if (v) saveVisit(closed(v, Date.now())); }
    if (how === 'closed' && wasSaved) { try { sessionStorage.setItem(BADGE_CLOSED, '1'); } catch { /* private mode */ } }
    showBadge();
    if (how !== 'claimed') check();
  }, [check, fired, showBadge]);

  // the badge opens the saved prize's claim form (the server's play for this visitor, already revealed)
  const openSaved = useCallback(() => {
    if (open.current) return;
    open.current = true;
    setBadge(null);
    setFired({ why: 'saved', slim: false });
    announce(true);
    void loadPopup().then((m) => setPopup(() => m.GamePopup)).catch(() => { open.current = false; announce(false); showBadge(); });
  }, [showBadge]);
  const closeBadge = useCallback(() => {
    try { sessionStorage.setItem(BADGE_CLOSED, '1'); } catch { /* private mode */ }
    setBadge(null);
  }, []);

  if (Popup && fired && !excludedPath(path)) return <Popup trigger={fired.why} slim={fired.slim} path={path} seen={memory().seen ?? []} onDone={done} />;
  if (badge) return (
    <section className="ccg ccg--saved" role="region" aria-label="Your CarmaCars discount" data-testid="game-saved">
      <p className="ccg-saved__text">{savedWords(badge)}</p>
      <button type="button" className="btn btn--primary btn--sm ccg-saved__go" onClick={openSaved} data-testid="game-saved-open">Get my code</button>
      <button type="button" className="ccg-x ccg-x--dark" onClick={closeBadge} aria-label="Hide the saved discount" data-testid="game-saved-close">×</button>
    </section>
  );
  return null;
}
