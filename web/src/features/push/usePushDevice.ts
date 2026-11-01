'use client';
import { useCallback, useEffect, useState } from 'react';
import { pushStateFor, subscribePush, unsubscribePush } from '@/server/actions/push';
import { deviceLabel, supportOf, type PushRole, type PushState, type Support } from './topics';

// This browser and alerts (migration 0300): can it show them, is it on, and turning it on or off. The service worker
// (public/push-sw.js) is registered only when a person turns alerts on; it shows alerts and caches nothing.
const LAST = 'cc-push-endpoint';
const store = {
  get: () => { try { return localStorage.getItem(LAST); } catch { return null; } },
  set: (v: string | null) => { try { if (v) localStorage.setItem(LAST, v); else localStorage.removeItem(LAST); } catch { /* private mode */ } }
};

function keyBytes(b64: string): Uint8Array<ArrayBuffer> {
  const t = b64.replace(/-/g, '+').replace(/_/g, '/');
  const bin = atob(t + '='.repeat((4 - (t.length % 4)) % 4));
  const out = new Uint8Array(new ArrayBuffer(bin.length));
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
function sameKey(a: ArrayBuffer | null | undefined, b: Uint8Array): boolean {
  if (!a) return false;
  const x = new Uint8Array(a);
  return x.length === b.length && x.every((v, i) => v === b[i]);
}

export function browserSupport(): Support {
  const n = navigator as Navigator & { standalone?: boolean };
  const standalone = window.matchMedia?.('(display-mode: standalone)').matches || n.standalone === true;
  const hasPush = 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;
  return supportOf({ ua: navigator.userAgent, maxTouchPoints: navigator.maxTouchPoints, standalone, hasPush, permission: 'Notification' in window ? Notification.permission : 'none' });
}

async function currentSubscription(): Promise<PushSubscription | null> {
  if (!('serviceWorker' in navigator)) return null;
  const reg = await navigator.serviceWorker.getRegistration('/');
  return (await reg?.pushManager.getSubscription()) ?? null;
}

export type DeviceStatus = 'loading' | Support | 'on';

export function usePushDevice(publicKey: string, portal: PushRole, initial?: PushState | null, opts: { readState?: boolean } = {}) {
  const [status, setStatus] = useState<DeviceStatus>('loading');
  const [state, setState] = useState<PushState | null>(initial ?? null);
  const [endpoint, setEndpoint] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const readState = opts.readState !== false;

  const send = useCallback(async (sub: PushSubscription) => {
    const j = sub.toJSON();
    const r = await subscribePush({ endpoint: sub.endpoint, p256dh: j.keys?.p256dh ?? '', auth: j.keys?.auth ?? '', portal, device: deviceLabel(navigator.userAgent) });
    if (!r.ok) throw new Error(r.message);
    store.set(sub.endpoint);
    setState(r.data); setEndpoint(sub.endpoint); setStatus('on');
  }, [portal]);

  useEffect(() => {
    let live = true;
    (async () => {
      const support = browserSupport();
      if (support !== 'ready') { if (live) setStatus(support); return; }
      const sub = await currentSubscription().catch(() => null);
      if (!sub || Notification.permission !== 'granted') { if (live) setStatus('ready'); return; }
      if (!readState) { if (live) { setEndpoint(sub.endpoint); setStatus('on'); } return; }
      const r = await pushStateFor(sub.endpoint);
      if (!live) return;
      if (r.ok && r.data.this_device) { setState(r.data); setEndpoint(sub.endpoint); setStatus('on'); return; }
      // the browser replaced its push address since (push-sw.js pushsubscriptionchange): send the new one. A device
      // removed from the list on another device stays off until the person turns it on here.
      const last = store.get();
      if (last && last !== sub.endpoint) { await send(sub).catch(() => setStatus('ready')); return; }
      if (r.ok) setState(r.data);
      setStatus('ready');
    })();
    return () => { live = false; };
  }, [readState, send]);

  const turnOn = useCallback(async () => {
    setBusy(true); setError(null);
    try {
      const permission = await Notification.requestPermission();
      if (permission !== 'granted') { setStatus(permission === 'denied' ? 'blocked' : 'ready'); return false; }
      const reg = await navigator.serviceWorker.register('/push-sw.js', { scope: '/' });
      await navigator.serviceWorker.ready;
      const key = keyBytes(publicKey);
      let sub = await reg.pushManager.getSubscription();
      // made with another key (the keys were changed): start again with the current one
      if (sub && !sameKey(sub.options.applicationServerKey, key)) { await sub.unsubscribe().catch(() => undefined); sub = null; }
      sub ??= await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: key });
      await send(sub);
      return true;
    } catch (e) {
      setError(e instanceof Error && e.message && !/^[A-Z][a-z]+Error/.test(e.name) ? e.message : 'This browser could not turn alerts on. Try again, or use another browser.');
      return false;
    } finally { setBusy(false); }
  }, [publicKey, send]);

  const turnOff = useCallback(async () => {
    setBusy(true); setError(null);
    try {
      const sub = await currentSubscription().catch(() => null);
      const ep = sub?.endpoint ?? endpoint;
      await sub?.unsubscribe().catch(() => undefined);
      store.set(null);
      if (ep) { const r = await unsubscribePush({ endpoint: ep }); if (r.ok) setState(r.data); }
      setEndpoint(null); setStatus('ready');
    } finally { setBusy(false); }
  }, [endpoint]);

  const removeDevice = useCallback(async (id: string) => {
    setBusy(true); setError(null);
    try { const r = await unsubscribePush({ id }); if (r.ok) setState(r.data); else setError(r.message); } finally { setBusy(false); }
  }, []);

  return { status, state, setState, endpoint, busy, error, setError, turnOn, turnOff, removeDevice };
}
