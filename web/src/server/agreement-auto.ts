import 'server-only';
import { rpc } from '@/lib/db/repo';
import { openAgreement } from '@/server/portal/agreement';

// Every confirmed or on-trip booking gets its rental agreement by itself (migration 0132): booking CC-10013, added by
// hand, had none because the agreement was made only when the renter first opened the signing page. The site makes it
// (and Blind Spot's, and each additional driver's link) as the renter, then the database sends the renter's "sign your
// agreement". Right after a rental is added, and on the five-minute job for anything missed. Each try is recorded.
const SR = { role: 'service_role' as const };
type Due = { booking_id: string; booking_number: string; renter_user_id: string };

export async function ensureAgreement(bookingId: string, renterUserId: string, source = 'job'): Promise<boolean> {
  try {
    await openAgreement(bookingId, renterUserId);
    await rpc('server_agreement_auto_done', { p_booking: bookingId, p_ok: true, p_source: source }, SR);
    return true;
  } catch (e) {
    await rpc('server_agreement_auto_done', { p_booking: bookingId, p_ok: false, p_error: e instanceof Error ? e.message : String(e), p_source: source }, SR).catch(() => undefined);
    return false;
  }
}

/** The bookings that still have no agreement, a few at a time (each render is a PDF). */
export async function runMissingAgreements(max = 3): Promise<{ done: number; failed: number; more: boolean }> {
  const due = ((await rpc('server_agreements_due', { p_limit: max + 1 }, SR)) as unknown as Due[]) ?? [];
  let done = 0; let failed = 0;
  for (const d of due.slice(0, max)) { if (await ensureAgreement(d.booking_id, d.renter_user_id)) done++; else failed++; }
  return { done, failed, more: due.length > max };
}

/** All the agreements' background work, one path (0132 and 0154): first the agreements' queue (a new version after a
 *  change, the check-out and check-in copies, the signed copies of a version, dispute evidence packs: someone may be
 *  waiting for them), then the bookings still without their agreement. Called by /api/jobs/agreements (the Worker's cron,
 *  when server_jobs_due says agreements) and by the PDF jobs' request (/api/jobs/pdf, kicked right after a check-out, a
 *  check-in or Make the agreements again), within its time budget. */
export async function runAgreementJobs(o: { max?: number; deadlineMs?: number; aheadSeconds?: number } = {}): Promise<{ done: number; failed: number; more: boolean }> {
  const start = Date.now();
  const max = o.max ?? 3;
  const deadline = o.deadlineMs ?? 20_000;
  const { runAgreementQueue } = await import('@/server/agreements/versions');
  const q = await runAgreementQueue({ max, deadlineMs: deadline, aheadSeconds: o.aheadSeconds });
  const left = max - q.done - q.failed;
  if (left <= 0 || Date.now() - start > deadline) return { ...q, more: true };
  const m = await runMissingAgreements(left);
  return { done: q.done + m.done, failed: q.failed + m.failed, more: q.more || m.more };
}

/** Right after a rental is added: its agreement now, unless it was signed on paper (the job catches a miss). */
export async function agreementAfterAdd(bookingId: string): Promise<void> {
  const due = ((await rpc('server_agreements_due', { p_limit: 50 }, SR).catch(() => [])) as unknown as Due[]) ?? [];
  const d = due.find((x) => x.booking_id === bookingId);
  if (d) await ensureAgreement(d.booking_id, d.renter_user_id, 'added');
}
