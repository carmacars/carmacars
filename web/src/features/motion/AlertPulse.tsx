'use client';
import { useCallback, useEffect, useRef } from 'react';
import { useLive } from '@/features/live/realtime/useLive';
import { playMoment, pulseToast } from './moment';

type Latest = { latest: { id: string; title: string; url: string | null; kind: 'request' | 'offer' | 'other' } | null };
/** r35 S2: Admin and staff: a new request or an accepted offer while the page is open: a toast with a pulse. Reads the
 *  person's newest unread alert while the tab is visible (one small read); the first read is the start. r41: with the
 *  person's live topic (server/live.ts), it reads when an alert arrives (within about 2 seconds) and every 5 minutes as a
 *  safety net; without one, every 30 seconds as before. */
export function AlertPulse({ topic }: { topic?: string | null }) {
  const seen = useRef<string | null | undefined>(undefined);
  const readRef = useRef<() => void>(() => {});
  useLive(topic ? [topic] : [], useCallback(() => readRef.current(), []));
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
    readRef.current = () => void read();
    void read();
    const t = setInterval(() => void read(), topic ? 300_000 : 30_000);
    return () => { live = false; clearInterval(t); };
  }, [topic]);
  return null;
}
