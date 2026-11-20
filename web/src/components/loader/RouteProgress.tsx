'use client';
import { useCallback, useEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { usePathname } from 'next/navigation';
import { PageSkeleton, shapeFor, type Shape } from './skeletons';

// r48 speed (docs/changes/2026-11-20-r48-perf.md): instant feedback on every tap, on every page, in one place.
//  - A link to another page: the brand-red bar at the top starts at once, and after a moment (so a fast page never
//    flickers) the page area shows the skeleton of the page being opened (skeletons.tsx shapeFor) until it arrives. The
//    portals' links do not prefetch (prefetch={false}), so without this the old page stayed put until the server answered.
//  - A form sent to a server action: its button is marked busy (BrandLoader's busy style) until the action answers.
// Nothing here changes what a link or a form does; it only watches. Everything clears by itself after a while in case a
// navigation never completes (a download, a link the browser opens elsewhere).

const SKELETON_AFTER_MS = 140;
const GIVE_UP_MS = 15_000;
// the part of each frame that holds the page (admin and staff, owner and renter, everything else)
const SLOTS = ['.ad__main', '.pt__body', '#main'];

type Pending = { shape: Shape | null; slot: Element | null };

function internalTarget(a: HTMLAnchorElement): URL | null {
  if (a.target && a.target !== '_self') return null;
  if (a.hasAttribute('download')) return null;
  const href = a.getAttribute('href');
  if (!href || href.startsWith('#') || /^(mailto|tel|sms|javascript):/i.test(href)) return null;
  let url: URL;
  try { url = new URL(a.href, location.href); } catch { return null; }
  if (url.origin !== location.origin) return null;
  // a route handler (a file, a PDF, an export) is a download, not a page
  if (/^\/(api|files|_next|_local|guide-pdf)\//.test(url.pathname) || /\.(pdf|csv|xlsx?|zip|ics|json|xml|txt|png|jpe?g|svg)$/i.test(url.pathname)) return null;
  return url;
}

export function RouteProgress() {
  const pathname = usePathname();
  const [progress, setProgress] = useState(0);
  const [on, setOn] = useState(false);
  const [pending, setPending] = useState<Pending | null>(null);
  const timers = useRef<number[]>([]);
  const busyButtons = useRef(new Set<HTMLElement>());
  const actions = useRef(0);

  const clearTimers = useCallback(() => { for (const t of timers.current) window.clearTimeout(t); timers.current = []; }, []);
  const finish = useCallback(() => {
    clearTimers();
    setPending(null);
    setProgress((p) => (p > 0 ? 1 : 0));
    timers.current.push(window.setTimeout(() => { setOn(false); setProgress(0); }, 250));
  }, [clearTimers]);

  // a page arrived (the address changed): done
  useEffect(() => { const t = window.setTimeout(finish, 0); return () => window.clearTimeout(t); }, [pathname, finish]);

  useEffect(() => {
    // the address when the last navigation started (a write of another address ends it)
    let at = location.href;
    const start = (url: URL | null) => {
      clearTimers();
      at = location.href;
      setOn(true);
      setProgress(0.12);
      // the bar creeps on while the page is on its way, never quite to the end
      let p = 0.12;
      const creep = () => { p = Math.min(0.9, p + (0.9 - p) * 0.18); setProgress(p); timers.current.push(window.setTimeout(creep, 400)); };
      timers.current.push(window.setTimeout(creep, 200));
      if (url && (url.pathname !== location.pathname)) {
        timers.current.push(window.setTimeout(() => {
          const slot = SLOTS.map((s) => document.querySelector(s)).find(Boolean) ?? null;
          setPending({ shape: shapeFor(url.pathname), slot });
        }, SKELETON_AFTER_MS));
      }
      timers.current.push(window.setTimeout(() => finish(), GIVE_UP_MS));
    };

    const onClick = (e: MouseEvent) => {
      if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
      const a = (e.target as Element | null)?.closest?.('a[href]') as HTMLAnchorElement | null;
      if (!a) return;
      const url = internalTarget(a);
      if (!url) return;
      const same = url.pathname === location.pathname && url.search === location.search;
      if (same) return;
      // next/link stops the browser's own navigation (defaultPrevented) and loads the page in place: the skeleton then
      // stands in for it. A plain link loads a new document: the bar alone (the browser keeps the old page meanwhile).
      if (e.defaultPrevented) start(url);
      else start(null);
    };

    // a GET form (search, filters) is a navigation too: the bar only, the page keeps its shape
    // a form sent to a server action (React sets its action to a javascript: URL): its button is busy until it answers
    const onSubmit = (e: SubmitEvent) => {
      const form = e.target as HTMLFormElement | null;
      if (!form || form.tagName !== 'FORM') return;
      const submitter = (e.submitter as HTMLElement | null) ?? form.querySelector<HTMLElement>('button[type="submit"], button:not([type])');
      const action = submitter?.getAttribute('formaction') ?? form.getAttribute('action') ?? '';
      // a server action form carries React's hidden $ACTION_ fields (rendered on the server) or a javascript: action
      const serverAction = /^javascript:/i.test(action) || !!form.querySelector('input[name^="$ACTION_"]');
      if (serverAction) {
        if (!submitter || submitter.hasAttribute('aria-busy')) return;
        submitter.setAttribute('aria-busy', 'true');
        submitter.setAttribute('data-bl-busy', '');
        busyButtons.current.add(submitter);
        // when no server action has started within a moment the form did not send (the page checked it): not busy
        window.setTimeout(() => { if (actions.current === 0) release(); }, 1200);
        window.setTimeout(release, 30_000);
        return;
      }
      if (!e.defaultPrevented && (form.method || 'get').toLowerCase() === 'get') start(null);
    };
    const release = () => {
      for (const b of busyButtons.current) { b.removeAttribute('data-bl-busy'); if (b.getAttribute('aria-busy') === 'true') b.removeAttribute('aria-busy'); }
      busyButtons.current.clear();
    };

    // server actions are fetches with a Next-Action header: counted, so a busy button is released when the last one answers
    const realFetch = window.fetch;
    const isAction = (init?: RequestInit) => {
      const h = init?.headers;
      if (!h) return false;
      if (h instanceof Headers) return h.has('next-action');
      if (Array.isArray(h)) return h.some(([k]) => k.toLowerCase() === 'next-action');
      return Object.keys(h).some((k) => k.toLowerCase() === 'next-action');
    };
    const wrapped: typeof fetch = (input, init) => {
      if (!isAction(init)) return realFetch(input, init);
      actions.current += 1;
      const done = () => { actions.current = Math.max(0, actions.current - 1); if (actions.current === 0) window.setTimeout(() => { if (actions.current === 0) release(); }, 60); };
      return realFetch(input, init).then((r) => { done(); return r; }, (err) => { done(); throw err; });
    };
    window.fetch = wrapped;

    // a navigation that only changes the search part (a filter, a tab, a page of results) keeps the address's path: done
    // when the router writes the new address
    const realPush = history.pushState, realReplace = history.replaceState;
    const wrote = () => { if (location.href !== at) { at = location.href; finish(); } };
    history.pushState = function (...args: Parameters<History['pushState']>) { realPush.apply(this, args); wrote(); };
    history.replaceState = function (...args: Parameters<History['replaceState']>) { realReplace.apply(this, args); wrote(); };
    // Back and Forward come from the router's cache in place: nothing to show, only the address to follow
    const onPop = () => { at = location.href; };
    // the browser restored this page from its cache (Back after a full page load): nothing is pending any more
    const onShow = () => { finish(); release(); };
    window.addEventListener('click', onClick);
    window.addEventListener('submit', onSubmit);
    window.addEventListener('popstate', onPop);
    window.addEventListener('pageshow', onShow);
    return () => {
      window.removeEventListener('click', onClick);
      window.removeEventListener('submit', onSubmit);
      window.removeEventListener('popstate', onPop);
      window.removeEventListener('pageshow', onShow);
      if (window.fetch === wrapped) window.fetch = realFetch;
      history.pushState = realPush; history.replaceState = realReplace;
      clearTimers();
      release();
    };
  }, [finish, clearTimers]);

  // the skeleton takes the page area's place: the old page is hidden (not removed) while the new one is on its way
  useEffect(() => {
    const slot = pending?.slot;
    if (!slot) return;
    slot.setAttribute('data-nav-pending', '');
    window.scrollTo({ top: 0 });
    return () => slot.removeAttribute('data-nav-pending');
  }, [pending]);

  return (
    <>
      <div className="bl-bar" data-on={on ? '' : undefined} aria-hidden="true" data-testid="route-progress">
        <div className="bl-bar__fill" style={{ ['--bl-p' as string]: String(progress) }} />
      </div>
      {pending?.slot && pending.shape ? createPortal(<div className="nav-skel"><PageSkeleton shape={pending.shape} /></div>, pending.slot) : null}
    </>
  );
}
