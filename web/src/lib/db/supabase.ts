import 'server-only';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { required } from '@/lib/env';
import { DbError, type Backend } from './repo';
import type { Database } from './types';

// Supabase backend: PostgREST through supabase-js. The service role key never leaves the server
// (this module is server-only), and the anon and user clients carry no cookies of their own.
let anon: SupabaseClient<Database> | undefined;
let service: SupabaseClient<Database> | undefined;
const opts = { auth: { persistSession: false, autoRefreshToken: false } } as const;

function client(role: string, accessToken?: string): SupabaseClient<Database> {
  const url = required('NEXT_PUBLIC_SUPABASE_URL');
  if (role === 'service_role') return (service ??= createClient<Database>(url, required('SUPABASE_SERVICE_ROLE_KEY'), opts));
  if (role === 'authenticated' && accessToken) {
    return createClient<Database>(url, required('NEXT_PUBLIC_SUPABASE_ANON_KEY'), { ...opts, global: { headers: { Authorization: `Bearer ${accessToken}` } } });
  }
  return (anon ??= createClient<Database>(url, required('NEXT_PUBLIC_SUPABASE_ANON_KEY'), opts));
}

export function supabaseBackend(): Backend {
  return {
    async call(fn, args, o) {
      const c = client(o.role, o.accessToken) as unknown as { rpc(fn: string, args: object): PromiseLike<{ data: unknown; error: { message: string; code?: string; hint?: string } | null }> };
      const { data, error } = await c.rpc(fn, args);
      if (error) throw new DbError(error.message, error.code, error.hint);
      return data;
    }
  };
}
