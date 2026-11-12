'use client';
import { useCallback, useEffect, useRef } from 'react';
import { usePathname, useRouter } from 'next/navigation';
import { useLive } from './useLive';
import { REFRESH_GAP_MS, topicsFor, TYPING_WAIT_MS, typingIn, type LiveArea } from './areas';

// Live updates (hub.ts): a change to a watched topic reads the screen again (router.refresh: the server parts render
// anew, the client parts keep their state, so what is typed in a form stays). While someone types, the refresh waits for
// the field to lose focus (at most 8 seconds); refreshes close together run once, and the last one is never dropped.
function useRefresher(): () => void {
  const router = useRouter();
  const last = useRef(0);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const run = useCallback(() => {
    if (timer.current) { clearTimeout(timer.current); timer.current = null; }
    last.current = Date.now();
    router.refresh();
    window.dispatchEvent(new Event('cc-live'));
  }, [router]);
  useEffect(() => () => { if (timer.current) clearTimeout(timer.current); }, []);
  return useCallback(() => {
    if (timer.current) return; // a refresh is already on its way
    const typing = typingIn(document.activeElement as HTMLElement | null);
    const wait = Math.max(0, last.current + REFRESH_GAP_MS - Date.now());
    if (!typing) { if (wait) timer.current = setTimeout(run, wait); else run(); return; }
    const el = document.activeElement;
    const go = () => { el?.removeEventListener('blur', go); run(); };
    el?.addEventListener('blur', go, { once: true });
    timer.current = setTimeout(go, Math.max(wait, TYPING_WAIT_MS));
  }, [run]);
}

/** Refreshes the screen when one of the topics changes (a booking's page: LiveBooking's topic). */
export function LiveRefresh({ topics }: { topics: readonly (string | null | undefined)[] }) {
  const refresh = useRefresher();
  useLive(topics, refresh);
  return null;
}

/** The portal frame's live updates: the areas of the screen shown (areas.ts), from the tokens the server gave. */
export function LivePortal({ tokens }: { tokens: Partial<Record<LiveArea, string>> }) {
  const path = usePathname() ?? '';
  const refresh = useRefresher();
  useLive(topicsFor(path, tokens), refresh);
  return null;
}
