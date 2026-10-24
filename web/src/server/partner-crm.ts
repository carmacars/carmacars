import 'server-only';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { storage } from '@/integrations/storage';
import { crmClient } from '@/integrations/crm';
import { runSync, testConnection, type Job, type Report } from '@/features/partner-crm/sync';
import { redact } from '@/features/partner-crm/ghl';

// The partner CRM link's server side (migration 0136). The database decides what is shared (never a partner car), when a
// run is due and what their cars become; this file reads the token from the vault for the call only, talks to their CRM
// through src/features/partner-crm, copies their photos into the public bucket and reports back. The token is never
// logged, returned or put in an error.
const SR = { role: 'service_role' as const };

/** Only a public https address: no IP literals, no local names (their feed and their photos). */
export function publicHttps(u: string): URL | null {
  try {
    const x = new URL(u);
    if (x.protocol !== 'https:' || x.username || x.password) return null;
    const h = x.hostname.toLowerCase();
    if (!h.includes('.') || /^[\d.]+$/.test(h) || h.includes(':') || h === 'localhost' || h.endsWith('.local') || h.endsWith('.internal') || h.endsWith('.localhost')) return null;
    return x;
  } catch { return null; }
}

async function fetchCapped(u: string, max: number, accept: RegExp): Promise<{ bytes: Uint8Array; type: string } | null> {
  const url = publicHttps(u);
  if (!url) throw new Error('Not a public https address');
  const r = await fetch(url, { redirect: 'follow', signal: AbortSignal.timeout(15_000), headers: { 'user-agent': 'CarmaCars partner sync (+https://carmacars.ca)' } });
  if (!r.ok) throw new Error(`The address answered ${r.status}`);
  const type = (r.headers.get('content-type') ?? '').split(';')[0]!.trim().toLowerCase();
  if (!accept.test(type)) return null;
  const len = Number(r.headers.get('content-length') ?? '0');
  if (len > max) throw new Error('Too large');
  const buf = new Uint8Array(await r.arrayBuffer());
  if (buf.byteLength > max) throw new Error('Too large');
  return { bytes: buf, type };
}

export async function fetchFeed(u: string): Promise<string> {
  const f = await fetchCapped(u, 2_000_000, /^(application\/json|text\/csv|text\/plain|application\/csv|text\/comma-separated-values|application\/octet-stream)$/);
  if (!f) throw new Error('Their feed is not JSON or CSV');
  return new TextDecoder().decode(f.bytes);
}

async function sha(s: string): Promise<string> {
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)));
  return Array.from(d.slice(0, 12), (b) => b.toString(16).padStart(2, '0')).join('');
}

async function importPhotos(list: Array<{ vehicle_id: string; urls: string[] }>, budget = 24): Promise<{ copied: number; failed: number }> {
  const s = await storage();
  let copied = 0, failed = 0;
  for (const p of list) {
    for (const url of p.urls.slice(0, 8)) {
      if (copied + failed >= budget) return { copied, failed };
      try {
        const img = await fetchCapped(url, 8_000_000, /^image\/(jpeg|png|webp)$/);
        if (!img) { failed++; continue; }
        const ext = img.type === 'image/png' ? 'png' : img.type === 'image/webp' ? 'webp' : 'jpg';
        const key = `partners/${p.vehicle_id}/${await sha(url)}.${ext}`;
        await s.put('vehicle-public', key, img.bytes, img.type);
        await rpc('server_partner_crm_photo', { p: { vehicle_id: p.vehicle_id, url, path: key, mime: img.type, bytes: img.bytes.byteLength } as unknown as Json }, SR);
        copied++;
      } catch { failed++; }
    }
  }
  return { copied, failed };
}

function absolute(u: string, site: string): string {
  return /^https?:\/\//.test(u) ? u : `${site.replace(/\/$/, '')}${u.startsWith('/') ? '' : '/'}${u}`;
}

type JobResult = { ok: boolean; busy?: boolean; error?: string; run_id?: string } & Partial<Job>;

/** One sync of one partner link (the five-minute job, or "Run sync now"). */
export async function runPartnerCrm(connectionId: string, by: string | null = null): Promise<{ ok: boolean; error: string | null; counts?: Record<string, unknown>; busy?: boolean }> {
  const job = (await rpc('server_partner_crm_job', { p_conn: connectionId, p_by: by ?? undefined, p_kind: 'sync' }, SR)) as unknown as JobResult;
  if (!job.ok) return { ok: false, busy: !!job.busy, error: job.error ?? 'Not ready' };
  let token: string | null = null;
  let report: Report | null = null;
  try {
    token = (await rpc('server_partner_crm_secret', { p_conn: connectionId }, SR)) as unknown as string | null;
    if (!token) throw new Error('No token in the vault: paste their token again');
    const ghl = crmClient({ token, locationId: job.connection!.location_id, version: job.connection!.api_version });
    const s = await storage();
    report = await runSync(job as Job, { ghl, bucketUrl: (p) => absolute(s.publicUrl(p), job.site!.url), fetchFeed });
  } catch (e) {
    report = { run_id: job.run_id!, connection_id: connectionId, kind: 'sync', ok: false, error: redact(e instanceof Error ? e.message : String(e), token ?? undefined), target: null,
      counts: {}, records: [], removed: [], inbound: null, leads: [], partner_leads: [] };
  }
  token = null;
  const done = (await rpc('server_partner_crm_done', { p: report as unknown as Json }, SR)) as unknown as { counts: Record<string, unknown>; photos: Array<{ vehicle_id: string; urls: string[] }> };
  if (done.photos?.length) {
    const ph = await importPhotos(done.photos);
    done.counts = { ...done.counts, photos_copied: ph.copied, photos_failed: ph.failed };
  }
  return { ok: report.ok, error: report.error, counts: done.counts };
}

/** Test connection: reads their location, objects, products and pipelines; never writes to their CRM. */
export async function testPartnerCrm(connectionId: string, by: string | null): Promise<{ ok: boolean; error: string | null; test?: unknown }> {
  const job = (await rpc('server_partner_crm_job', { p_conn: connectionId, p_by: by ?? undefined, p_kind: 'test' }, SR)) as unknown as JobResult;
  if (!job.ok) return { ok: false, error: job.error ?? 'Not ready' };
  let token: string | null = null;
  let out: Awaited<ReturnType<typeof testConnection>>;
  try {
    token = (await rpc('server_partner_crm_secret', { p_conn: connectionId }, SR)) as unknown as string | null;
    if (!token) throw new Error('No token in the vault: paste their token again');
    out = await testConnection(crmClient({ token, locationId: job.connection!.location_id, version: job.connection!.api_version }));
  } catch (e) {
    out = { ok: false, error: redact(e instanceof Error ? e.message : String(e), token ?? undefined), target: null, test: { location: null, checks: {}, objects: [], pipelines: [], requests: 0 } };
  }
  token = null;
  await rpc('server_partner_crm_done', { p: { run_id: job.run_id, connection_id: connectionId, kind: 'test', ok: out.ok, error: out.error, target: out.target, test: out.test, counts: { requests: out.test.requests } } as unknown as Json }, SR);
  return { ok: out.ok, error: out.error, test: out.test };
}

/** The five-minute job: every link that is due (every 15 minutes, and soon after a change). */
export async function runDuePartnerCrm(): Promise<Record<string, unknown>> {
  const due = (await rpc('server_partner_crm_due', {} as never, SR)) as unknown as string[];
  const out: Array<{ id: string; ok: boolean; error: string | null }> = [];
  for (const id of due.slice(0, 5)) {
    try { const r = await runPartnerCrm(id); out.push({ id, ok: r.ok, error: r.error }); }
    catch (e) { out.push({ id, ok: false, error: e instanceof Error ? e.message.slice(0, 200) : 'failed' }); }
  }
  return { ok: true, links: out.length, failed: out.filter((x) => !x.ok).length };
}
