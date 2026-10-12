'use client';
import { publicEnv } from '@/lib/public-env';
import { supabaseBrowser } from '@/lib/supabase/browser';

// Public reads from the browser (calendar, quote, search, cookie choice). On Supabase they go
// straight to the API with the anon key, so the Worker does no work; on the local stack they go
// through /api/rpc, which calls the same function as the anonymous role.
export async function browserRpc<T = unknown>(fn: string, args: Record<string, unknown>): Promise<T> {
  if (publicEnv.dataBackend === 'supabase') {
    const { data, error } = await (supabaseBrowser() as unknown as { rpc(f: string, a: object): PromiseLike<{ data: unknown; error: { message: string } | null }> }).rpc(fn, args);
    if (error) throw new Error(error.message);
    return data as T;
  }
  const r = await fetch(`/api/rpc/${fn}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(args) });
  const j = (await r.json()) as { data?: T; error?: string };
  if (!r.ok) throw new Error(j.error ?? 'Request failed');
  return j.data as T;
}
