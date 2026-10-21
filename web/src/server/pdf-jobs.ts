import 'server-only';
import { after } from 'next/server';
import { env } from '@/lib/env';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { workerToken } from '@/server/listing-worker';

// Signed copies in the background (migration 0075). Signing records the signatures in the database first; each
// signed copy (a PDF with the signatures and the signature record) is a job in pdf_jobs, rendered in its own Worker
// request (/api/jobs/pdf), so the person who signs never waits for it and a slow or failed render never undoes or
// hides their signature. The job is kicked right after the response; the five-minute cron runs whatever is left,
// with retries and backoff (1, 2, 5, 15 and 60 minutes; then a task for an Admin).
const SR = { role: 'service_role' as const };

export type PdfJobKind = 'owner_signed_copy' | 'sign_request_record' | 'renter_signed_copy' | 'amendment_signed_copy';
export interface PdfJobInput { kind: PdfJobKind; ref: string; owner_id?: string | null; user_id?: string | null; payload?: unknown }
export interface PdfJob { id: string; kind: PdfJobKind; ref: string; owner_id: string | null; user_id: string | null; payload: Record<string, unknown>; attempts: number }

/** Queues the jobs, then asks for them to run in their own request once this response is sent. */
export async function enqueuePdfJobs(jobs: PdfJobInput[]): Promise<void> {
  if (!jobs.length) return;
  await rpc('server_pdf_jobs_enqueue', { p: jobs as unknown as Json }, SR);
  kickPdfJobs();
}

/** Starts /api/jobs/pdf after the response: on Cloudflare through the Worker's own service binding (a separate
 *  invocation, with its own CPU and memory), elsewhere through the site's own address. A kick that fails changes
 *  nothing: the cron runs the jobs within five minutes. */
export function kickPdfJobs(): void {
  try {
    after(async () => {
      try { await callJobs(); } catch (e) { console.error('pdf jobs kick', e); }
    });
  } catch { /* outside a request (a script): the cron runs them */ }
}

async function callJobs(): Promise<void> {
  const url = `${env().NEXT_PUBLIC_APP_URL.replace(/\/$/, '')}/api/jobs/pdf`;
  const init = { method: 'POST', headers: { authorization: `Bearer ${await workerToken()}` } };
  let self: { fetch(r: Request): Promise<Response> } | undefined;
  try {
    const { getCloudflareContext } = await import('@opennextjs/cloudflare');
    self = ((await getCloudflareContext({ async: true })).env as Record<string, unknown>).WORKER_SELF_REFERENCE as typeof self;
  } catch { self = undefined; }
  const r = self ? await self.fetch(new Request(url, init)) : await fetch(url, init);
  await r.text().catch(() => undefined);
}

type Handler = (job: PdfJob) => Promise<void>;

async function handler(kind: PdfJobKind): Promise<Handler> {
  if (kind === 'owner_signed_copy') {
    const { attachOwnerSignedCopy } = await import('@/server/owner/agreements');
    return (j) => attachOwnerSignedCopy(j.owner_id!, j.user_id!, j.payload.doc as Parameters<typeof attachOwnerSignedCopy>[2]);
  }
  if (kind === 'sign_request_record') {
    const { attachSignedRecord } = await import('@/server/sign-requests');
    return (j) => attachSignedRecord(j.user_id!, j.payload.signed as Parameters<typeof attachSignedRecord>[1], (j.payload.drawn_path as string | null) ?? null);
  }
  if (kind === 'renter_signed_copy') {
    const { attachSignedCopy } = await import('@/server/portal/agreement');
    return (j) => attachSignedCopy(j.ref, j.user_id!);
  }
  const { attachSignedAmendment } = await import('@/server/portal/change');
  return (j) => attachSignedAmendment(j.ref, j.payload.request_id as string, j.user_id!);
}

/** Runs due jobs one at a time until the deadline (each render is one PDF). */
export async function runPdfJobs(o: { maxJobs?: number; deadlineMs?: number } = {}): Promise<{ done: number; failed: number; more: boolean }> {
  const start = Date.now();
  const worker = `web-${crypto.randomUUID().slice(0, 8)}`;
  let done = 0, failed = 0, more = false;
  for (let n = 0; n < (o.maxJobs ?? 2); n++) {
    if (Date.now() - start > (o.deadlineMs ?? 20_000)) { more = true; break; }
    const jobs = (await rpc('server_pdf_jobs_claim', { p_worker: worker, p_limit: 1 }, SR)) as unknown as PdfJob[];
    const job = jobs[0];
    if (!job) break;
    try {
      await (await handler(job.kind))(job);
      await rpc('server_pdf_job_done', { p_job: job.id }, SR);
      done++;
    } catch (e) {
      failed++;
      console.error('pdf job', job.kind, job.id, e);
      await rpc('server_pdf_job_fail', { p_job: job.id, p_error: e instanceof Error ? e.message : String(e) }, SR).catch(() => undefined);
    }
    if (n === (o.maxJobs ?? 2) - 1) more = true;
  }
  return { done, failed, more };
}
