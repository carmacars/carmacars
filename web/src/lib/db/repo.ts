import 'server-only';
import { env } from '@/lib/env';
import type { Database, Json } from './types';

// The one way the app reaches the database: by calling a function in the public schema, as one
// of the three API roles, exactly as PostgREST would. Two backends:
//   supabase  supabase-js against the project's API (production, staging)
//   local     the Postgres driver against the local stack; each call is one transaction that sets
//             `role` and `request.jwt.claims` first, so row-level security and grants apply for real
// The money rules live in SQL; nothing here re-computes them.

export type DbRole = 'anon' | 'authenticated' | 'service_role';
export type Fns = Database['public']['Functions'];
export type FnName = keyof Fns;
type ArgsOf<F extends FnName> = Fns[F] extends { Args: infer A } ? ([A] extends [never] ? Record<string, never> : A) : never;
type ReturnsOf<F extends FnName> = Fns[F] extends { Returns: infer R } ? R : never;

export interface CallOptions {
  role?: DbRole;
  /** The signed-in user (authenticated role). */
  userId?: string;
  /** Supabase only: the user's access token, for the authenticated role. */
  accessToken?: string;
  requestId?: string;
}

export class DbError extends Error {
  constructor(message: string, public readonly code: string | undefined, public readonly hint?: string) {
    super(message);
    this.name = 'DbError';
  }
}

export interface Backend {
  call(fn: string, args: Record<string, unknown>, opts: Required<Pick<CallOptions, 'role'>> & CallOptions): Promise<unknown>;
}

let backend: Promise<Backend> | undefined;
async function getBackend(): Promise<Backend> {
  if (!backend) {
    backend = env().DATA_BACKEND === 'local'
      ? import('./local').then((m) => m.localBackend())
      : import('./supabase').then((m) => m.supabaseBackend());
  }
  return backend;
}

export async function rpc<F extends FnName>(fn: F, args: ArgsOf<F>, opts: CallOptions = {}): Promise<ReturnsOf<F>> {
  const b = await getBackend();
  const role = opts.role ?? (opts.userId ? 'authenticated' : 'anon');
  return (await b.call(fn, (args ?? {}) as Record<string, unknown>, { ...opts, role })) as ReturnsOf<F>;
}

/** Functions the browser may call through the local bridge (the same set anon may execute). */
export const BROWSER_FUNCTIONS = new Set<FnName>([
  'public_vehicle_calendar', 'quote_booking', 'search_available', 'record_cookie_choice', 'cookie_choice', 'handover_places'
]);

export type { Json };
