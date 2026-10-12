import 'server-only';
import postgres from 'postgres';
import { required } from '@/lib/env';
import { DbError, type Backend } from './repo';

// Local backend: one transaction per call, with the role and the JWT claims set first, the way
// PostgREST does it, so row-level security, grants and auth.uid() behave as on Supabase.
type Meta = { args: Map<string, string>; set: boolean };
const g = globalThis as unknown as { __ccSql?: postgres.Sql; __ccMeta?: Map<string, Meta> };

// In workerd (wrangler dev of the Worker build) a socket cannot outlive the request that opened
// it, so each call gets its own connection there; under Node one pool is shared.
const inWorker = typeof navigator !== 'undefined' && navigator.userAgent === 'Cloudflare-Workers';
function client(): postgres.Sql {
  if (inWorker) return postgres(required('DATABASE_URL'), { max: 1, onnotice: () => {} });
  if (!g.__ccSql) g.__ccSql = postgres(required('DATABASE_URL'), { max: 8, idle_timeout: 20, onnotice: () => {} });
  return g.__ccSql;
}
async function withClient<T>(fn: (sql: postgres.Sql) => Promise<T>): Promise<T> {
  const sql = client();
  try { return await fn(sql); } finally { if (inWorker) await sql.end({ timeout: 1 }); }
}

async function meta(fn: string): Promise<Meta> {
  g.__ccMeta ??= new Map();
  const hit = g.__ccMeta.get(fn);
  if (hit) return hit;
  const rows = await withClient((sql) => sql`
    select coalesce(p.proargnames, '{}') as names, coalesce(p.proargmodes, '{}') as modes,
           array(select format_type(t, null) from unnest(coalesce(p.proallargtypes, string_to_array(nullif(p.proargtypes::text, ''), ' ')::oid[], '{}')) t) as types,
           p.proretset or coalesce('t' = any(p.proargmodes), false) as set
      from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = ${fn}`);
  const r = rows[0];
  if (!r || rows.length > 1) throw new DbError(`Unknown or overloaded function public.${fn}`, '42883');
  const args = new Map<string, string>();
  (r.names as string[]).forEach((n, i) => {
    const mode = (r.modes as string[])[i] ?? 'i';
    if (mode === 'i' || mode === 'b') args.set(n, (r.types as string[])[i] ?? 'text');
  });
  const m = { args, set: r.set as boolean };
  g.__ccMeta.set(fn, m);
  return m;
}

function param(v: unknown): string | null {
  if (v === undefined || v === null) return null;
  if (typeof v === 'object') return JSON.stringify(v);
  return String(v);
}

export function localBackend(): Backend {
  return {
    async call(fn, args, opts) {
      const m = await meta(fn);
      const names = Object.keys(args).filter((k) => args[k] !== undefined);
      for (const n of names) if (!m.args.has(n)) throw new DbError(`public.${fn} has no argument ${n}`, '42883');
      const list = names.map((n, i) => `${n} => $${i + 1}::text::${m.args.get(n)}`).join(', ');
      const claims = JSON.stringify({ role: opts.role, ...(opts.userId ? { sub: opts.userId } : {}) });
      try {
        return await withClient((sql) => sql.begin(async (tx) => {
          await tx.unsafe(
            `select set_config('role', $1, true), set_config('request.jwt.claims', $2, true),
                    set_config('request.jwt.claim.sub', $3, true), set_config('app.request_id', $4, true)`,
            [opts.role, claims, opts.userId ?? '', opts.requestId ?? '']
          );
          const rows = await tx.unsafe(`select to_jsonb(r) as v from public.${fn}(${list}) r`, names.map((n) => param(args[n])));
          const values = rows.map((row) => row.v as unknown);
          return m.set ? values : (values[0] ?? null);
        }));
      } catch (e) {
        if (e instanceof DbError) throw e;
        const pe = e as { message?: string; code?: string; hint?: string };
        throw new DbError(pe.message ?? 'Database error', pe.code, pe.hint);
      }
    }
  };
}

/** Local auth and the local bridge use the driver directly (src/lib/auth/local.ts). */
export function localSql(): postgres.Sql {
  return client();
}
