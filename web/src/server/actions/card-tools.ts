'use server';
import { revalidatePath } from 'next/cache';
import { cookies } from 'next/headers';
import { DbError, rpc } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal, VA_FN_COOKIE } from '@/server/door';
import { payments, terminal, type Intent } from '@/integrations/payments';
import { newPayToken, payTokenHash } from '@/server/pay-token';
import { settlePayreq } from '@/server/paylink';
import { parseCaAddress } from '@/features/terminal/address';

// Cards taken outside the pay page (Release 21): a card payment recorded by hand from the Stripe Dashboard or a reader
// (0201), the Stripe Terminal S700 driven from the server (0202), and the same-card rule of a card-coverage rental (0203).
// The database decides who may do what and refuses with the reason, shown as written. No card number reaches this code.
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
const refresh = (n?: string) => { for (const x of ['/admin/bookings', '/staff/bookings', ...(n ? [`/admin/bookings/${n}`, `/staff/bookings/${n}`] : [])]) revalidatePath(x); };
/** The caller may see this booking's money (the same read as the booking page), before anything is read at Stripe. */
async function mayHandle(booking: string) {
  const m = await me();
  await door(m.user.id, 'ops_read', 'booking_money', withFn({ booking }, m.va), m.aal);
  return m;
}

export interface Verified { intent_id: string; charge_id: string | null; status: string; amount_cents: number; capturable_cents: number; last4: string | null; brand: string | null; fingerprint: string | null; capture_before: number | null }
const verified = (i: Intent): Verified => ({ intent_id: i.id, charge_id: i.chargeId, status: i.status, amount_cents: i.amountCents, capturable_cents: i.amountCapturableCents,
  last4: i.card?.last4 ?? null, brand: i.card?.brand ?? null, fingerprint: i.card?.fingerprint ?? null, capture_before: i.captureBefore ?? null });

/** Look a payment up at Stripe by its id (pi_... or ch_...), to check what was typed. */
export async function lookupStripePayment(p: { booking: string; id: string }): Promise<R<Omit<Verified, 'fingerprint'>>> {
  try {
    await mayHandle(p.booking);
    const id = p.id.trim();
    if (!/^(pi|ch)_[A-Za-z0-9_]{6,}$/.test(id)) return { ok: false, code: 'refused', message: 'A Stripe payment id starts with pi_ (the payment) or ch_ (the charge).' };
    const { fingerprint: _f, ...v } = verified(await (await terminal()).lookupPayment(id));
    return { ok: true, data: v };
  } catch (e) { return fail(e); }
}

/** Record card payment (0201): { booking, covers, amount_cents, last4, brand, source, stripe_id, received_on, note, same_card } */
export async function recordCardPayment(p: Record<string, unknown> & { booking: string; stripe_id?: string | null }): Promise<R<{ confirmed?: boolean; held?: boolean }>> {
  try {
    const { user, aal, va } = await mayHandle(p.booking);
    const sid = typeof p.stripe_id === 'string' && p.stripe_id.trim() ? p.stripe_id.trim() : null;
    const v = sid ? verified(await (await terminal()).lookupPayment(sid)) : null;
    const data = await door<{ confirmed?: boolean; held?: boolean }>(user.id, 'ops_do', 'record_card_payment', withFn({ ...p, stripe_id: sid, verified: v }, va), aal);
    refresh(p.booking);
    return { ok: true, data };
  } catch (e) { return fail(e); }
}

/** An Admin allows another card or method on a card-coverage rental (0203): { booking, reason } */
export async function allowOtherCard(p: { booking: string; reason: string }): Promise<R> {
  try {
    const { user, aal } = await me();
    await door(user.id, 'ops_do', 'card_coverage_override', p, aal);
    refresh(p.booking);
    return { ok: true, data: {} };
  } catch (e) { return fail(e); }
}

// ---------------------------------------------------------------- the reader (0202)
interface ReaderReq { id: string; kind: 'charge' | 'hold'; covers: string; amount_cents: number; status: string; last_error: string | null; intent_id: string | null; reader: string | null;
  reader_label: string | null; booking_id: string; booking_number: string; payment_id: string | null }
export interface ReaderState { id: string; state: 'waiting' | 'done' | 'failed'; message?: string; amount_cents: number; kind: 'charge' | 'hold'; reader_label: string | null }

/** Charge on reader or Hold deposit on reader: the amount shows on the reader, the renter taps or inserts the card. */
export async function startOnReader(p: { booking: string; kind: 'charge' | 'hold'; covers?: string; amount_cents?: number | null; reason?: string; reader?: string | null }): Promise<R<ReaderState>> {
  try {
    const { user, aal, va } = await me();
    const q = await door<{ id: string; kind: 'charge' | 'hold'; covers: string; amount_cents: number; booking_id: string; booking_number: string; reader: { stripe_reader_id: string; label: string } }>(
      user.id, 'ops_do', 'payreq_create', withFn({ ...p, channel: 'reader', token_sha256: await payTokenHash(newPayToken()) }, va), aal);
    const t = await terminal();
    try {
      // manual capture both ways: a hold waits for Settle the deposit; a charge is checked (the same card, 0203), then captured
      const intent = await t.createReaderIntent({ amountCents: q.amount_cents, capture: 'manual',
        description: `CarmaCars booking ${q.booking_number}: ${q.kind === 'hold' ? 'deposit hold' : p.reason || q.covers}`,
        metadata: { booking_id: q.booking_id, booking_number: q.booking_number, purpose: 'staff_request', payment_request_id: q.id, covers: q.covers, channel: 'reader' },
        idempotencyKey: `payreq:${q.id}` });
      await rpc('server_payreq_attach', { p_id: q.id, p_intent: intent.id }, SR);
      await t.processOnReader(q.reader.stripe_reader_id, intent.id, `process:${q.id}`);
    } catch (e) {
      await rpc('server_payreq_reader_fail', { p_id: q.id, p_reason: e instanceof Error ? e.message : 'The reader could not start' }, SR);
      throw e;
    }
    refresh(q.booking_number);
    return { ok: true, data: { id: q.id, state: 'waiting', amount_cents: q.amount_cents, kind: q.kind, reader_label: q.reader.label } };
  } catch (e) { return fail(e); }
}

async function readerReq(id: string): Promise<ReaderReq> {
  const q = (await rpc('server_payreq_reader', { p_id: id }, SR)) as unknown as ReaderReq | null;
  if (!q) throw new Error('That reader payment is not found.');
  return q;
}

/** What the reader did: waiting for the card, done (recorded), or failed with the reason. Polled by the booking screen. */
export async function pollReader(p: { id: string; booking: string }): Promise<R<ReaderState>> {
  try {
    await mayHandle(p.booking);
    const q = await readerReq(p.id);
    const base = { id: q.id, amount_cents: q.amount_cents, kind: q.kind, reader_label: q.reader_label };
    if (q.status === 'paid') return { ok: true, data: { ...base, state: 'done' } };
    if (q.status !== 'open') return { ok: true, data: { ...base, state: 'failed', message: q.last_error ?? 'Not paid.' } };
    if (!q.intent_id || !q.reader) return { ok: true, data: { ...base, state: 'waiting' } };
    const t = await terminal();
    const pay = await payments();
    const i = await pay.retrieveIntent(q.intent_id);
    const failNow = async (message: string) => {
      await rpc('server_payreq_reader_fail', { p_id: q.id, p_reason: message }, SR);
      refresh(q.booking_number);
      return { ok: true as const, data: { ...base, state: 'failed' as const, message } };
    };
    if (i.status === 'canceled') return failNow(i.lastError ?? 'Cancelled on the reader.');
    if (i.status !== 'requires_capture' && i.status !== 'succeeded') {
      const r = await t.retrieveReader(q.reader).catch(() => null);
      if (r?.action?.status === 'failed') return failNow(r.action.failureMessage ?? 'The reader declined the card.');
      return { ok: true, data: { ...base, state: 'waiting' } };
    }
    if (q.kind === 'charge' && i.status === 'requires_capture') {
      // the card is read: the same card on a card-coverage rental (0203), then the money is taken
      const card = i.card ? { last4: i.card.last4, brand: i.card.brand, fingerprint: i.card.fingerprint } : {};
      const c = (await rpc('server_payreq_card_check', { p_id: q.id, p_card: card }, SR)) as unknown as { ok: boolean; reason?: string };
      if (!c.ok) { await pay.cancelIntent(i.id, `cancel:${q.id}`).catch(() => undefined); return failNow(c.reason ?? 'This card cannot pay the rental.'); }
      await pay.captureIntent(i.id, `capture:${q.id}`);
    }
    const s = await settlePayreq(q.id, i.id, q.kind);
    refresh(q.booking_number);
    return { ok: true, data: s.ok ? { ...base, state: 'done' } : { ...base, state: 'failed', message: s.reason ?? 'Not recorded.' } };
  } catch (e) { return fail(e); }
}

/** Stop the reader (the renter walked away, the wrong amount): nothing is charged. */
export async function cancelOnReader(p: { id: string; booking: string }): Promise<R> {
  try {
    await mayHandle(p.booking);
    const q = await readerReq(p.id);
    if (q.reader) await (await terminal()).cancelReaderAction(q.reader).catch(() => undefined);
    if (q.intent_id) await (await payments()).cancelIntent(q.intent_id, `cancel:${q.id}`).catch(() => undefined);
    await rpc('server_payreq_reader_fail', { p_id: q.id, p_reason: 'Cancelled by staff' }, SR);
    refresh(q.booking_number);
    return { ok: true, data: {} };
  } catch (e) { return fail(e); }
}

// ---------------------------------------------------------------- Admin: Pair reader
interface TerminalStateRow { mailing_address: string | null; location: { stripe_location_id: string } | null }

/** Pair reader: the pairing code the S700 shows (three words) and a name. The Terminal location is made from the
 *  mailing address the first time. */
export async function pairReader(p: { code: string; label: string }): Promise<R<{ label: string }>> {
  try {
    const { user, aal } = await me();
    const st = await door<TerminalStateRow>(user.id, 'ops_read', 'terminal_state', {}, aal);
    const t = await terminal();
    let location = st.location?.stripe_location_id ?? null;
    if (!location) {
      const address = parseCaAddress(st.mailing_address);
      if (!address) return { ok: false, code: 'refused', message: 'Set the mailing address in Site settings as street, city, province and postal code (for example 1 Example St, Toronto, ON A1A 1A1): the reader is registered there.' };
      location = (await t.createLocation({ displayName: 'CarmaCars', address, idempotencyKey: `terminal-location:${st.mailing_address}` })).id;
      await door(user.id, 'admin_do', 'terminal_location_save', { stripe_location_id: location, display_name: 'CarmaCars', address: st.mailing_address }, aal);
    }
    const code = p.code.trim().toLowerCase().replace(/\s+/g, '-');
    const label = p.label.trim() || 'Front desk';
    const r = await t.registerReader({ registrationCode: code, label, location });
    await door(user.id, 'admin_do', 'terminal_reader_save', { stripe_reader_id: r.id, label, device_type: r.deviceType, serial_number: r.serialNumber, stripe_location_id: location }, aal);
    revalidatePath('/admin/settings/card-reader');
    return { ok: true, data: { label } };
  } catch (e) { return fail(e); }
}

export async function removeReader(p: { id: string }): Promise<R> {
  try {
    const { user, aal } = await me();
    await door(user.id, 'admin_do', 'terminal_reader_remove', p, aal);
    revalidatePath('/admin/settings/card-reader');
    return { ok: true, data: {} };
  } catch (e) { return fail(e); }
}
