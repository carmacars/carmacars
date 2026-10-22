import 'server-only';
import { revalidatePath } from 'next/cache';
import { env } from '@/lib/env';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { getTokens, siteUrl } from '@/lib/site';
import { textGenerator } from '@/integrations/llm';
import { runSeoJob, type SeoClaim, type SeoSummary } from '@/features/seo/worker';

// The search job as the site runs it (migration 0061): the Worker's cron trigger calls /api/jobs/seo every five
// minutes (custom-worker.ts), and an Admin's "Write again" right after the click. It writes the copy that is due with
// Workers AI, publishes what passes, rebuilds the pages that changed, and sends changed addresses to IndexNow
// (production only: a local or staging site never tells search engines about itself).
const SR = { role: 'service_role' as const };

/** IndexNow (api.indexnow.org shares each submission with Bing, Yandex and the other IndexNow engines). */
export async function sendIndexNow(key: string, paths: string[]): Promise<{ status: number; error?: string }> {
  const base = siteUrl();
  const host = new URL(base).host;
  const r = await fetch('https://api.indexnow.org/indexnow', {
    method: 'POST', headers: { 'content-type': 'application/json; charset=utf-8' },
    body: JSON.stringify({ host, key, keyLocation: `${base}/${key}.txt`, urlList: paths.map((p) => base + p) })
  });
  return { status: r.status, error: r.ok ? undefined : (await r.text().catch(() => '')).slice(0, 200) || r.statusText };
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
    sent: (paths, status, error) => rpc('server_indexnow_sent', { p: { paths, status, error } as unknown as Json }, SR)
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

/** The IndexNow sweep (0097): the next batch of vehicle addresses (up to 10,000, IndexNow's most per request) after the
 *  cursor, sent, and the answer reported: 2xx moves the cursor, 429 and 403 back off (the database keeps the cursor,
 *  the day's count and the back-off, shared with every sender). Production only; nothing is rendered. */
export async function runIndexNowSweep(o: { rounds?: number } = {}): Promise<{ sent: number; why?: string; status?: number }> {
  if (!indexNowOn()) return { sent: 0, why: 'not production' };
  let sent = 0;
  for (let i = 0; i < (o.rounds ?? 1); i++) {
    const c = (await rpc('server_indexnow_claim', { p_limit: 10_000 }, SR)) as unknown as { paths: string[]; cursor?: unknown; files?: number; why?: string; key?: string };
    if (!c.paths?.length || !c.key) return { sent, why: c.why ?? 'no key' };
    const r = await sendIndexNow(c.key, c.paths);
    await rpc('server_indexnow_report', { p: { status: r.status, count: c.paths.length, cursor: c.cursor, files: c.files, error: r.error } as unknown as Json }, SR);
    if (r.status < 200 || r.status >= 300) return { sent, status: r.status };
    sent += c.paths.length;
  }
  return { sent };
}
