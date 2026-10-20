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
  /** The view-as check itself (src/server/view-as.ts) reads the Admin gate without being checked again. */
  skipViewAs?: boolean;
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
  let accessToken = opts.accessToken;
  const a = (args ?? {}) as Record<string, unknown>;
  // An Admin viewing as someone (src/server/view-as.ts): calls made for that person read with their identity, and
  // anything else made for them is refused. Only calls tied to a person are looked at, so a public page never
  // reads cookies here (it would stop being static).
  if (!opts.skipViewAs && (role === 'authenticated' || 'p_by' in a || 'p_user' in a)) {
    const va = await import('@/server/view-as');
    const v = await va.viewAs();
    if (v) {
      if (va.refusedForViewAs(v, fn, a, opts.userId)) throw new va.ViewAsReadOnly();
      if (role === 'authenticated' && !accessToken && opts.userId === v.target.id) accessToken = (await va.viewAsToken()) ?? undefined;
    }
  }
  // The database API decides who the caller is from the session's access token, never from a user id
  // the server passes along: a call as the signed-in user carries their token (on Supabase a call without
  // it runs as anon and every row-level-security read is refused: React error #441 on /account).
  if (role === 'authenticated' && !accessToken) {
    accessToken = (await (await (await import('@/lib/auth')).auth()).accessToken()) ?? undefined;
    if (!accessToken) throw new DbError('Sign in first', '42501');
  }
  const rest: CallOptions = { ...opts };
  delete rest.skipViewAs;
  // While `next build` pre-renders the public pages, each build worker reads the same public rows (settings, page
  // texts, the fleet, the footer links) once instead of once per page: about 145 reads became about 35, so a slow
  // moment of the database touches fewer of them (deploy run 39310793167). Never used for a visitor's request.
  if (role === 'anon' && !accessToken && process.env.NEXT_PHASE === 'phase-production-build') {
    const key = `${fn}:${JSON.stringify(a)}`;
    let p = buildReads.get(key);
    if (!p) { p = b.call(fn, a, { ...rest, role }); buildReads.set(key, p); p.catch(() => buildReads.delete(key)); }
    return (await p) as ReturnsOf<F>;
  }
  return (await b.call(fn, a, { ...rest, role, accessToken })) as ReturnsOf<F>;
}
const buildReads = new Map<string, Promise<unknown>>();

/** Functions the browser may call through the local bridge (the same set anon may execute). */
export const BROWSER_FUNCTIONS = new Set<FnName>([
  'public_vehicle_calendar', 'quote_booking', 'addons_for_car', 'search_available', 'record_cookie_choice', 'cookie_choice', 'handover_places', 'chat_poll', 'chat_typing',
  // discount games (0069): the settings, a play and its reveal
  'game_cfg', 'game_start', 'game_reveal'
]);

export type { Json };
