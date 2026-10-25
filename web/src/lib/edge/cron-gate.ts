// The five-minute cron tick (custom-worker.ts scheduled) asks the database first whether the listing pipeline or the
// search job has anything to do (public.server_jobs_due, migration 0076): one small call from the Worker entry instead
// of loading the app (about a second of CPU on a fresh isolate) for a tick with nothing to do. Any doubt (no service
// key, the function missing, an error) runs both, as before. No imports: it runs in the Worker entry and in Node.

export interface JobsDue { listing: boolean; seo: boolean; pdf: boolean; phone: boolean; turo: boolean; agreements: boolean; reviews: boolean; crm: boolean; deposits: boolean; checked: boolean }

export async function jobsToRun(env: Record<string, unknown>, f: typeof fetch = fetch): Promise<JobsDue> {
  // reviews (the Google reviews sync, 0146) only when the database says so: it calls Google's API
  const all: JobsDue = { listing: true, seo: true, pdf: true, phone: true, turo: true, agreements: true, reviews: false, crm: true, deposits: true, checked: false };
  const url = env.NEXT_PUBLIC_SUPABASE_URL, key = env.SUPABASE_SERVICE_ROLE_KEY;
  if (env.DATA_BACKEND !== 'supabase' || typeof url !== 'string' || typeof key !== 'string' || !url || !key) return all;
  try {
    const r = await f(`${url.replace(/\/$/, '')}/rest/v1/rpc/server_jobs_due`, {
      method: 'POST', headers: { apikey: key, authorization: `Bearer ${key}`, 'content-type': 'application/json' }, body: '{}',
      signal: AbortSignal.timeout(5000)
    });
    if (!r.ok) return all;
    const d = (await r.json()) as { listing?: unknown; seo?: unknown; pdf?: unknown; phone?: unknown; turo?: unknown; agreements?: unknown; reviews?: unknown; crm?: unknown; deposits?: unknown } | null;
    if (!d || typeof d !== 'object') return all;
    // pdf: the signed copies waiting (0077); phone: texts and call summaries due (0085); turo: Turo emails waiting for
    // their car to match again (0088)
    // agreements: confirmed bookings still without their rental agreement (0139); reviews: the Google reviews sync,
    // connected and not run for 6 hours (0146); crm: a partner CRM link due a sync (0147); deposits: a card hold to capture
    // before it lapses, a money step waiting for Stripe, or the day's balance follow-up (0155; run when in doubt: money)
    return { listing: d.listing !== false, seo: d.seo !== false, pdf: d.pdf !== false, phone: d.phone !== false, turo: d.turo === true, agreements: d.agreements !== false, reviews: d.reviews === true, crm: d.crm === true, deposits: d.deposits !== false, checked: true };
  } catch {
    return all;
  }
}
