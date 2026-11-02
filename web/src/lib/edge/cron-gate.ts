// The five-minute cron tick (custom-worker.ts scheduled) asks the database first whether the listing pipeline or the
// search job has anything to do (public.server_jobs_due, migration 0076): one small call from the Worker entry instead
// of loading the app (about a second of CPU on a fresh isolate) for a tick with nothing to do. Any doubt (no service
// key, the function missing, an error) runs both, as before. No imports: it runs in the Worker entry and in Node.

export interface JobsDue { listing: boolean; seo: boolean; pdf: boolean; phone: boolean; turo: boolean; agreements: boolean; reviews: boolean; crm: boolean; deposits: boolean; ads: boolean; checked: boolean;
  /** 0380: an AI interview waits for a transcript, its scores, or its audio removed */
  interviews?: boolean;
  /** 0324: the month's crawler guard is on (crawlers that are not search or answer crawlers keep to the crawl scope, bot-shield.ts keptToScope) */
  cpu_guard?: boolean;
  /** R23: the search scope is Core (crawlers kept to the crawl scope at the edge, bot-shield.ts shield) */
  search_core?: boolean }

export async function jobsToRun(env: Record<string, unknown>, f: typeof fetch = fetch): Promise<JobsDue> {
  // reviews (the Google reviews sync, 0146) only when the database says so: it calls Google's API
  const all: JobsDue = { listing: true, seo: true, pdf: true, phone: true, turo: true, agreements: true, reviews: false, crm: true, deposits: true, ads: false, interviews: true, checked: false };
  const url = env.NEXT_PUBLIC_SUPABASE_URL, key = env.SUPABASE_SERVICE_ROLE_KEY;
  if (env.DATA_BACKEND !== 'supabase' || typeof url !== 'string' || typeof key !== 'string' || !url || !key) return all;
  try {
    const r = await f(`${url.replace(/\/$/, '')}/rest/v1/rpc/server_jobs_due`, {
      method: 'POST', headers: { apikey: key, authorization: `Bearer ${key}`, 'content-type': 'application/json' }, body: '{}',
      signal: AbortSignal.timeout(5000)
    });
    if (!r.ok) return all;
    const d = (await r.json()) as { listing?: unknown; seo?: unknown; pdf?: unknown; phone?: unknown; turo?: unknown; agreements?: unknown; reviews?: unknown; crm?: unknown; deposits?: unknown; ads?: unknown; interviews?: unknown; cpu_guard?: unknown; search_scope?: unknown } | null;
    if (!d || typeof d !== 'object') return all;
    // pdf: the signed copies waiting (0077); phone: texts and call summaries due (0085); turo: Turo emails waiting for
    // their car to match again (0088)
    // agreements: confirmed bookings still without their rental agreement (0139); reviews: the Google reviews sync,
    // connected and not run for 6 hours (0146); crm: a partner CRM link due a sync (0147); deposits: a card hold to capture
    // before it lapses, a money step waiting for Stripe, or the day's balance follow-up (0155; run when in doubt: money);
    // ads: the posted ads, the week's social drafts and Meta publishing (0167), only when the database says so
    return { listing: d.listing !== false, seo: d.seo !== false, pdf: d.pdf !== false, phone: d.phone !== false, turo: d.turo === true, agreements: d.agreements !== false, reviews: d.reviews === true, crm: d.crm === true, deposits: d.deposits !== false, ads: d.ads === true, interviews: d.interviews === true, cpu_guard: d.cpu_guard === true, search_core: d.search_scope === 'core', checked: true };
  } catch {
    return all;
  }
}

// Phone and browser alerts (migration 0300): asked only when the Worker has the VAPID keys or (0390, the store app) the
// Firebase service account, so a site without either makes no extra call; the database is asked only about the kinds
// this Worker can send. Any doubt (an error, no answer) sends: the job asks the database again and does nothing when idle.
export function pushKindsOf(env: Record<string, unknown>): string[] {
  const has = (k: string) => typeof env[k] === 'string' && (env[k] as string).trim() !== '';
  return [...(has('VAPID_PUBLIC_KEY') && has('VAPID_PRIVATE_KEY') ? ['web'] : []), ...(has('FCM_SERVICE_ACCOUNT') ? ['fcm'] : [])];
}

export async function pushWaiting(env: Record<string, unknown>, f: typeof fetch = fetch): Promise<boolean> {
  const kinds = pushKindsOf(env);
  if (!kinds.length) return false;
  const url = env.NEXT_PUBLIC_SUPABASE_URL, key = env.SUPABASE_SERVICE_ROLE_KEY;
  if (env.DATA_BACKEND !== 'supabase' || typeof url !== 'string' || typeof key !== 'string' || !url || !key) return true;
  try {
    const r = await f(`${url.replace(/\/$/, '')}/rest/v1/rpc/server_push_waiting`, {
      method: 'POST', headers: { apikey: key, authorization: `Bearer ${key}`, 'content-type': 'application/json' }, body: JSON.stringify({ p_kinds: kinds }),
      signal: AbortSignal.timeout(5000)
    });
    if (!r.ok) return true;
    return (await r.json()) !== false;
  } catch {
    return true;
  }
}
