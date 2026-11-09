'use client';
import { useEffect, useRef } from 'react';
import { playMoment, pulseToast, type MomentKind } from './moment';

/** r35 S2: plays a moment once when the page shows (a server page: the request sent, the booking confirmed). */
export function Moment({ kind }: { kind: MomentKind }) {
  const done = useRef(false);
  useEffect(() => { if (!done.current) { done.current = true; playMoment(kind); } }, [kind]);
  return null;
}

type Latest = { latest: { id: string; title: string; url: string | null; kind: 'request' | 'offer' | 'other' } | null };
/** r35 S2: Admin and staff: a new request or an accepted offer while the page is open: a toast with a pulse. Reads the
 *  person's newest unread alert every 30 seconds while the tab is visible (one small read); the first read is the start. */
export function AlertPulse() {
  const seen = useRef<string | null | undefined>(undefined);
  useEffect(() => {
    let live = true;
    const read = async () => {
      if (document.visibilityState !== 'visible') return;
      const r = await fetch('/api/alerts/latest', { cache: 'no-store' }).then((x) => (x.ok ? (x.json() as Promise<Latest>) : null)).catch(() => null);
      if (!live || !r) return;
      const l = r.latest;
      if (seen.current !== undefined && l && l.id !== seen.current && l.kind !== 'other') {
        pulseToast(l.title, l.url);
        if (l.kind === 'offer') playMoment('offer');
      }
      seen.current = l?.id ?? null;
    };
    void read();
    const t = setInterval(() => void read(), 30_000);
    return () => { live = false; clearInterval(t); };
  }, []);
  return null;
}
