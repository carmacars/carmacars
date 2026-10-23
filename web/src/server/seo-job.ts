import 'server-only';
import { revalidatePath } from 'next/cache';
import { env } from '@/lib/env';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { getTokens, siteUrl } from '@/lib/site';
import { textGenerator } from '@/integrations/llm';
import { runSeoJob, sweepWith, type SeoClaim, type SeoSummary, type SweepClaim } from '@/features/seo/worker';

// The search job as the site runs it (migration 0061): the Worker's cron trigger calls /api/jobs/seo every five
// minutes (custom-worker.ts), and an Admin's "Write again" right after the click. It writes the copy that is due with
// Workers AI, publishes what passes, rebuilds the pages that changed, and sends changed addresses to IndexNow
// (production only: a local or staging site never tells search engines about itself).
const SR = { role: 'service_role' as const };

/** IndexNow, sent to Bing's endpoint (every IndexNow engine shares what one receives). api.indexnow.org answered 429 to
 *  every submission from the Worker's shared addresses (audit of October 22, 2026). At most 10,000 addresses a request
 *  (the protocol's limit). A 429's Retry-After is passed on, so the queue waits exactly that long (0104). */
export const INDEXNOW_ENDPOINT = 'https://www.bing.com/indexnow';
export async function sendIndexNow(key: string, paths: string[]): Promise<{ status: number; error?: string; retryAfter?: number }> {
  const base = siteUrl();
  const host = new URL(base).host;
  const r = await fetch(INDEXNOW_ENDPOINT, {
    method: 'POST', headers: { 'content-type': 'application/json; charset=utf-8' },
    body: JSON.stringify({ host, key, keyLocation: `${base}/${key}.txt`, urlList: paths.slice(0, 10_000).map((p) => base + p) })
  });
  return { status: r.status, error: r.ok ? undefined : (await r.text().catch(() => '')).slice(0, 200) || r.statusText, retryAfter: retryAfterSeconds(r.headers.get('retry-after')) };
}

/** Retry-After in seconds: a number of seconds or an HTTP date; undefined when absent or unreadable. */
export function retryAfterSeconds(h: string | null, now = Date.now()): number | undefined {
  if (!h) return undefined;
  if (/^\d+$/.test(h.trim())) return Number(h.trim()) || undefined;
  const t = Date.parse(h);
  return Number.isFinite(t) && t > now ? Math.ceil((t - now) / 1000) : undefined;
}

export function indexNowOn(): boolean {
  return env().APP_ENV === 'production' && /^https:\/\/(www\.)?carmacars\.ca$/.test(siteUrl());
}

export async function runSeoJobNow(o: { limit?: number; deadlineMs?: number } = {}): Promise<SeoSummary> {
  const text = await textGenerator();
  const s = await runSeoJob({
    claim: async (n) => (await rpc('server_seo_claim', { p_worker: `web-${crypto.randomUUID().slice(0, 8)}`, p_limit: n }, SR)) as unknown as SeoClaim,
    report: (r) => rpc('server_seo_result', { p: r as unknown as Json }, SR),
    text,
    tokens: async () => getTokens(),
    indexNow: indexNowOn() ? sendIndexNow : null,
    sent: (paths, status, error, retryAfter) => rpc('server_indexnow_sent', { p: { paths, status, error, retry_after: retryAfter ?? null } as unknown as Json }, SR)
  }, o);
  // the landing pages' cars and prices (0068): one read of the fleet; pg_cron also does it every 10 minutes
  try { await rpc('server_seo_snapshots', {}, SR); } catch { /* the next run or pg_cron */ }
  // the pages whose copy changed are rebuilt now rather than at their next hourly revalidation
  for (const p of s.changed) { try { revalidatePath(p); } catch { /* outside a request */ } }
  // a car's page changed (a car published by itself, 0070, gets its text here): the fleet page and home list it
  if (s.changed.some((p) => p.startsWith('/cars/'))) { try { revalidatePath('/cars'); revalidatePath('/'); } catch { /* ignore */ } }
  if (s.changed.some((p) => p.startsWith('/car-rental/'))) { try { revalidatePath('/car-rental'); } catch { /* ignore */ } }
  if (s.changed.some((p) => p.startsWith('/guides/'))) { try { revalidatePath('/guides'); } catch { /* ignore */ } }
  if (s.changed.length) { try { revalidatePath('/sitemap.xml'); } catch { /* ignore */ } }
  return s;
}

/** The IndexNow sweep (0097; 0124: the priority list first, then the place files, then the vehicle files): the next
 *  batch (up to 10,000 addresses, IndexNow's most per request) after the cursor, sent, and the answer reported: 2xx
 *  moves the cursor, 429 and 403 back off (the database keeps the cursor, the day's count and the back-off, shared with
 *  every sender). A claim that fails (the database busy) is reported too, so Admin and the gsc workflow see why nothing
 *  went out. Production only; nothing is rendered. */
export async function runIndexNowSweep(o: { rounds?: number } = {}): Promise<{ sent: number; why?: string; status?: number }> {
  if (!indexNowOn()) return { sent: 0, why: 'not production' };
  return sweepWith({
    claim: async () => (await rpc('server_indexnow_claim', { p_limit: 10_000 }, SR)) as unknown as SweepClaim,
    send: sendIndexNow,
    report: (p) => rpc('server_indexnow_report', { p: p as unknown as Json }, SR)
  }, o.rounds ?? 1);
}

