// The usage guard's Cloudflare figures (migration 0080): Worker requests and CPU time, Workers AI neurons and R2
// storage, per Toronto day, from Cloudflare's GraphQL analytics. Used by the usage workflow (web/scripts/cf-usage.mjs,
// every hour, with the CLOUDFLARE_API_TOKEN secret of GitHub) and by the Worker's hourly job when the Worker has its own
// read-only analytics token (CLOUDFLARE_ANALYTICS_TOKEN). Each part the token may not read is reported, never fatal.
// The token needs "Account Analytics: Read" (and nothing else).

export interface UsageDay { day: string; values: Record<string, number> }
export interface CloudflareUsage { source: 'cloudflare'; days: UsageDay[]; unavailable: Record<string, string> }

type Fetch = (url: string, init: { method: string; headers: Record<string, string>; body: string }) => Promise<{ json(): Promise<unknown> }>;

/** The UTC instant of midnight in Toronto on a calendar day (YYYY-MM-DD). */
export function torontoMidnight(day: string): Date {
  const [y, m, d] = day.split('-').map(Number) as [number, number, number];
  const guess = new Date(Date.UTC(y, m - 1, d, 5));
  const parts = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', hour: '2-digit', hourCycle: 'h23' }).formatToParts(guess);
  const hour = Number(parts.find((p) => p.type === 'hour')?.value ?? '0');
  return new Date(guess.getTime() - hour * 3600_000);
}

/** The Toronto calendar day of an instant. */
export function torontoDay(at: Date): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(at);
}

/** The days of the current Toronto month up to today (the month-to-date the allowances count), oldest first. */
export function monthDays(now: Date): string[] {
  const today = torontoDay(now);
  const first = `${today.slice(0, 8)}01`;
  const out: string[] = [];
  for (let d = first; d <= today; ) {
    out.push(d);
    const n = new Date(`${d}T12:00:00Z`);
    n.setUTCDate(n.getUTCDate() + 1);
    d = n.toISOString().slice(0, 10);
  }
  return out;
}

export async function cloudflareUsage(o: { token: string; account: string; now?: Date; days?: string[]; fetch?: Fetch }): Promise<CloudflareUsage> {
  const f: Fetch = o.fetch ?? ((u, i) => fetch(u, i));
  const now = o.now ?? new Date();
  const days = o.days ?? monthDays(now);
  const unavailable: Record<string, string> = {};
  const out: UsageDay[] = days.map((day) => ({ day, values: {} }));
  const gql = async (query: string, variables: Record<string, unknown>) => {
    const r = await f('https://api.cloudflare.com/client/v4/graphql', { method: 'POST', headers: { authorization: `Bearer ${o.token}`, 'content-type': 'application/json' }, body: JSON.stringify({ query, variables }) });
    const j = (await r.json()) as { data?: { viewer?: { accounts?: Array<Record<string, unknown>> } }; errors?: Array<{ message: string }> };
    if (j.errors?.length) throw new Error(j.errors.map((e) => e.message).join('; ').slice(0, 300));
    return j.data?.viewer?.accounts?.[0] ?? {};
  };
  for (const d of out) {
    const s = torontoMidnight(d.day).toISOString();
    const next = new Date(`${d.day}T12:00:00Z`); next.setUTCDate(next.getUTCDate() + 1);
    const e = new Date(Math.min(torontoMidnight(next.toISOString().slice(0, 10)).getTime(), now.getTime())).toISOString();
    if (e <= s) continue;
    // 1. every Worker invocation of the account: requests and CPU time (microseconds)
    if (!unavailable.workers) {
      try {
        const a = await gql(`query($a:String!,$s:Time!,$e:Time!){viewer{accounts(filter:{accountTag:$a}){
          w: workersInvocationsAdaptive(limit:1000,filter:{datetime_geq:$s,datetime_lt:$e}){sum{requests cpuTimeUs}}}}}`, { a: o.account, s, e });
        const rows = (a.w as Array<{ sum: { requests: number; cpuTimeUs: number } }>) ?? [];
        d.values.workers_requests = rows.reduce((n, r) => n + (r.sum.requests ?? 0), 0);
        d.values.workers_cpu = Math.round(rows.reduce((n, r) => n + (r.sum.cpuTimeUs ?? 0), 0) / 1000);
      } catch (err) { unavailable.workers = String((err as Error).message ?? err); }
    }
    // 2. Workers AI neurons
    if (!unavailable.workers_ai) {
      try {
        const a = await gql(`query($a:String!,$s:Time!,$e:Time!){viewer{accounts(filter:{accountTag:$a}){
          ai: aiInferenceAdaptiveGroups(limit:1000,filter:{datetime_geq:$s,datetime_lt:$e}){sum{totalNeurons}}}}}`, { a: o.account, s, e });
        const rows = (a.ai as Array<{ sum: { totalNeurons: number } }>) ?? [];
        d.values.workers_ai = Math.round(rows.reduce((n, r) => n + (r.sum.totalNeurons ?? 0), 0));
      } catch (err) { unavailable.workers_ai = String((err as Error).message ?? err); }
    }
  }
  // 3. R2 storage: the latest size of every bucket, today
  try {
    const s = new Date(now.getTime() - 24 * 3600_000).toISOString(), e = now.toISOString();
    const a = await gql(`query($a:String!,$s:Time!,$e:Time!){viewer{accounts(filter:{accountTag:$a}){
      r2: r2StorageAdaptiveGroups(limit:100,filter:{datetime_geq:$s,datetime_lt:$e}){max{payloadSize metadataSize}dimensions{bucketName}}}}}`, { a: o.account, s, e });
    const rows = (a.r2 as Array<{ max: { payloadSize: number; metadataSize: number }; dimensions: { bucketName: string } }>) ?? [];
    const by = new Map<string, number>();
    for (const r of rows) by.set(r.dimensions.bucketName, Math.max(by.get(r.dimensions.bucketName) ?? 0, (r.max.payloadSize ?? 0) + (r.max.metadataSize ?? 0)));
    const today = out.find((x) => x.day === torontoDay(now));
    if (today) today.values.r2_storage = [...by.values()].reduce((n, v) => n + v, 0);
  } catch (err) { unavailable.r2_storage = String((err as Error).message ?? err); }
  return { source: 'cloudflare', days: out.filter((d) => Object.keys(d.values).length), unavailable };
}
