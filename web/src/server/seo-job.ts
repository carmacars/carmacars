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
  if (s.changed.some((p) => p.startsWith('/car-rental/'))) { try { revalidatePath('/car-rental'); } catch { /* ignore */ } }
  if (s.changed.some((p) => p.startsWith('/guides/'))) { try { revalidatePath('/guides'); } catch { /* ignore */ } }
  if (s.changed.length) { try { revalidatePath('/sitemap.xml'); } catch { /* ignore */ } }
  return s;
}
