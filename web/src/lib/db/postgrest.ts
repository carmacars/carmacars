// One PostgREST function call (POST /rest/v1/rpc/<fn>), the request supabase-js's rpc() makes, as a plain fetch.
// No imports, so the unit test runs it with a mocked fetch (postgrest.test.ts).
export interface RpcTarget { url: string; anonKey: string; serviceKey?: string }
export interface RpcCaller { role: 'anon' | 'authenticated' | 'service_role'; accessToken?: string; requestId?: string }
export class RpcError extends Error {
  readonly code: string | undefined; readonly hint?: string; readonly status?: number;
  constructor(message: string, code: string | undefined, hint?: string, status?: number) { super(message); this.name = 'RpcError'; this.code = code; this.hint = hint; this.status = status; }
}

export async function postgrestRpc(f: typeof fetch, t: RpcTarget, fn: string, args: Record<string, unknown>, o: RpcCaller): Promise<unknown> {
  if (o.role === 'service_role' && !t.serviceKey) throw new RpcError('The service role key is not set', undefined);
  const key = o.role === 'service_role' ? t.serviceKey! : t.anonKey;
  const bearer = o.role === 'service_role' ? key : o.role === 'authenticated' && o.accessToken ? o.accessToken : t.anonKey;
  const res = await f(`${t.url.replace(/\/$/, '')}/rest/v1/rpc/${encodeURIComponent(fn)}`, {
    method: 'POST',
    headers: { apikey: key, Authorization: `Bearer ${bearer}`, 'content-type': 'application/json', accept: 'application/json',
      ...(o.requestId ? { 'x-request-id': o.requestId } : {}) },
    // no cache option, as supabase-js sends none: 'no-store' would make every public page dynamic in Next.js
    body: JSON.stringify(args ?? {})
  });
  const text = await res.text();
  if (!res.ok) {
    let e: { message?: string; code?: string; hint?: string | null } = {};
    try { e = JSON.parse(text); } catch { e = { message: text.slice(0, 300) || res.statusText }; }
    throw new RpcError(e.message ?? `Database call ${fn} failed (${res.status})`, e.code, e.hint ?? undefined, res.status);
  }
  // a function returning void answers 204 with no body: supabase-js gives null
  return text ? JSON.parse(text) : null;
}

// While `next build` pre-renders pages (the deploy's "Build the Worker"), a slow moment of the database must not fail
// the whole build: a statement timeout (57014), a pooler or network error, or a 5xx is tried again with a growing wait.
// At run time nothing is retried here (a visitor's request answers at once, and the page cache serves the last copy).
const RETRYABLE = new Set(['57014', '53300', '08000', '08003', '08006', '57P01', 'PGRST000', 'PGRST001', 'PGRST002', 'PGRST003']);
export function isRetryable(e: unknown): boolean {
  if (e instanceof RpcError) return (e.code !== undefined && RETRYABLE.has(e.code)) || (e.status !== undefined && (e.status >= 500 || e.status === 429));
  return e instanceof TypeError; // fetch failed: network
}
export async function withBuildRetry<T>(run: () => Promise<T>, o: { building: boolean; tries?: number; waitMs?: number; sleep?: (ms: number) => Promise<void> }): Promise<T> {
  const tries = o.building ? (o.tries ?? 5) : 1;
  const sleep = o.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));
  for (let i = 1; ; i++) {
    try { return await run(); } catch (e) {
      if (i >= tries || !isRetryable(e)) throw e;
      await sleep((o.waitMs ?? 1500) * 2 ** (i - 1));
    }
  }
}
