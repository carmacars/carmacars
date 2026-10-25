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
export async function runAgreementJobs(max = 3): Promise<{ done: number; failed: number; more: boolean }> {
  const due = ((await rpc('server_agreements_due', { p_limit: max + 1 }, SR)) as unknown as Due[]) ?? [];
  let done = 0; let failed = 0;
  for (const d of due.slice(0, max)) { if (await ensureAgreement(d.booking_id, d.renter_user_id)) done++; else failed++; }
  return { done, failed, more: due.length > max };
}

/** Right after a rental is added: its agreement now, unless it was signed on paper (the job catches a miss). */
export async function agreementAfterAdd(bookingId: string): Promise<void> {
  const due = ((await rpc('server_agreements_due', { p_limit: 50 }, SR).catch(() => [])) as unknown as Due[]) ?? [];
  const d = due.find((x) => x.booking_id === bookingId);
  if (d) await ensureAgreement(d.booking_id, d.renter_user_id, 'added');
}

type PeriodDue = { booking_id: string; seq: number; booking_number: string; renter_user_id: string };

/** A long rental's next period (migration 0148): lead days before it starts, a new version of the agreement (CarmaCars'
 *  and Blind Spot's) made as the renter and sent to sign, with what is due for that period. */
export async function runPeriodJobs(max = 2): Promise<{ done: number; failed: number }> {
  const due = ((await rpc('server_periods_due', { p_limit: max }, SR)) as unknown as PeriodDue[]) ?? [];
  let done = 0; let failed = 0;
  for (const d of due) {
    try {
      await rpc('server_period_begin', { p_booking: d.booking_id, p_seq: d.seq }, SR);
      await openAgreement(d.booking_id, d.renter_user_id);
      await rpc('server_period_done', { p_booking: d.booking_id, p_seq: d.seq, p_ok: true }, SR);
      done++;
      await chargePeriod(d.booking_id, d.seq).catch((e) => console.error('period charge', e));
    } catch (e) {
      await rpc('server_period_done', { p_booking: d.booking_id, p_seq: d.seq, p_ok: false, p_error: e instanceof Error ? e.message : String(e) }, SR).catch(() => undefined);
      failed++;
    }
  }
  return { done, failed };
}

type ChargeBegin = { charge: boolean; why?: string; payment_id?: string; amount_cents?: number; customer_id?: string; method_id?: string; booking_number?: string; idempotency_key?: string; reason?: string };

/** long_rental_autocharge (0148): the period's share, still open, charged to the saved card off session; the database
 *  records the result, sends the receipt, or raises a Finance task when it is declined or there is no card. */
export async function chargePeriod(bookingId: string, seq: number): Promise<boolean> {
  const b = (await rpc('server_period_charge_begin', { p_booking: bookingId, p_seq: seq }, SR)) as unknown as ChargeBegin;
  if (!b.charge || !b.payment_id) return false;
  let ok = false; let error: string | undefined; let intent: string | undefined; let charge: string | null = null;
  try {
    const { payments } = await import('@/integrations/payments');
    const i = await (await payments()).chargeOffSession({ customerId: b.customer_id!, paymentMethodId: b.method_id!, amountCents: b.amount_cents!, description: `CarmaCars booking ${b.booking_number}: ${b.reason}`,
      metadata: { booking_id: bookingId, purpose: 'period_charge', payment_id: b.payment_id, covers: 'balance' }, idempotencyKey: b.idempotency_key! });
    ok = i.status === 'succeeded'; intent = i.id; charge = i.chargeId; error = ok ? undefined : i.lastError ?? 'The card was declined.';
  } catch (e) { error = e instanceof Error ? e.message : 'The card could not be charged.'; }
  await rpc('server_period_charge_finish', { p_booking: bookingId, p_seq: seq, p_ok: ok, p_error: error, p_intent: intent, p_charge: charge ?? undefined }, SR);
  return ok;
}
