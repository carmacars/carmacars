'use client';
import { useEffect, useRef, useState, type ComponentType } from 'react';
import { usePathname } from 'next/navigation';
import { browserRpc } from '@/lib/browser-rpc';
import { addPage, excludedPath, ineligible, isSearchReferrer, trigger, type GameCfg, type GameMemory, type Visit } from './rules';
import type { GamePopupProps } from './GamePopup';

// Discount games (migration 0069): the watcher. Loaded after the page is idle (with the beacon and the chat), it counts
// this visit's pages, car pages and time in the browser only (sessionStorage: nothing leaves the device for this),
// and when a rule fires (2 car pages, 60 seconds, or the mouse leaving towards the tabs on a computer) it loads the
// game itself. Never for a signed-in visitor, never on booking, pay, sign, sign-in or portal pages, never over the
// cookie banner, never on the first page of a search visit on a phone, never again after a claim.
const MEM = 'cc_game', VISIT = 'cc_game_visit', CFG = 'cc_game_cfg';
const read = <T,>(s: Storage | undefined, k: string): T | null => { try { return JSON.parse(s?.getItem(k) ?? 'null') as T | null; } catch { return null; } };
const write = (s: Storage | undefined, k: string, v: unknown) => { try { s?.setItem(k, JSON.stringify(v)); } catch { /* private mode */ } };
export const memory = (): GameMemory => read<GameMemory>(globalThis.localStorage, MEM) ?? {};
export const remember = (m: Partial<GameMemory>) => write(globalThis.localStorage, MEM, { ...memory(), ...m });
/** Signed in: Supabase's session cookie (readable by the page), or the local stack's hint. */
export const signedIn = () => /(^|;\s*)(sb-[a-z0-9]+-auth-token(\.0)?|cc-local-in)=/.test(document.cookie);
const answeredCookies = () => /(^|;\s*)cc_cookie_choice=/.test(document.cookie);
const phone = () => matchMedia('(max-width: 599px)').matches;
// automated browsers (tests, the guides' screenshots, audits) never get a game unless a test asks for it
const automated = () => navigator.webdriver && localStorage.getItem('cc_games_e2e') !== '1';

async function settings(): Promise<GameCfg | null> {
  const c = read<{ at: number; v: GameCfg }>(globalThis.sessionStorage, CFG);
  if (c && Date.now() - c.at < 30 * 60_000) return c.v;
  try { const v = await browserRpc<GameCfg>('game_cfg', {}); write(globalThis.sessionStorage, CFG, { at: Date.now(), v }); return v; } catch { return null; }
}

export function GameGate() {
  const path = usePathname() ?? '/';
  const [Popup, setPopup] = useState<ComponentType<GamePopupProps> | null>(null);
  const [fired, setFired] = useState<'pages' | 'time' | 'exit' | null>(null);
  const cfg = useRef<GameCfg | null>(null);
  const done = useRef(false);
  const pathRef = useRef(path);

  // the visit: one more page on every address
  useEffect(() => {
    pathRef.current = path;
    let v = read<Visit>(globalThis.sessionStorage, VISIT);
    if (!v) v = { start: Date.now(), pages: 0, cars: [], fromSearch: isSearchReferrer(document.referrer) };
    v = addPage(v, path);
    write(globalThis.sessionStorage, VISIT, v);
  }, [path]);

  useEffect(() => {
    if (done.current) return;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let live = true;
    const fire = (why: 'pages' | 'time' | 'exit') => {
      if (done.current || !live) return;
      if (ineligible({ cfg: cfg.current, mem: memory(), signedIn: signedIn(), path: pathRef.current, now: Date.now() })) return;
      // the cookie banner first: one thing at a time
      if (!answeredCookies()) { addEventListener('cc:consent', () => fire(why), { once: true }); return; }
      done.current = true;
      setFired(why);
      const load = () => import('./GamePopup');
      void load().catch(() => new Promise<Awaited<ReturnType<typeof load>>>((ok) => setTimeout(() => load().then(ok, () => undefined), 3000)))
        .then((m) => { if (live && m) setPopup(() => m.GamePopup); });
    };
    const check = (exit = false) => {
      const c = cfg.current;
      const v = read<Visit>(globalThis.sessionStorage, VISIT);
      if (!c || !v) return;
      const why = trigger({ cfg: c, visit: v, now: Date.now(), exit, phone: phone() });
      if (why) fire(why);
    };
    const onLeave = (e: MouseEvent) => { if (!e.relatedTarget && e.clientY <= 0) check(true); };
    (async () => {
      if (automated() || signedIn()) return;
      if (ineligible({ cfg: { on: true, car_pages: 1, seconds: 1, exit: true, dismiss_days: 0 }, mem: memory(), signedIn: false, path, now: Date.now() }) === 'claimed') return;
      cfg.current = await settings();
      if (!live || !cfg.current || ineligible({ cfg: cfg.current, mem: memory(), signedIn: signedIn(), path, now: Date.now() })) return;
      check();
      const v = read<Visit>(globalThis.sessionStorage, VISIT);
      if (cfg.current.seconds > 0 && v) timer = setTimeout(() => check(), Math.max(0, cfg.current.seconds * 1000 - (Date.now() - v.start)) + 250);
      if (cfg.current.exit && !phone()) document.documentElement.addEventListener('mouseleave', onLeave);
    })();
    return () => { live = false; if (timer) clearTimeout(timer); document.documentElement.removeEventListener('mouseleave', onLeave); };
  }, [path]);

  if (!Popup || !fired || excludedPath(path)) return null;
  return <Popup trigger={fired} path={path} onDone={() => { setPopup(null); }} />;
}
