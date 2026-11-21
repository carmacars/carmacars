'use client';
import { call, has, inApp, watch } from '@/lib/native/bridge';
import { goodFix, REPORT_MS, STATE_MS, type MyLocation } from '@/features/live-map/people';

// Sharing one's own location with the live map (migration 3350, release 48 part MAP). In the store app: the
// BackgroundGeolocation plugin (apps/carmacars, @capacitor-community/background-geolocation), which keeps reporting with the
// app in the background and shows the phone's own notice while it does; in a browser: the page's geolocation, only once
// the person allowed it (we never ask from here, only from the settings card's button). The database decides on every
// report whether it is kept: staff on shift or on a job after the policy, renters and owners around a pickup or return.

const BG = 'BackgroundGeolocation';
export interface Fix { lat: number; lng: number; accuracy: number | null; at: number }
type Stop = () => void;

export async function readState(): Promise<MyLocation | null> {
  try {
    const r = await fetch('/api/me/location', { cache: 'no-store', credentials: 'same-origin' });
    const j = (await r.json()) as { ok: boolean; data?: MyLocation };
    return r.ok && j.ok ? j.data ?? null : null;
  } catch { return null; }
}

export async function act(action: 'report' | 'prefs' | 'policy', body: Record<string, unknown>): Promise<{ ok: true; data: MyLocation & { stored?: boolean } } | { ok: false; message: string }> {
  try {
    const r = await fetch('/api/me/location', { method: 'POST', credentials: 'same-origin', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ action, ...body }) });
    const j = (await r.json()) as { ok: boolean; data?: MyLocation; message?: string };
    return r.ok && j.ok ? { ok: true, data: j.data as MyLocation } : { ok: false, message: j.message ?? 'That did not work. Try again.' };
  } catch { return { ok: false, message: 'No connection. Try again.' }; }
}

/** Whether this device already allows the location: 'granted', 'prompt', 'denied' or 'unknown' (the browser cannot say). */
export async function permission(): Promise<'granted' | 'prompt' | 'denied' | 'unknown'> {
  if (inApp() && has(BG)) return 'unknown';
  try {
    const p = await (navigator as Navigator & { permissions?: { query(d: { name: string }): Promise<{ state: string }> } }).permissions?.query({ name: 'geolocation' });
    return p?.state === 'granted' || p?.state === 'prompt' || p?.state === 'denied' ? p.state : 'unknown';
  } catch { return 'unknown'; }
}

/** Starts watching; `ask` lets the phone or the browser show its permission question. Returns the stop, or null. */
export function startWatch(onFix: (f: Fix) => void, onError: (m: string) => void, ask: boolean): Stop | null {
  if (inApp() && has(BG)) {
    const id = watch<{ latitude: number; longitude: number; accuracy?: number; time?: number }>(BG, 'addWatcher', {
      requestPermissions: ask, stale: false, distanceFilter: 25,
      backgroundTitle: 'CarmaCars is sharing your location',
      backgroundMessage: 'Only while you are on shift or on a job, or around your pickup or return. Turn it off in Settings, Privacy.'
    }, (d, err) => {
      if (err || !d) { const code = (err as { code?: string } | undefined)?.code; onError(code === 'NOT_AUTHORIZED' ? 'Location is off for CarmaCars in the phone\'s settings.' : 'The phone could not read the location.'); return; }
      onFix({ lat: d.latitude, lng: d.longitude, accuracy: d.accuracy ?? null, at: d.time ?? Date.now() });
    });
    if (id) return () => { void call(BG, 'removeWatcher', { id }).catch(() => undefined); };
  }
  if (typeof navigator === 'undefined' || !navigator.geolocation) { onError('This browser cannot share a location.'); return null; }
  const w = navigator.geolocation.watchPosition(
    (p) => onFix({ lat: p.coords.latitude, lng: p.coords.longitude, accuracy: Number.isFinite(p.coords.accuracy) ? p.coords.accuracy : null, at: p.timestamp || Date.now() }),
    (e) => onError(e.code === 1 ? 'Location is blocked for carmacars.ca in this browser.' : 'The browser could not read the location.'),
    { enableHighAccuracy: true, maximumAge: 30_000, timeout: 30_000 }
  );
  return () => navigator.geolocation.clearWatch(w);
}

/**
 * The page's sharer: asks the database whether this person qualifies now (again every 5 minutes, and when the page comes
 * back), watches only while they do, and sends the latest good fix once a minute. Returns the stop.
 */
export function runSharer(onState?: (s: MyLocation | null) => void): Stop {
  let stop: Stop | null = null, last: Fix | null = null, sentAt = 0, dead = false;
  const source = inApp() && has(BG) ? 'app' : 'web';
  const send = async (force = false) => {
    if (!last || !goodFix(last) || (!force && Date.now() - sentAt < REPORT_MS)) return;
    sentAt = Date.now();
    const r = await act('report', { lat: last.lat, lng: last.lng, accuracy_m: last.accuracy ?? 0, at: new Date(last.at).toISOString(), source });
    // the database said no (a shift ended, a pickup window closed, turned off): stop at once
    if (r.ok && r.data.stored === false && (r.data as { why?: string }).why !== 'soon' && (r.data as { why?: string }).why !== 'stale') { stop?.(); stop = null; void check(); }
  };
  const check = async () => {
    if (dead) return;
    const s = await readState();
    onState?.(s);
    if (s?.share && !stop) {
      // in a browser only once allowed (the settings card asks); in the app the phone keeps the answer it was given
      const perm = await permission();
      if (dead || (source === 'web' && perm !== 'granted')) return;
      stop = startWatch((f) => { const fresh = !last; last = f; void send(fresh); }, () => undefined, false);
    } else if (!s?.share && stop) { stop(); stop = null; last = null; }
  };
  void check();
  const t = setInterval(() => void check(), STATE_MS);
  const tick = setInterval(() => void send(), REPORT_MS);
  const shown = () => { if (document.visibilityState === 'visible') void check(); };
  document.addEventListener('visibilitychange', shown);
  return () => { dead = true; clearInterval(t); clearInterval(tick); document.removeEventListener('visibilitychange', shown); stop?.(); };
}
