import 'server-only';
import { required } from '@/lib/env';
import { postgrestRpc, RpcError } from './postgrest';
import { DbError, type Backend } from './repo';

// Supabase backend: one POST to PostgREST per call (postgrest.ts), the request supabase-js's rpc() makes,
// without building a supabase-js client (auth, realtime, storage and functions clients) for every call as
// the signed-in user: that construction was a measurable part of the Worker's CPU time per portal page
// (Cloudflare's Workers Free plan allows 10 ms; docs/audit/2026-10-13-launch-audit.md). The service role key
// never leaves the server (this module is server-only).
// While the deploy builds the pages (next build), a read the database cancels on its statement timeout or a lock
// (57014, 55P03) is tried twice more after a pause: one slow moment of the database must not stop a release
// (deploy run 39289461880). Requests of visitors are never retried here.
const BUILD_RETRY = new Set(['57014', '55P03']);
const building = () => process.env.NEXT_PHASE === 'phase-production-build';

export function supabaseBackend(): Backend {
  return {
    async call(fn, args, o) {
      for (let attempt = 0; ; attempt++) {
        try {
          return await postgrestRpc(fetch, {
            url: required('NEXT_PUBLIC_SUPABASE_URL'), anonKey: required('NEXT_PUBLIC_SUPABASE_ANON_KEY'),
            serviceKey: o.role === 'service_role' ? required('SUPABASE_SERVICE_ROLE_KEY') : undefined
          }, fn, args, o);
        } catch (e) {
          if (e instanceof RpcError && attempt < 2 && BUILD_RETRY.has(e.code ?? '') && building()) {
            await new Promise((r) => setTimeout(r, 2000 * (attempt + 1)));
            continue;
          }
          if (e instanceof RpcError) throw new DbError(e.message, e.code, e.hint);
          throw e;
        }
      }
    }
  };
}
