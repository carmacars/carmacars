'use client';
import { useEffect, useRef } from 'react';
import { publicRead } from '@/lib/browser-rpc';
import { publicEnv } from '@/lib/public-env';
import { createLiveHub, type LiveHub } from './hub';
import { createSocket, OFF_KEY, realtimeOff, socketUrl, type WsLike } from './socket';

// Live updates (hub.ts): one hub per tab, shared by every screen part that watches topics.
let hub: LiveHub | null = null;

const session = (): Storage | null => { try { return window.sessionStorage; } catch { return null; } };

function theHub(): LiveHub {
  if (hub) return hub;
  const url = publicEnv.dataBackend === 'supabase' ? socketUrl(publicEnv.supabaseUrl, publicEnv.supabaseAnonKey) : null;
  const h = createLiveHub({
    poll: (topics) => publicRead<Record<string, string | null>>('live_poll', { p_topics: topics }),
    visible: () => document.visibilityState === 'visible',
    socket: url && typeof WebSocket !== 'undefined' && !realtimeOff(session(), Date.now())
      ? (onBump, onJoined) => createSocket({ url, ws: (u) => new WebSocket(u) as unknown as WsLike, onBump, onJoined,
          giveUp: () => { try { session()?.setItem(OFF_KEY, String(Date.now())); } catch { /* private mode */ } } })
      : undefined
  });
  document.addEventListener('visibilitychange', () => h.visibility());
  hub = h;
  return h;
}

/** Runs `onChange` (at most once per burst of changes) whenever one of the topics changes. Topics are the server's
 *  tokens (server/live.ts); an empty list watches nothing. */
export function useLive(topics: readonly (string | null | undefined)[], onChange: () => void): void {
  const cb = useRef(onChange);
  useEffect(() => { cb.current = onChange; }, [onChange]);
  const key = topics.filter(Boolean).sort().join(',');
  useEffect(() => {
    if (!key) return;
    return theHub().subscribe(key.split(','), () => cb.current());
  }, [key]);
}
