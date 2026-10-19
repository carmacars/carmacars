import 'server-only';
import { required } from '@/lib/env';
import { postgrestRpc, RpcError, withBuildRetry } from './postgrest';
import { DbError, type Backend } from './repo';

// Supabase backend: one POST to PostgREST per call (postgrest.ts), the request supabase-js's rpc() makes,
// without building a supabase-js client (auth, realtime, storage and functions clients) for every call as
// the signed-in user: that construction was a measurable part of the Worker's CPU time per portal page
// (Cloudflare's Workers Free plan allows 10 ms; docs/audit/2026-10-13-launch-audit.md). The service role key
// never leaves the server (this module is server-only).
export function supabaseBackend(): Backend {
  return {
    async call(fn, args, o) {
      try {
        // pre-rendering during `next build` tries a slow database again (postgrest.ts, withBuildRetry)
        return await withBuildRetry(() => postgrestRpc(fetch, {
          url: required('NEXT_PUBLIC_SUPABASE_URL'), anonKey: required('NEXT_PUBLIC_SUPABASE_ANON_KEY'),
          serviceKey: o.role === 'service_role' ? required('SUPABASE_SERVICE_ROLE_KEY') : undefined
        }, fn, args, o), { building: process.env.NEXT_PHASE === 'phase-production-build' });
      } catch (e) {
        if (e instanceof RpcError) throw new DbError(e.message, e.code, e.hint);
        throw e;
      }
    }
  };
}
