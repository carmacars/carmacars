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
  // Site-wide public reads (settings, facts, footer links, sitemap lists): the same answer for every visitor, so each
  // Worker instance keeps it for SHARED_TTL_MS, shares one call among concurrent requests, and keeps serving the last
  // good answer for up to a day when the database errors or is too busy. Before this, every page render read them
  // again (seo_links and site_facts were about 0.5 s each), and a crawl made the database fall over (2026-10-22).
  if (role === 'anon' && !accessToken && SHARED_READS.has(fn) && env().DATA_BACKEND !== 'local') {
    return (await sharedRead(`${fn}:${JSON.stringify(a)}`, () => b.call(fn, a, { ...rest, role }))) as ReturnsOf<F>;
  }
  return (await b.call(fn, a, { ...rest, role, accessToken })) as ReturnsOf<F>;
}
const buildReads = new Map<string, Promise<unknown>>();

const SHARED_READS = new Set<string>([
  'site_settings_public', 'site_facts', 'site_content', 'vehicle_classes', 'seo_links', 'seo_pages_public', 'articles_public',
  'sitemap_all', 'place_sitemap_files', 'vehicle_tiers', 'vehicle_tier_files_count', 'vehicle_sitemap_index'
]);
const SHARED_TTL_MS = 5 * 60_000;
const SHARED_STALE_MS = 24 * 3600_000;
const shared = new Map<string, { at: number; value?: unknown; pending?: Promise<unknown> }>();
/** One shared read: fresh for SHARED_TTL_MS, refreshed by one caller at a time, the last good value on an error. */
export async function sharedRead(key: string, load: () => Promise<unknown>, now = Date.now()): Promise<unknown> {
  const e = shared.get(key);
  const has = e !== undefined && 'value' in e;
  if (has && now - e.at < SHARED_TTL_MS) return e.value;
  if (e?.pending) return has ? e.value : e.pending;
  const entry = e ?? { at: 0 };
  const p = load().then(
    (v) => { entry.at = Date.now(); entry.value = v; entry.pending = undefined; return v; },
    (err) => { entry.pending = undefined; if ('value' in entry && Date.now() - entry.at < SHARED_STALE_MS) return entry.value; if (!('value' in entry)) shared.delete(key); throw err; }
  );
  entry.pending = p;
  if (has) p.catch(() => {});
  shared.set(key, entry);
  if (shared.size > 2000) shared.delete(shared.keys().next().value as string);
  return has ? entry.value : p;
}

/** Functions the browser may call through the local bridge (the same set anon may execute). */
export const BROWSER_FUNCTIONS = new Set<FnName>([
  'public_vehicle_calendar', 'quote_booking', 'addons_for_car', 'search_available', 'record_cookie_choice', 'record_cookie_notice', 'cookie_choice', 'handover_places', 'chat_poll', 'chat_typing',
  // discount games (0069): the settings, a play and its reveal
  'game_cfg', 'game_start', 'game_reveal',
  // the chat's greeting for a page (0100)
  'chat_greeting',
  // the request form's car when another one is chosen, and the real car for a sample car's dates (0102)
  'booking_car', 'sample_car_match'
]);

export type { Json };
