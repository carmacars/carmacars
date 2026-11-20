// The app's client for the site's mobile API (/api/m/v1). Typed from the shared contract: a route id, its path
// parameters and its body in, the route's answer out. It keeps the session fresh (a new access token a minute before the
// old one ends, and once more when the server says it has ended), tells "no connection" apart from a refusal, and never
// throws: every call resolves to { ok: true, data } or { ok: false, code, message }.
// No React, no native modules: fetch and the session store are handed in, so the unit test runs it in Node.
import { API_PREFIX, APP_HEADER, ROUTES, routePath, type ApiFail, type ApiResult, type BodyOf, type MobileSession, type ResponseOf, type RouteDef, type RouteId } from '../shared.ts';

export interface SessionStore { get(): Promise<MobileSession | null>; set(s: MobileSession | null): Promise<void> }
export interface ClientDeps {
  baseUrl: string;
  fetch: typeof fetch;
  session: SessionStore;
  appVersion: string;
  platform: 'ios' | 'android';
  /** The session ended for good (the refresh token was refused): the app shows the sign-in screen. */
  onSignedOut?: () => void;
  /** Whether the last call reached the server (the offline banner). */
  onReachable?: (reachable: boolean) => void;
  now?: () => number;
  timeoutMs?: number;
}
export type CallOptions<I extends RouteId> = { params?: Record<string, string>; query?: Record<string, string | number | undefined | null>; signal?: AbortSignal }
  & (BodyOf<I> extends undefined ? { body?: undefined } : { body: BodyOf<I> });
export type Result<I extends RouteId> = (ApiResult<ResponseOf<I>> & { next?: string });
export interface UploadFile { uri: string; name: string; type: string }

export const OFFLINE: ApiFail = { ok: false, code: 'offline', message: 'No connection. Check your signal or Wi-Fi and try again.' };
const SLOW: ApiFail = { ok: false, code: 'timeout', message: 'The server took too long to answer. Try again.' };
const BROKEN: ApiFail = { ok: false, code: 'error', message: 'Something went wrong. Please try again.' };
/** Refresh this many seconds before the access token ends. */
export const REFRESH_AHEAD_S = 60;

export function createClient(d: ClientDeps) {
  const now = d.now ?? Date.now;
  const base = d.baseUrl.replace(/\/$/, '') + API_PREFIX;
  let refreshing: Promise<MobileSession | null> | null = null;

  async function send(id: RouteId, o: { params?: Record<string, string>; query?: Record<string, string | number | undefined | null>; body?: unknown; form?: FormData; signal?: AbortSignal }, token: string | null): Promise<ApiResult<unknown> & { next?: string }> {
    const def = ROUTES[id] as RouteDef<unknown>;
    let url = base + routePath(id, o.params);
    const q = Object.entries(o.query ?? {}).filter(([, v]) => v !== undefined && v !== null && v !== '');
    if (q.length) url += '?' + q.map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(String(v))}`).join('&');
    const headers: Record<string, string> = { accept: 'application/json', [APP_HEADER]: `${d.appVersion} ${d.platform}` };
    if (token) headers.authorization = `Bearer ${token}`;
    let body: string | FormData | undefined;
    if (o.form) body = o.form;
    else if (def.method !== 'GET' && def.body) { headers['content-type'] = 'application/json'; body = JSON.stringify(o.body ?? {}); }
    const ctl = new AbortController();
    let timedOut = false;
    const timer = setTimeout(() => { timedOut = true; ctl.abort(); }, o.form ? Math.max(d.timeoutMs ?? 20_000, 90_000) : d.timeoutMs ?? 20_000);
    const onAbort = () => ctl.abort();
    o.signal?.addEventListener('abort', onAbort);
    try {
      const res = await d.fetch(url, { method: def.method, headers, body, signal: ctl.signal });
      d.onReachable?.(true);
      let j: unknown;
      try { j = await res.json(); } catch { return res.status === 502 || res.status === 503 || res.status === 504 ? { ...SLOW, code: 'busy' } : BROKEN; }
      if (j && typeof j === 'object' && typeof (j as { ok?: unknown }).ok === 'boolean') return j as ApiResult<unknown>;
      return BROKEN;
    } catch {
      if (timedOut) { d.onReachable?.(true); return SLOW; }
      if (o.signal?.aborted) return { ok: false, code: 'cancelled', message: 'Cancelled.' };
      d.onReachable?.(false);
      return OFFLINE;
    } finally {
      clearTimeout(timer);
      o.signal?.removeEventListener('abort', onAbort);
    }
  }

  /** One refresh at a time, shared by every call that needs it. Null: no new token (signed out, or the server was not reached). */
  function refresh(current: MobileSession): Promise<MobileSession | null> {
    refreshing ??= (async () => {
      try {
        const r = await send('auth.refresh', { body: { refresh_token: current.refresh_token } }, null);
        if (r.ok) { const s = r.data as MobileSession; await d.session.set(s); return s; }
        // refused for good: the session is over. Busy or offline: keep it and try again with the next call
        if (r.code === 'expired' || r.code === 'auth' || r.code === 'invalid') { await d.session.set(null); d.onSignedOut?.(); }
        return null;
      } finally { refreshing = null; }
    })();
    return refreshing;
  }

  async function run<I extends RouteId>(id: I, o: { params?: Record<string, string>; query?: Record<string, string | number | undefined | null>; body?: unknown; form?: () => FormData; signal?: AbortSignal }): Promise<Result<I>> {
    const def = ROUTES[id] as RouteDef<unknown>;
    let s = await d.session.get();
    if (def.auth === 'user' && !s) return { ok: false, code: 'auth', message: 'Sign in first.' };
    if (s && s.expires_at - now() / 1000 < REFRESH_AHEAD_S && id !== 'auth.refresh') {
      const fresh = await refresh(s);
      if (fresh) s = fresh;
      else if (def.auth === 'user' && !(await d.session.get())) return { ok: false, code: 'auth', message: 'Sign in again.' };
    }
    let r = await send(id, { ...o, form: o.form?.() }, s?.access_token ?? null);
    if (!r.ok && r.code === 'expired' && s) {
      const fresh = await refresh(s);
      if (fresh) r = await send(id, { ...o, form: o.form?.() }, fresh.access_token);
      else if (!(await d.session.get())) return { ok: false, code: 'auth', message: 'Sign in again.' };
    }
    return r as Result<I>;
  }

  return {
    /** One call of the API. */
    call<I extends RouteId>(id: I, ...[o]: BodyOf<I> extends undefined ? [o?: CallOptions<I>] : [o: CallOptions<I>]): Promise<Result<I>> {
      return run(id, (o ?? {}) as { params?: Record<string, string>; body?: unknown });
    },
    /** A photo to a route that takes one, with its other form fields. */
    upload<I extends RouteId>(id: I, params: Record<string, string>, file: UploadFile, fields: Record<string, string> = {}): Promise<Result<I>> {
      return run(id, { params, form: () => {
        const f = new FormData();
        for (const [k, v] of Object.entries(fields)) f.append(k, v);
        // React Native's FormData takes a file as { uri, name, type }
        f.append('file', file as unknown as Blob);
        return f;
      } });
    },
    /** Keeps the session a sign-in route answered with. */
    async adopt(s: MobileSession): Promise<void> { await d.session.set(s); },
    /** Ends this phone's session: the server is told when it can be reached; the phone forgets either way. */
    async signOut(): Promise<void> {
      const s = await d.session.get();
      if (s) await send('auth.signOut', {}, s.access_token).catch(() => undefined);
      await d.session.set(null);
    }
  };
}
export type Client = ReturnType<typeof createClient>;
