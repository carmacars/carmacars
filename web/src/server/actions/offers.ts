'use server';
import { revalidatePath } from 'next/cache';
import { cookies } from 'next/headers';
import { DbError, rpc } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal, VA_FN_COOKIE } from '@/server/door';
import { payments } from '@/integrations/payments';
import { siteUrl } from '@/lib/site';
import { newPayToken, payTokenHash } from '@/server/pay-token';

// Offers and rentals made easy (migration 0129), through the staff door (ops calls): an offer sent without a request,
// an offer edited in place, payments by part and method, and the card actions staff start from a booking. The database
// decides who may do what and refuses with the reason, shown as written. Card numbers never reach these actions: the
// renter types the card in Stripe's frame on the pay page (/pay/<token>), on their phone or on the staff device.
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });
const SR = { role: 'service_role' as const };

async function me() {
  const user = await currentUser();
  if (!user) throw new Error('Sign in first.');
  let va: string | null = null;
  try { va = (await cookies()).get(VA_FN_COOKIE)?.value ?? null; } catch { va = null; }
  return { user, aal: await sessionAal(), va };
}
const withFn = (p: Record<string, unknown>, va: string | null) => (va ? { ...p, _va: va } : p);
function refreshAll(paths: string[]) { for (const x of paths) revalidatePath(x); }

export type OffersRead = 'offer_form' | 'offer_preview' | 'find_customers' | 'booking_money';
export async function offersRead<T = Record<string, unknown>>(what: OffersRead, p: Record<string, unknown> = {}): Promise<R<T>> {
  try { const { user, aal, va } = await me(); return { ok: true, data: await door<T>(user.id, 'ops_read', what, withFn(p, va), aal) }; } catch (e) { return fail(e); }
}

export type OffersDo = 'offer_create' | 'offer_revise' | 'record_booking_payment' | 'confirm_offline_booking' | 'deposit_return_offline' | 'payreq_cancel';
export async function offersDo<T = Record<string, unknown>>(action: OffersDo, p: Record<string, unknown> = {}, refresh: string[] = []): Promise<R<T>> {
  try {
    const { user, aal, va } = await me();
    const data = await door<T>(user.id, 'ops_do', action, withFn(p, va), aal);
    refreshAll([...refresh, '/admin/bookings', '/admin/requests', '/va/requests', '/admin/calendar']);
    return { ok: true, data };
  } catch (e) { return fail(e); }
}

const baseUrl = () => siteUrl();

export interface CardRequestResult { id: string; url: string; kind: 'charge' | 'hold' | 'setup'; amount_cents: number; sent?: { ok: boolean; to?: string; reason?: string } | null }
interface PayreqRow { id: string; kind: 'charge' | 'hold' | 'setup'; covers: string; amount_cents: number; booking_id: string; booking_number: string; vehicle_name: string;
  renter: { id: string; legal_name: string; email: string | null; mobile: string | null; customer_id: string | null } }

/** Collect a card: a payment of a part, the deposit hold, or saving the card. The renter enters the card on the pay page:
 *  on the staff device (channel device: the page opens here), or by a link texted or emailed to them. */
export async function startCardRequest(p: { booking: string; kind: 'charge' | 'hold' | 'setup'; covers?: string; amount_cents?: number | null; reason?: string; channel: 'device' | 'text' | 'email' }): Promise<R<CardRequestResult>> {
  try {
    const { user, aal, va } = await me();
    const token = newPayToken();
    const q = await door<PayreqRow>(user.id, 'ops_do', 'payreq_create', withFn({ ...p, token_sha256: await payTokenHash(token) }, va), aal);
    const pay = await payments();
    const customerId = q.renter.customer_id ?? (await pay.createCustomer({ email: q.renter.email ?? '', name: q.renter.legal_name, renterId: q.renter.id, idempotencyKey: `customer:${q.renter.id}` })).id;
    const metadata = { booking_id: q.booking_id, booking_number: q.booking_number, purpose: 'staff_request', payment_request_id: q.id, covers: q.covers };
    const intent = q.kind === 'setup'
      ? await pay.createCardSetup({ customerId, description: `CarmaCars booking ${q.booking_number}: card on file`, metadata, idempotencyKey: `payreq:${q.id}` })
      : await pay.createStaffIntent({ amountCents: q.amount_cents, customerId, capture: q.kind === 'hold' ? 'manual' : 'automatic',
          description: `CarmaCars booking ${q.booking_number}: ${q.kind === 'hold' ? 'deposit hold' : p.reason || q.covers}`, metadata, idempotencyKey: `payreq:${q.id}` });
    await rpc('server_payreq_attach', { p_id: q.id, p_intent: intent.id }, SR);
    const url = `${baseUrl()}/pay/${token}`;
    let sent: CardRequestResult['sent'] = null;
    if (p.channel === 'text' || p.channel === 'email') sent = await door<{ ok: boolean; to?: string; reason?: string }>(user.id, 'ops_do', 'payreq_send', withFn({ id: q.id, link: url }, va), aal);
    refreshAll([`/admin/bookings/${q.booking_number}`, `/va/bookings/${q.booking_number}`]);
    // the device: the page opens on this screen, by its path (the same origin as the staff portal)
    return { ok: true, data: { id: q.id, url: p.channel === 'device' ? `/pay/${token}` : url, kind: q.kind, amount_cents: q.amount_cents, sent } };
  } catch (e) { return fail(e); }
}

/** Charge the saved card (Finance, an Admin): a later charge with its reason, or the deposit of a long rental. */
export async function chargeSavedCard(p: { booking: string; amount_cents?: number | null; reason: string; covers?: 'later' | 'deposit' | 'rental' | 'fees' }): Promise<R<{ ok: boolean; message?: string }>> {
  try {
    const { user, aal, va } = await me();
    const b = await door<{ payment_id: string; amount_cents: number; customer_id: string; method_id: string; booking_id: string; booking_number: string; reason: string; covers: string; idempotency_key: string }>(
      user.id, 'ops_do', 'card_charge_begin', withFn(p, va), aal);
    let ok = false; let message: string | undefined; let intentId: string | undefined; let chargeId: string | null = null;
    try {
      const i = await (await payments()).chargeOffSession({ customerId: b.customer_id, paymentMethodId: b.method_id, amountCents: b.amount_cents, description: `CarmaCars booking ${b.booking_number}: ${b.reason}`,
        metadata: { booking_id: b.booking_id, purpose: 'staff_charge', payment_id: b.payment_id, covers: b.covers }, idempotencyKey: b.idempotency_key });
      ok = i.status === 'succeeded'; intentId = i.id; chargeId = i.chargeId; message = ok ? undefined : i.lastError ?? 'The card was declined.';
    } catch (e) { message = e instanceof Error ? e.message : 'The card could not be charged.'; }
    await door(user.id, 'ops_do', 'card_charge_finish', withFn({ payment: b.payment_id, ok, error: message, intent_id: intentId, charge_id: chargeId, reason: b.reason }, va), aal);
    refreshAll([`/admin/bookings/${b.booking_number}`, `/va/bookings/${b.booking_number}`]);
    return { ok: true, data: { ok, message } };
  } catch (e) { return fail(e); }
}

/** A deposit hold: capture all or part (with the reason), or release it. */
export async function holdAction(p: { booking: string; action: 'capture' | 'release'; amount_cents?: number | null; reason?: string }): Promise<R<{ ok: boolean; message?: string }>> {
  try {
    const { user, aal, va } = await me();
    const b = await door<{ deposit_id: string; intent_id: string; amount_cents: number; action: string; idempotency_key: string; booking_id: string }>(user.id, 'ops_do', 'hold_action_begin', withFn(p, va), aal);
    let ok = false; let message: string | undefined;
    try {
      const pay = await payments();
      const i = p.action === 'capture' ? await pay.captureIntent(b.intent_id, b.idempotency_key, b.amount_cents) : await pay.cancelIntent(b.intent_id, b.idempotency_key);
      ok = p.action === 'capture' ? i.status === 'succeeded' : i.status === 'canceled';
      message = ok ? undefined : i.lastError ?? `Stripe answered ${i.status}`;
    } catch (e) { message = e instanceof Error ? e.message : 'Stripe refused.'; }
    await door(user.id, 'ops_do', 'hold_action_finish', withFn({ deposit: b.deposit_id, action: p.action, amount_cents: b.amount_cents, ok, error: message, reason: p.reason }, va), aal);
    refreshAll(['/admin/bookings', '/va/bookings']);
    return { ok: true, data: { ok, message } };
  } catch (e) { return fail(e); }
}
