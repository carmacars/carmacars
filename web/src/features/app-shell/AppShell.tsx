'use client';
import '@/styles/app-shell.css';
import { useCallback, useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { signOut } from '@/server/actions/auth';
import { authenticate, biometry, call, haptic, listen, prefGet, prefSet } from '@/lib/native/bridge';
import { appPathOf } from '@/lib/native/shell';
import { cameraOptions, cancelled, factsOf, photoFile, photoModeFor } from '@/lib/native/camera';
import { refreshAppToken } from '@/features/push/usePushDevice';
import { UNLOCK_KEY, UNLOCK_AFTER_MS, lockDue } from './unlock';
import { BrandMark } from '@/components/BrandMark';

// The store app's layer over the site (migration 0390), loaded only inside the CarmaCars app (AppShellMount):
//   - the splash screen goes once the first page has painted, and the status bar is light on black;
//   - deep links (universal links and app links from emails and texts) and a tapped alert open their page here;
//   - a tap on a photo field opens the phone's camera (lib/native/camera.ts), with a short haptic when the photo is in;
//   - Face ID or fingerprint unlock, when the person turned it on (Profile, App settings): asked when the app opens and
//     when it comes back after 5 minutes; the screen is veiled in the app switcher;
//   - a bar when the phone loses its connection (a page that cannot load shows the app's own offline screen);
//   - an alert that arrives while the app is open shows as a banner here (Android shows none by itself in front).

type Toast = { title: string; body: string; url: string | null };

function go(path: string) {
  if (path === location.pathname + location.search + location.hash) return;
  // a full navigation: sign-in links (/auth/callback) must reach the server
  location.assign(path);
}

export default function AppShell() {
  const router = useRouter();
  const [lock, setLock] = useState<'off' | 'veil' | 'ask'>('off');
  const [label, setLabel] = useState('Face ID');
  const [offline, setOffline] = useState(false);
  const [toast, setToast] = useState<Toast | null>(null);
  const awayAt = useRef<number | null>(null);
  const enabled = useRef(false);
  const unlockBtn = useRef<HTMLButtonElement | null>(null);

  const unlock = useCallback(async () => {
    const ok = await authenticate('Unlock CarmaCars');
    if (ok) { setLock('off'); haptic('success'); } else setLock('ask');
  }, []);

  // ---- once: splash, status bar, unlock, links, alerts, connection
  useEffect(() => {
    const stops: Array<() => void> = [];
    void call('SplashScreen', 'hide', { fadeOutDuration: 200 }).catch(() => undefined);
    void call('StatusBar', 'setStyle', { style: 'DARK' }).catch(() => undefined);

    (async () => {
      enabled.current = (await prefGet(UNLOCK_KEY)) === '1';
      if (!enabled.current) return;
      const b = await biometry();
      if (!b) { enabled.current = false; return; }
      setLabel(b.label);
      setLock('ask');
      void unlock();
    })();

    stops.push(listen<{ url?: string }>('App', 'appUrlOpen', (e) => { const p = appPathOf(e?.url); if (p) go(p); }));
    stops.push(listen<{ isActive?: boolean }>('App', 'appStateChange', (e) => {
      if (!enabled.current) return;
      if (!e?.isActive) { awayAt.current = Date.now(); setLock((l) => (l === 'off' ? 'veil' : l)); return; }
      if (lockDue(awayAt.current, Date.now(), UNLOCK_AFTER_MS)) { setLock('ask'); void unlock(); } else setLock((l) => (l === 'veil' ? 'off' : l));
      awayAt.current = null;
    }));
    stops.push(listen<{ notification?: { data?: { url?: string } } }>('FirebaseMessaging', 'notificationActionPerformed', (e) => {
      const p = appPathOf(e?.notification?.data?.url ?? null);
      if (p) go(p);
    }));
    stops.push(listen<{ notification?: { title?: string; body?: string; data?: { url?: string } } }>('FirebaseMessaging', 'notificationReceived', (e) => {
      const n = e?.notification;
      if (!n?.title) return;
      haptic('light');
      setToast({ title: n.title, body: n.body ?? '', url: appPathOf(n.data?.url ?? null) });
      router.refresh();
    }));
    stops.push(listen<{ token?: string }>('FirebaseMessaging', 'tokenReceived', (e) => { if (e?.token) void refreshAppToken(e.token); }));
    void call<{ connected: boolean }>('Network', 'getStatus').then((s) => setOffline(s.connected === false)).catch(() => undefined);
    stops.push(listen<{ connected?: boolean }>('Network', 'networkStatusChange', (s) => {
      setOffline(s?.connected === false);
      if (s?.connected) router.refresh();
    }));
    return () => { for (const s of stops) s(); };
  }, [router, unlock]);

  // ---- photo fields: the phone's camera
  useEffect(() => {
    const onClick = (ev: MouseEvent) => {
      const el = ev.target instanceof HTMLInputElement ? ev.target : null;
      if (!el) return;
      const mode = photoModeFor(factsOf(el));
      if (!mode) return;
      ev.preventDefault();
      call<{ base64String?: string; format?: string }>('Camera', 'getPhoto', cameraOptions(mode)).then((photo) => {
        if (!photo?.base64String) return;
        const dt = new DataTransfer();
        dt.items.add(photoFile(photo.base64String, photo.format));
        el.files = dt.files;
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        haptic('success');
      }).catch((e) => {
        if (cancelled(e)) return;
        // no camera permission or an older app: the WebView's own chooser
        el.dataset.nativeCamera = 'off';
        el.click();
        delete el.dataset.nativeCamera;
      });
    };
    document.addEventListener('click', onClick, true);
    return () => document.removeEventListener('click', onClick, true);
  }, []);

  // ---- while locked, the page behind is out of reach
  useEffect(() => {
    if (lock === 'off') return;
    const others = [...document.body.children].filter((n) => !n.hasAttribute('data-app-lock')) as HTMLElement[];
    for (const n of others) n.inert = true;
    if (lock === 'ask') unlockBtn.current?.focus();
    return () => { for (const n of others) n.inert = false; };
  }, [lock]);

  useEffect(() => {
    if (!toast) return;
    const t = setTimeout(() => setToast(null), 8000);
    return () => clearTimeout(t);
  }, [toast]);

  return (
    <>
      {offline && <div className="as-offline" role="status" data-testid="app-offline">No connection. You are seeing the last page that loaded.</div>}
      {toast && (
        <div className="as-toast" role="status" data-testid="app-toast">
          <p className="as-toast__title">{toast.title}</p>
          {toast.body && <p className="as-toast__body">{toast.body}</p>}
          <div className="as-toast__actions">
            {toast.url && <button type="button" className="btn btn--primary btn--sm" onClick={() => { const u = toast.url!; setToast(null); go(u); }}>Open</button>}
            <button type="button" className="btn btn--quiet btn--sm as-toast__close" onClick={() => setToast(null)}>Close</button>
          </div>
        </div>
      )}
      {lock !== 'off' && (
        <div className={`as-lock${lock === 'veil' ? ' as-lock--veil' : ''}`} data-app-lock role="dialog" aria-modal="true" aria-labelledby="as-lock-t" data-testid="app-lock">
          <div className="as-lock__in">
            <div className="as-lock__mark" aria-hidden="true"><BrandMark size={72} /></div>
            <div className="as-lock__rule" aria-hidden="true" />
            <h1 className="as-lock__title" id="as-lock-t">CarmaCars is locked</h1>
            <p className="as-lock__text">Use {label} to open your account.</p>
            <button ref={unlockBtn} type="button" className="btn btn--primary" onClick={() => void unlock()} data-testid="app-unlock">Unlock with {label}</button>
            <form action={async () => { await prefSet(UNLOCK_KEY, null); await signOut(); }}>
              <button type="submit" className="as-lock__out">Sign out instead</button>
            </form>
          </div>
        </div>
      )}
    </>
  );
}
