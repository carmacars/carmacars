import 'server-only';
import { env } from '@/lib/env';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { siteUrl } from '@/lib/site';
import { matchReviews, type Candidate } from '@/features/reviews/match';

// The Google Business Profile reviews sync (migration 0146, docs/changes/2026-10-24-review-requests.md). An Admin
// connects rent@carmacars.ca once (Admin > Settings > Reviews, OAuth with offline access); the refresh token goes to the
// vault. Every 6 hours the Worker's cron tick runs /api/jobs/reviews: a fresh access token, the account and location
// (the one whose place id is in Site settings), the newest reviews (accounts.locations.reviews.list), each matched to a
// renter by name in the window after their return (src/features/reviews/match.ts), written back to the database.
// Google gives this API only to approved projects: a refusal is recorded as "api_not_approved" and shown on the screen,
// and the rest of the review program works without it. No token or reviewer name is ever logged.
const SR = { role: 'service_role' as const };
export const GOOGLE_SCOPE = 'https://www.googleapis.com/auth/business.manage';
export const GOOGLE_ACCOUNT_HINT = 'rent@carmacars.ca';
export const callbackUrl = () => `${siteUrl()}/api/google/reviews/callback`;

export function googleKeys(): { id: string; secret: string } | null {
  const e = env();
  return e.GOOGLE_REVIEWS_CLIENT_ID && e.GOOGLE_REVIEWS_CLIENT_SECRET ? { id: e.GOOGLE_REVIEWS_CLIENT_ID, secret: e.GOOGLE_REVIEWS_CLIENT_SECRET } : null;
}

/** The consent screen's address. */
export function consentUrl(state: string): string | null {
  const k = googleKeys();
  if (!k) return null;
  const q = new URLSearchParams({ client_id: k.id, redirect_uri: callbackUrl(), response_type: 'code', scope: `openid email ${GOOGLE_SCOPE}`,
    access_type: 'offline', prompt: 'consent', include_granted_scopes: 'true', login_hint: GOOGLE_ACCOUNT_HINT, state });
  return `https://accounts.google.com/o/oauth2/v2/auth?${q}`;
}

/** The code from the consent screen: the refresh token and the account's address. */
export async function exchangeCode(code: string, f: typeof fetch = fetch): Promise<{ refreshToken: string | null; email: string | null }> {
  const k = googleKeys();
  if (!k) throw new Error('The Google app keys are not set');
  const r = await f('https://oauth2.googleapis.com/token', { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ code, client_id: k.id, client_secret: k.secret, redirect_uri: callbackUrl(), grant_type: 'authorization_code' }), signal: AbortSignal.timeout(15_000) });
  const d = (await r.json().catch(() => ({}))) as { refresh_token?: string; id_token?: string; error?: string };
  if (!r.ok) throw new Error(`Google refused the code (${d.error ?? r.status})`);
  let email: string | null = null;
  try {
    const part = d.id_token?.split('.')[1];
    if (part) email = (JSON.parse(atob(part.replace(/-/g, '+').replace(/_/g, '/'))) as { email?: string }).email ?? null;
  } catch { email = null; }
  return { refreshToken: d.refresh_token ?? null, email };
}

interface Begin { connected: boolean; refresh_token?: string; account_name?: string | null; location_name?: string | null; place_id?: string | null;
  match_days?: number; auto_match?: boolean; candidates?: Candidate[]; known?: string[] }
interface GReview { name: string; reviewer?: { displayName?: string; isAnonymous?: boolean }; starRating?: string; comment?: string; createTime: string; updateTime?: string; reviewReply?: { comment?: string } }
const STARS: Record<string, number> = { ONE: 1, TWO: 2, THREE: 3, FOUR: 4, FIVE: 5 };

class GoogleError extends Error { constructor(message: string, readonly notApproved = false) { super(message); } }

async function getJson<T>(url: string, token: string, f: typeof fetch): Promise<T> {
  const r = await f(url, { headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(20_000) });
  const d = (await r.json().catch(() => ({}))) as T & { error?: { message?: string; status?: string; code?: number } };
  if (!r.ok) {
    const msg = d.error?.message ?? `HTTP ${r.status}`;
    // a project without access: the API not enabled, or enabled with no quota until Google approves it
    const notApproved = r.status === 403 || r.status === 429 && /quota/i.test(msg) || /has not been used|is disabled|SERVICE_DISABLED|PERMISSION_DENIED/i.test(`${msg} ${d.error?.status ?? ''}`);
    throw new GoogleError(`${r.status} ${msg}`.slice(0, 300), notApproved);
  }
  return d;
}

async function accessToken(refresh: string, f: typeof fetch): Promise<string> {
  const k = googleKeys();
  if (!k) throw new GoogleError('The Google app keys are not set (GOOGLE_REVIEWS_CLIENT_ID, GOOGLE_REVIEWS_CLIENT_SECRET)');
  const r = await f('https://oauth2.googleapis.com/token', { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ client_id: k.id, client_secret: k.secret, refresh_token: refresh, grant_type: 'refresh_token' }), signal: AbortSignal.timeout(15_000) });
  const d = (await r.json().catch(() => ({}))) as { access_token?: string; error?: string };
  if (!r.ok || !d.access_token) throw new GoogleError(d.error === 'invalid_grant' ? 'Google no longer accepts the connection: connect again' : `Google refused the token (${d.error ?? r.status})`);
  return d.access_token;
}

/** The account and location: the ones on record, else the location whose place id is in Site settings (or the only one). */
async function findLocation(b: Begin, token: string, f: typeof fetch): Promise<{ account: string; location: string; title: string | null }> {
  if (b.account_name && b.location_name) return { account: b.account_name, location: b.location_name, title: null };
  const acc = await getJson<{ accounts?: Array<{ name: string }> }>('https://mybusinessaccountmanagement.googleapis.com/v1/accounts?pageSize=20', token, f);
  const found: Array<{ account: string; location: string; title: string | null; placeId: string | null }> = [];
  for (const a of acc.accounts ?? []) {
    const l = await getJson<{ locations?: Array<{ name: string; title?: string; metadata?: { placeId?: string } }> }>(
      `https://mybusinessbusinessinformation.googleapis.com/v1/${a.name}/locations?readMask=name,title,metadata&pageSize=100`, token, f);
    for (const x of l.locations ?? []) found.push({ account: a.name, location: x.name, title: x.title ?? null, placeId: x.metadata?.placeId ?? null });
  }
  const pick = found.find((x) => b.place_id && x.placeId === b.place_id) ?? (found.length === 1 ? found[0] : undefined);
  if (!pick) throw new GoogleError(found.length ? 'Several Business Profile locations: set the Google place id in Site settings' : 'No Business Profile location on this Google account');
  return { account: pick.account, location: pick.location, title: pick.title };
}

/** One run of the sync. */
export async function runReviewsSync(f: typeof fetch = fetch): Promise<Record<string, unknown>> {
  const b = (await rpc('server_review_google_sync_begin', {}, SR)) as unknown as Begin;
  if (!b?.connected || !b.refresh_token) return { status: 'not_connected' };
  const finish = (p: Record<string, unknown>) => rpc('server_review_google_sync_finish', { p: p as Json }, SR);
  try {
    const token = await accessToken(b.refresh_token, f);
    const where = await findLocation(b, token, f);
    const reviews: GReview[] = [];
    let page = '';
    for (let i = 0; i < 5; i++) {
      const d = await getJson<{ reviews?: GReview[]; nextPageToken?: string }>(
        `https://mybusiness.googleapis.com/v4/${where.account}/${where.location}/reviews?pageSize=50&orderBy=updateTime%20desc${page ? `&pageToken=${encodeURIComponent(page)}` : ''}`, token, f);
      reviews.push(...(d.reviews ?? []));
      if (!d.nextPageToken) break;
      page = d.nextPageToken;
    }
    const rows = reviews.filter((r) => r.name && r.createTime).map((r) => ({
      id: r.name, reviewer_name: r.reviewer?.isAnonymous ? null : r.reviewer?.displayName ?? null, star_rating: STARS[r.starRating ?? ''] ?? null,
      comment: r.comment ?? null, reply: r.reviewReply?.comment ?? null, reviewed_at: r.createTime, updated_at: r.updateTime ?? null
    }));
    const known = new Set(b.known ?? []);
    const matches = matchReviews(rows.filter((r) => !known.has(r.id)), b.candidates ?? [], { windowDays: b.match_days ?? 30, autoMatch: b.auto_match !== false });
    return (await finish({ status: 'connected', account_name: where.account, location_name: where.location, location_title: where.title, reviews: rows, matches })) as unknown as Record<string, unknown>;
  } catch (e) {
    const g = e instanceof GoogleError ? e : null;
    const status = g?.notApproved ? 'api_not_approved' : 'error';
    await finish({ status, error: (e instanceof Error ? e.message : 'The sync failed').slice(0, 300) });
    return { status };
  }
}
