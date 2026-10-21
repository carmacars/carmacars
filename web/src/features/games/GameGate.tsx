'use client';
import { useCallback, useEffect, useRef, useState, type ComponentType } from 'react';
import { usePathname } from 'next/navigation';
import { browserRpc } from '@/lib/browser-rpc';
import { addPage, addSeen, closed, excludedPath, ineligible, isSearchReferrer, nextCheck, shown, trigger, type Fire, type GameCfg, type GameKind, type GameMemory, type Visit } from './rules';
import type { GamePopupProps } from './GamePopup';

// Discount games (migrations 0069 and 0076): the watcher. Loaded after the page is idle (with the beacon and the chat),
// it counts this visit's pages, car pages and time in the browser only (sessionStorage: nothing leaves the device for
// this). The first game comes after 1 car page or 15 seconds (or the mouse leaving towards the tabs on a computer);
// after a close another game this browser has not seen comes after 2 more car pages or 3 minutes, at most 3 a visit,
// and again on later visits; never after a claim. Never for a signed-in visitor (they get it in the request-to-book
// form only), never on booking, pay, sign, sign-in or portal pages, never over the cookie banner. On the first page of
// a phone visit from a search engine it waits for the second page, or comes 15 seconds later as a small slide-in. The
// game's code is fetched in idle time once the visitor can get one, so it opens at once.
const MEM = 'cc_game', VISIT = 'cc_game_visit', CFG = 'cc_game_cfg';
const read = <T,>(s: Storage | undefined, k: string): T | null => { try { return JSON.parse(s?.getItem(k) ?? 'null') as T | null; } catch { return null; } };
const write = (s: Storage | undefined, k: string, v: unknown) => { try { s?.setItem(k, JSON.stringify(v)); } catch { /* private mode */ } };
export const memory = (): GameMemory => { try { return read<GameMemory>(globalThis.localStorage, MEM) ?? {}; } catch { return {}; } };
export const remember = (m: Partial<GameMemory>) => { try { write(globalThis.localStorage, MEM, { ...memory(), ...m }); } catch { /* none */ } };
/** A game was on screen: this browser has seen it (the round of five). */
export const rememberSeen = (g: GameKind) => remember({ seen: addSeen(memory().seen, g) });
/** Signed in: Supabase's session cookie (readable by the page), or the local stack's hint. */
export const signedIn = () => /(^|;\s*)(sb-[a-z0-9]+-auth-token(\.0)?|cc-local-in)=/.test(document.cookie);
const answeredCookies = () => /(^|;\s*)cc_cookie_choice=/.test(document.cookie);
const phone = () => matchMedia('(max-width: 599px)').matches;
// automated browsers (tests, the guides' screenshots, audits) never get a game unless a test asks for it
export const automated = () => { try { return navigator.webdriver && localStorage.getItem('cc_games_e2e') !== '1'; } catch { return navigator.webdriver; } };
const visitNow = () => read<Visit>(globalThis.sessionStorage, VISIT);
const saveVisit = (v: Visit) => write(globalThis.sessionStorage, VISIT, v);
const idle = (f: () => void) => ('requestIdleCallback' in window ? requestIdleCallback(f, { timeout: 4000 }) : setTimeout(f, 1200));

/** The settings (kept 30 minutes in this tab). */
export async function gameSettings(): Promise<GameCfg | null> {
  const c = read<{ at: number; v: GameCfg }>(globalThis.sessionStorage, CFG);
  if (c && Date.now() - c.at < 30 * 60_000 && typeof c.v.per_visit === 'number') return c.v;
  try { const v = await browserRpc<GameCfg>('game_cfg', {}); write(globalThis.sessionStorage, CFG, { at: Date.now(), v }); return v; } catch { return null; }
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

  const may = useCallback(() => !automated() && !ineligible({ cfg: cfg.current, mem: memory(), signedIn: signedIn(), path: pathRef.current, visit: visitNow() }), []);

  const fire = useCallback((f: Fire) => {
    if (open.current || !may()) return;
    // the cookie banner first: one thing at a time
    if (!answeredCookies()) { addEventListener('cc:consent', () => again.current(), { once: true }); return; }
    open.current = true;
    const v = visitNow();
    if (v) saveVisit(shown(v));
    setFired(f);
    void loadPopup().then((m) => setPopup(() => m.GamePopup)).catch(() => { open.current = false; });
  }, [may]);

  const check = useCallback((exit = false) => {
    if (timer.current) { clearTimeout(timer.current); timer.current = undefined; }
    const c = cfg.current, v = visitNow();
    if (!c || !v || open.current || !may()) return;
    const f = trigger({ cfg: c, visit: v, now: Date.now(), exit, phone: phone() });
    if (f) { fire(f); return; }
    const wait = nextCheck({ cfg: c, visit: v, now: Date.now(), phone: phone() });
    if (wait !== null) timer.current = setTimeout(() => again.current(), wait + 250);
  }, [fire, may]);
  useEffect(() => { again.current = check; }, [check]);

  // the visit: one more page on every address, then look again
  useEffect(() => {
    pathRef.current = path;
    // a page where games never show closes an open one (it counts as closed)
    if (open.current && excludedPath(path)) { open.current = false; setPopup(null); setFired(null); const o = visitNow(); if (o) saveVisit(closed(o, Date.now())); }
    let v = visitNow();
    if (!v) v = { start: Date.now(), pages: 0, cars: [], fromSearch: isSearchReferrer(document.referrer), shows: 0 };
    saveVisit(addPage(v, path));
    check();
  }, [path, check]);

  // once: the settings, the exit intent, and the game's code in idle time when this visitor can get one
  useEffect(() => {
    let live = true;
    const onLeave = (e: MouseEvent) => { if (!e.relatedTarget && e.clientY <= 0) check(true); };
    (async () => {
      if (automated() || signedIn() || memory().claimed) return;
      cfg.current = await gameSettings();
      if (!live || !cfg.current || !may()) return;
      idle(() => { if (live && may()) void loadPopup().catch(() => undefined); });
      if (cfg.current.exit && !phone()) { document.documentElement.addEventListener('mouseleave', onLeave); }
      check();
    })();
    return () => { live = false; if (timer.current) clearTimeout(timer.current); document.documentElement.removeEventListener('mouseleave', onLeave); };
  }, [check, may]);

  const done = useCallback((how: 'closed' | 'claimed' | 'failed') => {
    setPopup(null); setFired(null); open.current = false;
    const v = visitNow();
    if (v) saveVisit(closed(v, Date.now()));
    if (how !== 'claimed') check();
  }, [check]);

  if (!Popup || !fired || excludedPath(path)) return null;
  return <Popup trigger={fired.why} slim={fired.slim} path={path} seen={memory().seen ?? []} onDone={done} />;
}
