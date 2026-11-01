'use client';
import { publicEnv } from '@/lib/public-env';

// Public reads from the browser (calendar, quote, search, cookie choice). On Supabase they go
// straight to the API with the anon key, so the Worker does no work; on the local stack they go
// through /api/rpc, which calls the same function as the anonymous role.
export async function browserRpc<T = unknown>(fn: string, args: Record<string, unknown>): Promise<T> {
  if (publicEnv.dataBackend === 'supabase') {
    // loaded only when needed, so pages that never call it do not carry the client
    const { supabaseBrowser } = await import('@/lib/supabase/browser');
    const { data, error } = await (supabaseBrowser() as unknown as { rpc(f: string, a: object): PromiseLike<{ data: unknown; error: { message: string } | null }> }).rpc(fn, args);
    if (error) throw new Error(error.message);
    return data as T;
  }
  return localRpc<T>(fn, args);
}

async function localRpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const r = await fetch(`/api/rpc/${fn}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(args) });
  const j = (await r.json()) as { data?: T; error?: string };
  if (!r.ok) throw new Error(j.error ?? 'Request failed');
  return j.data as T;
}

/** A small public read on a pointer gesture (the car card photos, src/lib/card-photos.ts): on Supabase a plain fetch to
 *  the database API with the anon key, as the Worker's fleet check does (src/lib/edge/fleet-sig.ts), so the Supabase
 *  client is never loaded for it and the Worker does no work; locally the same /api/rpc route. */
export async function publicRead<T = unknown>(fn: string, args: Record<string, unknown>): Promise<T> {
  if (publicEnv.dataBackend === 'supabase') {
    const key = publicEnv.supabaseAnonKey;
    const r = await fetch(`${publicEnv.supabaseUrl.replace(/\/$/, '')}/rest/v1/rpc/${fn}`, {
      method: 'POST', headers: { apikey: key, authorization: `Bearer ${key}`, 'content-type': 'application/json' }, body: JSON.stringify(args)
    });
    if (!r.ok) throw new Error('Request failed');
    return (await r.json()) as T;
  }
  return localRpc<T>(fn, args);
}
