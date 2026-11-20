'use client';
import { useCallback, useEffect, useState } from 'react';
import { pushStateFor, subscribePush, unsubscribePush } from '@/server/actions/push';
import { call, has, haptic, platform } from '@/lib/native/bridge';
import { deviceLabel, supportOf, type PushRole, type PushState, type Support } from './topics';

// This browser and alerts (migration 0300): can it show them, is it on, and turning it on or off. The service worker
// (public/push-sw.js) is registered only when a person turns alerts on; it shows alerts and caches nothing.
// In the store app (migration 0390, native = true) the same card uses the phone's own alerts instead: Firebase Cloud
// Messaging (@capacitor-firebase/messaging) asks the permission and gives a token, kept as the device 'fcm:<token>'.
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

// ---------------------------------------------------------------- the store app (0390)
const FCM = 'FirebaseMessaging';
type Receive = 'granted' | 'denied' | 'prompt' | 'prompt-with-rationale';
async function appToken(): Promise<string | null> {
  try { return (await call<{ token?: string }>(FCM, 'getToken')).token || null; } catch { return null; }
}
/** This phone's alerts in the app: unsupported (an app without the plugin), blocked, ready or granted with its token. */
async function appSupport(): Promise<{ support: Support; granted: boolean }> {
  if (!has(FCM)) return { support: 'unsupported', granted: false };
  try {
    const p = (await call<{ receive: Receive }>(FCM, 'checkPermissions')).receive;
    return p === 'denied' ? { support: 'blocked', granted: false } : { support: 'ready', granted: p === 'granted' };
  } catch { return { support: 'unsupported', granted: false }; }
}
export function appDeviceLabel(): string {
  return platform() === 'ios' ? 'CarmaCars app on iPhone' : platform() === 'android' ? 'CarmaCars app on Android' : 'CarmaCars app';
}
/** Sends the app's current token when alerts were on and Firebase replaced it (the shell's tokenReceived). */
export async function refreshAppToken(token: string, portal?: PushRole): Promise<void> {
  const last = store.get();
  if (!last?.startsWith('fcm:') || last === `fcm:${token}`) return;
  const p = platform();
  const r = await subscribePush({ kind: 'fcm', token, platform: p ?? 'android', portal, device: appDeviceLabel() });
  if (r.ok) store.set(`fcm:${token}`);
}

export function usePushDevice(publicKey: string | null, portal: PushRole, initial?: PushState | null, opts: { readState?: boolean; native?: boolean } = {}) {
  const [status, setStatus] = useState<DeviceStatus>('loading');
  const [state, setState] = useState<PushState | null>(initial ?? null);
  const [endpoint, setEndpoint] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const readState = opts.readState !== false;
  const native = opts.native === true;

  const send = useCallback(async (sub: PushSubscription, auto = false) => {
    const j = sub.toJSON();
    const r = await subscribePush({ endpoint: sub.endpoint, p256dh: j.keys?.p256dh ?? '', auth: j.keys?.auth ?? '', portal, device: deviceLabel(navigator.userAgent), ...(auto ? { auto: true } : {}) });
    if (!r.ok) throw new Error(r.message);
    setState(r.data);
    // r48 CM: a device its person turned off stays off (the server refuses the browser's own re-subscribe)
    if (r.data.auto_refused || !r.data.this_device) { setStatus('ready'); return; }
    store.set(sub.endpoint);
    setEndpoint(sub.endpoint); setStatus('on');
  }, [portal]);

  const appSend = useCallback(async (token: string) => {
    const r = await subscribePush({ kind: 'fcm', token, platform: platform() ?? 'android', portal, device: appDeviceLabel() });
    if (!r.ok) throw new Error(r.message);
    const ep = `fcm:${token}`;
    store.set(ep);
    setState(r.data); setEndpoint(ep); setStatus('on');
  }, [portal]);

  useEffect(() => {
    if (!native) return;
    let live = true;
    (async () => {
      const { support, granted } = await appSupport();
      if (!live) return;
      if (support !== 'ready' || !granted) { setStatus(support); return; }
      const token = await appToken();
      if (!token) { if (live) setStatus('ready'); return; }
      const ep = `fcm:${token}`;
      if (!readState) { if (live) { setEndpoint(ep); setStatus(store.get() === ep ? 'on' : 'ready'); } return; }
      const r = await pushStateFor(ep);
      if (!live) return;
      if (r.ok && r.data.this_device) { setState(r.data); setEndpoint(ep); setStatus('on'); return; }
      // Firebase replaced the token since alerts were turned on here: send the new one
      const last = store.get();
      if (last?.startsWith('fcm:') && last !== ep) { await appSend(token).catch(() => setStatus('ready')); return; }
      if (r.ok) setState(r.data);
      setStatus('ready');
    })();
    return () => { live = false; };
  }, [native, readState, appSend]);

  useEffect(() => {
    if (native) return;
    let live = true;
    (async () => {
      const support = browserSupport();
      if (support !== 'ready') {
        if (support === 'blocked') { const r = await pushStateFor(null).catch(() => null); if (live && r?.ok) setState(r.data); }
        if (live) setStatus(support);
        return;
      }
      let sub = await currentSubscription().catch(() => null);
      if (!sub || Notification.permission !== 'granted') {
        // r48 CM: alerts stopped on this device without the person turning them off (the push service dropped it, or the
        // permission was reset): the card and the prompt say so (state.lost) and ask for the permission again
        const r = await pushStateFor(null).catch(() => null);
        if (live && r?.ok) setState(r.data);
        if (live) setStatus('ready');
        return;
      }
      // r48 CM: alerts stay on unless the person turns them off. A subscription made with old keys is replaced with the
      // current ones (the permission is already granted: no prompt), and a device the server dropped (expired, refused,
      // another person signed in on it, more than 10 devices) is sent again by itself, on every portal page that has the
      // card or the prompt; only the person's own Turn off keeps it off.
      if (publicKey && !sameKey(sub.options.applicationServerKey, keyBytes(publicKey))) {
        await sub.unsubscribe().catch(() => undefined);
        const reg = await navigator.serviceWorker.getRegistration('/');
        sub = (await reg?.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: keyBytes(publicKey) }).catch(() => null)) ?? null;
        if (!sub) { if (live) setStatus('ready'); return; }
        if (live) await send(sub, true).catch(() => setStatus('ready'));
        return;
      }
      const r = await pushStateFor(sub.endpoint);
      if (!live) return;
      if (r.ok && r.data.this_device) { setState(r.data); setEndpoint(sub.endpoint); setStatus('on'); return; }
      if (r.ok && r.data.turned_off_here) { setState(r.data); setStatus('ready'); return; }
      await send(sub, true).catch(() => setStatus('ready'));
    })();
    return () => { live = false; };
  }, [native, readState, send, publicKey]);

  const turnOn = useCallback(async () => {
    setBusy(true); setError(null);
    if (native) {
      try {
        const p = (await call<{ receive: Receive }>(FCM, 'requestPermissions')).receive;
        if (p !== 'granted') { setStatus(p === 'denied' ? 'blocked' : 'ready'); return false; }
        // Android: the alerts channel (high importance: a banner and the sound); iOS has none
        if (platform() === 'android') await call(FCM, 'createChannel', { id: 'alerts', name: 'CarmaCars alerts', description: 'Bookings, payments, pickups and messages', importance: 4, visibility: 1, vibration: true }).catch(() => undefined);
        const token = await appToken();
        if (!token) throw new Error('The phone did not give a push address. Check the connection and try again.');
        await appSend(token);
        haptic('success');
        return true;
      } catch (e) {
        setError(e instanceof Error && e.message ? e.message : 'The app could not turn alerts on. Try again.');
        return false;
      } finally { setBusy(false); }
    }
    if (!publicKey) { setBusy(false); setStatus('unsupported'); return false; }
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
  }, [native, publicKey, send, appSend]);

  const turnOff = useCallback(async () => {
    setBusy(true); setError(null);
    if (native) {
      try {
        const ep = endpoint ?? store.get();
        await call(FCM, 'deleteToken').catch(() => undefined);
        store.set(null);
        if (ep) { const r = await unsubscribePush({ endpoint: ep }); if (r.ok) setState(r.data); }
        setEndpoint(null); setStatus('ready');
      } finally { setBusy(false); }
      return;
    }
    try {
      const sub = await currentSubscription().catch(() => null);
      const ep = sub?.endpoint ?? endpoint;
      await sub?.unsubscribe().catch(() => undefined);
      store.set(null);
      if (ep) { const r = await unsubscribePush({ endpoint: ep }); if (r.ok) setState(r.data); }
      setEndpoint(null); setStatus('ready');
    } finally { setBusy(false); }
  }, [native, endpoint]);

  const removeDevice = useCallback(async (id: string) => {
    setBusy(true); setError(null);
    try { const r = await unsubscribePush({ id }); if (r.ok) setState(r.data); else setError(r.message); } finally { setBusy(false); }
  }, []);

  return { status, state, setState, endpoint, busy, error, setError, turnOn, turnOff, removeDevice };
}
