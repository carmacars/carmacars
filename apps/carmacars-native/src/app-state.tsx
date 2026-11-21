import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { AppState as PhoneState } from 'react-native';
import NetInfo from '@react-native-community/netinfo';
import { useRouter } from 'expo-router';
import { createClient, type Client, type Result } from '@/api/client';
import { STATE_MS, type AppConfig, type Me, type MobileSession, type Portal, type RouteId } from '@/shared';
import { API_URL, APP_VERSION, canLock, getFlag, openSite, PLATFORM, sessionStore, setFlag, SITE_HOSTS, unlockWithDevice } from '@/native';
import { onBackground, onForeground, onUnlocked, type LockState } from '@/logic/lock';
import { targetFor } from '@/logic/links';
import { forgetPushOnSignOut, watchPush } from '@/push';
import { setLocationClient, stopAll as stopLocation, sync as syncLocation } from '@/location';

// What every screen shares: the API client, who is signed in and what they hold, whether the server can be reached,
// and the app lock. One provider at the root (app/_layout.tsx).
interface Value {
  api: Client;
  ready: boolean;
  config: AppConfig | null;
  session: MobileSession | null;
  me: Me | null;
  /** false: the phone has no connection, or the last call did not reach the server (the offline banner) */
  online: boolean;
  locked: boolean;
  lockEnabled: boolean;
  lockAvailable: boolean;
  /** Keeps a session a sign-in route gave and loads the account. */
  signedIn(s: MobileSession): Promise<Me | null>;
  signOut(): Promise<void>;
  reloadMe(): Promise<Me | null>;
  setLockEnabled(on: boolean): Promise<boolean>;
  unlock(): Promise<void>;
  /** Opens a link to the site: a screen when the app has one, else the in-app browser. */
  open(link: string): void;
  portal: Portal;
}
const Ctx = createContext<Value | null>(null);
export const useApp = (): Value => { const v = useContext(Ctx); if (!v) throw new Error('AppProvider is missing'); return v; };

export function AppProvider({ children }: { children: ReactNode }) {
  const router = useRouter();
  const [ready, setReady] = useState(false);
  const [config, setConfig] = useState<AppConfig | null>(null);
  const [session, setSession] = useState<MobileSession | null>(null);
  const [me, setMe] = useState<Me | null>(null);
  const [connected, setConnected] = useState(true);
  const [reachable, setReachable] = useState(true);
  const [lockAvailable, setLockAvailable] = useState(false);
  const [lock, setLock] = useState<LockState>({ enabled: false, signedIn: false, locked: false, backgroundAt: null });
  const meRef = useRef<Me | null>(null);
  meRef.current = me;

  const api = useMemo(() => createClient({ baseUrl: API_URL, fetch: (...a) => fetch(...a), session: sessionStore, appVersion: APP_VERSION, platform: PLATFORM,
    onReachable: setReachable, onSignedOut: () => { setMe(null); } }), []);

  const reloadMe = useCallback(async (): Promise<Me | null> => {
    const r = await api.call('me');
    if (r.ok) { setMe(r.data); return r.data; }
    if (r.code === 'auth') setMe(null);
    return meRef.current;
  }, [api]);

  // start: the session from the keychain, the lock setting, the site's settings for the app, then the account
  useEffect(() => {
    let live = true;
    // another account, or nobody: nothing loaded for the last person stays in memory or on screen
    let who: string | null | undefined;
    const off = sessionStore.subscribe((s) => {
      if (who !== undefined && who !== (s?.user.id ?? null)) { forgetLoaded(); void stopLocation(); }
      who = s?.user.id ?? null;
      setSession(s); setLock((l) => ({ ...l, signedIn: !!s })); if (!s) setMe(null);
    });
    void (async () => {
      const [s, flag, can] = await Promise.all([sessionStore.get(), getFlag('lock'), canLock()]);
      if (!live) return;
      who = s?.user.id ?? null;
      setSession(s); setLockAvailable(can);
      setLock((l) => onForeground({ ...l, enabled: flag === '1' && can, signedIn: !!s }, Date.now(), true));
      const [c] = await Promise.all([api.call('config'), s ? reloadMe() : null]);
      if (!live) return;
      if (c.ok) setConfig(c.data);
      setReady(true);
    })();
    return () => { live = false; off(); };
  }, [api, reloadMe]);

  // the connection, and the lock when the app comes back
  useEffect(() => {
    const net = NetInfo.addEventListener((st) => { const on = st.isConnected !== false; setConnected(on); if (on) setReachable(true); });
    const sub = PhoneState.addEventListener('change', (st) => {
      if (st === 'background' || st === 'inactive') setLock((l) => onBackground(l, Date.now()));
      if (st === 'active') setLock((l) => onForeground(l, Date.now()));
    });
    return () => { net(); sub.remove(); };
  }, []);
  // the settings again once the server is reachable (a cold start with no connection)
  useEffect(() => {
    if (ready && !config && connected) void api.call('config').then((c) => { if (c.ok) setConfig(c.data); });
  }, [ready, config, connected, api]);

  const portal: Portal = me?.roles.admin ? 'admin' : me?.roles.field ? 'field' : me?.roles.staff ? 'staff' : me?.roles.owner ? 'owner' : 'renter';
  const portalRef = useRef(portal);
  portalRef.current = portal;

  const open = useCallback((link: string) => {
    const t = targetFor(link, SITE_HOSTS);
    if (!t) return;
    if (t.kind === 'screen') router.push(t.href as never);
    else void openSite(t.path, config?.site_url);
  }, [router, config?.site_url]);
  const openRef = useRef(open);
  openRef.current = open;
  useEffect(() => (session ? watchPush(api, () => portalRef.current, (u) => openRef.current(u)) : undefined), [api, !!session]); // eslint-disable-line react-hooks/exhaustive-deps
  // Location on the live map (src/location): asked again when the account loads, when the app comes back, and every 5 minutes
  const meId = me?.user.id ?? null;
  useEffect(() => {
    if (!meId) return;
    setLocationClient(api);
    void syncLocation({ prompt: true });
    const t = setInterval(() => { if (PhoneState.currentState === 'active') void syncLocation(); }, STATE_MS);
    const sub = PhoneState.addEventListener('change', (st) => { if (st === 'active') void syncLocation({ prompt: true }); });
    return () => { clearInterval(t); sub.remove(); };
  }, [api, meId]);

  const value: Value = {
    api, ready, config, session, me, online: connected && reachable, locked: lock.locked, lockEnabled: lock.enabled, lockAvailable, portal, open, reloadMe,
    async signedIn(s) { await api.adopt(s); return reloadMe(); },
    async signOut() { await stopLocation().catch(() => undefined); await forgetPushOnSignOut(api).catch(() => undefined); await api.signOut(); setMe(null); },
    async setLockEnabled(on) {
      // turning it on or off asks for the face, the finger or the passcode first
      if (!(await unlockWithDevice(on ? 'Turn on app lock' : 'Turn off app lock'))) return false;
      await setFlag('lock', on ? '1' : null);
      setLock((l) => ({ ...l, enabled: on, locked: false }));
      return true;
    },
    async unlock() { if (await unlockWithDevice()) setLock(onUnlocked); }
  };
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

// ---------------------------------------------------------------- loading a screen's data
const lastGood = new Map<string, { at: number; data: unknown }>();
export interface Loaded<T> { data: T | null; loading: boolean; error: string | null; code: string | null; reload: () => void; refreshing: boolean; /** when what is shown was loaded, if the newest try failed (offline) */ staleAt: number | null }
/** One read of the API for a screen. The last good answer stays on screen when a reload fails (no connection). */
export function useLoad<T>(key: string | null, load: () => Promise<{ ok: true; data: T } | { ok: false; code: string; message: string }>): Loaded<T> {
  type State = { key: string | null; data: T | null; loading: boolean; error: string | null; code: string | null; refreshing: boolean; staleAt: number | null };
  const fresh = (k: string | null): State => {
    const hit = k ? lastGood.get(k) : undefined;
    return { key: k, data: (hit?.data as T | undefined) ?? null, loading: !!k && !hit, error: null, code: null, refreshing: false, staleAt: null };
  };
  const [state, set] = useState<State>(() => fresh(key));
  const fn = useRef(load); fn.current = load;
  const run = useCallback((refreshing: boolean) => {
    if (!key) { set(fresh(null)); return; }
    // another read (other dates, another trip): never the last read's answer under the new question
    set((s) => (s.key === key ? { ...s, loading: s.data === null, refreshing, error: null } : fresh(key)));
    void fn.current().then((r) => {
      set((s) => {
        if (s.key !== key) return s;
        if (r.ok) { lastGood.set(key, { at: Date.now(), data: r.data }); return { key, data: r.data, loading: false, error: null, code: null, refreshing: false, staleAt: null }; }
        return { ...s, loading: false, refreshing: false, error: r.message, code: r.code, staleAt: s.data !== null ? lastGood.get(key)?.at ?? null : null };
      });
    });
  }, [key]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { run(false); }, [run]);
  // the first render after the key changed still holds the old state: show nothing of it
  const shown = state.key === key ? state : fresh(key);
  return { data: shown.data, loading: shown.loading, error: shown.error, code: shown.code, refreshing: shown.refreshing, staleAt: shown.staleAt, reload: () => run(true) };
}
export const forgetLoaded = (prefix = '') => { for (const k of [...lastGood.keys()]) if (k.startsWith(prefix)) lastGood.delete(k); };
/** A call from a button: busy while it runs, the server's sentence when it is refused. */
export function useAct() {
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [fieldErrors, setFieldErrors] = useState<Record<string, string>>({});
  async function act<I extends RouteId>(name: string, call: () => Promise<Result<I>>): Promise<Result<I>> {
    setBusy(name); setError(null); setFieldErrors({});
    const r = await call();
    setBusy(null);
    if (!r.ok) { setError(r.message); setFieldErrors(r.fieldErrors ?? {}); }
    return r;
  }
  return { busy, error, fieldErrors, act, setError };
}
