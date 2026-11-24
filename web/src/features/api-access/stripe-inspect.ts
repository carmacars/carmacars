// Release 47 (2896): the connector's Stripe reads, side by side with what the site recorded. Read only: the reader given
// here only GETs (stripeReader), so nothing is ever charged, captured, refunded or changed. Only a card's brand and last
// four digits are ever returned, never a full number, a secret or a client secret. Pure apart from the reader: unit
// tested with a faked Stripe (stripe-inspect.test.ts).

export type StripeGet = (path: string, params?: Record<string, string>) => Promise<Record<string, unknown>>;
type O = Record<string, unknown>;
const o = (v: unknown): O | null => (v && typeof v === 'object' && !Array.isArray(v) ? (v as O) : null);
const arr = (v: unknown): O[] => (Array.isArray(v) ? (v.filter((x) => o(x)) as O[]) : []);
const s = (v: unknown): string | null => (typeof v === 'string' && v ? v : null);
const n = (v: unknown): number => (typeof v === 'number' && Number.isFinite(v) ? v : 0);
const iso = (sec: unknown): string | null => (typeof sec === 'number' && sec > 0 ? new Date(sec * 1000).toISOString() : null);

/** What the database gave (app.stripe_booking_recorded). */
export interface Recorded {
  booking_id: string; booking_number: string; status: string; renter_due_at_booking_cents?: number | null;
  payments: Array<{ purpose: string; kind: string; status: string; amount_cents: number; intent: string | null; charge?: string | null }>;
  holds: Array<{ status: string; amount_cents: number; hold_expires_at: string | null; intent: string | null }>;
  pay_links: Array<{ kind: string; status: string; amount_cents: number; intent: string | null; expires_at: string }>;
  intents: string[];
}

export interface StripeIntentView {
  id: string; kind: 'payment_intent' | 'setup_intent'; status: string; purpose: string | null; booking_metadata: string | null;
  amount_cents: number; amount_received_cents: number; amount_capturable_cents: number; currency: string | null; capture_method: string | null;
  created: string | null; capture_before: string | null; last_payment_error: string | null; card: string | null;
  charges: Array<{ id: string; status: string | null; captured: boolean; amount_captured_cents: number; amount_refunded_cents: number; disputed: boolean; refunds: Array<{ amount_cents: number; status: string | null }> }>;
  disputes: Array<{ id: string; amount_cents: number; status: string | null; reason: string | null }>;
  recorded: boolean;
}

/** "visa 4242": the brand and last four only. */
function cardOf(pm: O | null, charge: O | null): string | null {
  const c = o(o(pm)?.card) ?? o(o(charge?.payment_method_details)?.card);
  const last4 = s(c?.last4);
  return last4 && /^\d{4}$/.test(last4) ? `${s(c?.brand) ?? 'card'} ${last4}` : null;
}

async function intentView(get: StripeGet, id: string, rec: Recorded): Promise<StripeIntentView | null> {
  const recorded = rec.payments.some((p) => p.intent === id && (p.status === 'succeeded' || p.status === 'authorized'));
  if (id.startsWith('seti_')) {
    const si = await get(`/v1/setup_intents/${id}`, { 'expand[]': 'payment_method' }).catch(() => null);
    if (!si) return null;
    return { id, kind: 'setup_intent', status: s(si.status) ?? 'unknown', purpose: s(o(si.metadata)?.purpose), booking_metadata: s(o(si.metadata)?.booking_id) ?? s(o(si.metadata)?.booking_number),
      amount_cents: 0, amount_received_cents: 0, amount_capturable_cents: 0, currency: null, capture_method: null, created: iso(si.created), capture_before: null,
      last_payment_error: s(o(si.last_setup_error)?.message), card: cardOf(o(si.payment_method), null), charges: [], disputes: [], recorded };
  }
  const pi = await get(`/v1/payment_intents/${id}`, { 'expand[]': 'payment_method' }).catch(() => null);
  if (!pi) return null;
  const ch = await get('/v1/charges', { payment_intent: id, limit: '10', 'expand[]': 'data.refunds' }).catch(() => null);
  const charges = arr(ch?.data);
  const dz = await get('/v1/disputes', { payment_intent: id, limit: '10' }).catch(() => null);
  const latest = charges[0] ?? null;
  return {
    id, kind: 'payment_intent', status: s(pi.status) ?? 'unknown', purpose: s(o(pi.metadata)?.purpose), booking_metadata: s(o(pi.metadata)?.booking_id) ?? s(o(pi.metadata)?.booking_number),
    amount_cents: n(pi.amount), amount_received_cents: n(pi.amount_received), amount_capturable_cents: n(pi.amount_capturable), currency: s(pi.currency),
    capture_method: s(pi.capture_method), created: iso(pi.created),
    capture_before: iso(o(o(latest?.payment_method_details)?.card)?.capture_before),
    last_payment_error: s(o(pi.last_payment_error)?.message), card: cardOf(o(pi.payment_method), latest),
    charges: charges.map((c) => ({ id: String(c.id), status: s(c.status), captured: c.captured === true, amount_captured_cents: n(c.amount_captured), amount_refunded_cents: n(c.amount_refunded),
      disputed: c.disputed === true, refunds: arr(o(c.refunds)?.data).map((r) => ({ amount_cents: n(r.amount), status: s(r.status) })) })),
    disputes: arr(dz?.data).map((d) => ({ id: String(d.id), amount_cents: n(d.amount), status: s(d.status), reason: s(d.reason) })),
    recorded
  };
}

const money = (c: number) => `$${(c / 100).toFixed(2)}`;
const day = (i: string | null) => (i ? i.slice(0, 10) : 'unknown');

/** One line: what Stripe and the site say together about the booking's payment. */
export function verdict(rec: Recorded, intents: StripeIntentView[]): string {
  const pis = intents.filter((i) => i.kind === 'payment_intent');
  const disputed = pis.find((i) => i.disputes.some((d) => d.status !== 'won' && d.status !== 'lost'));
  if (disputed) return `disputed at Stripe (${disputed.id}): answer the dispute`;
  const paidNotRecorded = pis.find((i) => i.status === 'succeeded' && !i.recorded && (i.purpose ?? 'booking_total') === 'booking_total');
  if (paidNotRecorded) return `paid at Stripe but not recorded (${paidNotRecorded.id}, ${money(paidNotRecorded.amount_received_cents)}): stripe_record_paid can record it`;
  const refunded = pis.find((i) => i.charges.some((c) => c.amount_refunded_cents > 0));
  const paid = pis.find((i) => i.status === 'succeeded' && i.recorded);
  if (paid) return refunded ? `paid and recorded (${paid.id}); ${money(refunded.charges.reduce((t, c) => t + c.amount_refunded_cents, 0))} refunded` : `paid and recorded (${paid.id})`;
  const hold = pis.find((i) => i.status === 'requires_capture');
  if (hold) return `hold authorized until ${day(hold.capture_before)} (${hold.id}, ${money(hold.amount_capturable_cents)}), not captured`;
  if (pis.some((i) => i.status === 'processing')) return 'payment processing at Stripe';
  if (rec.payments.some((p) => p.status === 'succeeded' && p.purpose === 'booking_total')) return 'recorded as paid on the site, but Stripe shows no captured payment for it: check';
  const failed = pis.find((i) => i.last_payment_error);
  return failed ? `not paid (last attempt: ${failed.last_payment_error})` : 'not paid';
}

/** stripe_booking: Stripe's side, beside what the site recorded, and the verdict. */
export async function inspectBooking(get: StripeGet, rec: Recorded) {
  const ids = new Set(rec.intents.filter((i) => /^(pi|seti)_[A-Za-z0-9]{6,}$/.test(i)));
  // any PaymentIntent Stripe has for this booking that the site never noted (its metadata names the booking)
  for (const q of [`metadata['booking_id']:'${rec.booking_id}'`, `metadata['booking_number']:'${rec.booking_number}'`]) {
    const r = await get('/v1/payment_intents/search', { query: q, limit: '20' }).catch(() => null);
    for (const x of arr(r?.data)) if (typeof x.id === 'string') ids.add(x.id);
  }
  const intents = (await Promise.all([...ids].sort().map((id) => intentView(get, id, rec)))).filter((x): x is StripeIntentView => !!x);
  return { booking_number: rec.booking_number, booking_status: rec.status, verdict: verdict(rec, intents), stripe: intents,
    site: { payments: rec.payments, holds: rec.holds, pay_links: rec.pay_links } };
}

/** stripe_account: the balance, payouts and the account's open requirements. */
export async function inspectAccount(get: StripeGet) {
  const [bal, acct, po] = await Promise.all([get('/v1/balance'), get('/v1/account'), get('/v1/payouts', { limit: '10' }).catch(() => null)]);
  const per = (l: unknown) => arr(l).map((x) => ({ currency: s(x.currency), amount_cents: n(x.amount) }));
  const req = o(acct.requirements) ?? {};
  const list = (v: unknown) => (Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string') : []);
  const payouts = arr(po?.data);
  const next = payouts.filter((p) => p.status === 'pending' || p.status === 'in_transit').sort((a, b) => n(a.arrival_date) - n(b.arrival_date))[0];
  const last = payouts.find((p) => p.status === 'paid');
  const sched = o(o(o(acct.settings)?.payouts)?.schedule);
  return {
    balance: { available: per(bal.available), pending: per(bal.pending) },
    charges_enabled: acct.charges_enabled === true, payouts_enabled: acct.payouts_enabled === true,
    payout_schedule: sched ? { interval: s(sched.interval), delay_days: n(sched.delay_days) } : null,
    next_payout: next ? { id: String(next.id), amount_cents: n(next.amount), currency: s(next.currency), status: s(next.status), arrival_date: iso(next.arrival_date) } : null,
    last_payout: last ? { id: String(last.id), amount_cents: n(last.amount), currency: s(last.currency), arrival_date: iso(last.arrival_date) } : null,
    requirements: { currently_due: list(req.currently_due), past_due: list(req.past_due), eventually_due: list(req.eventually_due),
      current_deadline: iso(req.current_deadline), disabled_reason: s(req.disabled_reason), errors: arr(req.errors).map((e) => ({ requirement: s(e.requirement), reason: s(e.reason) })) }
  };
}

/** stripe_record_paid: only a PaymentIntent Stripe shows succeeded, for this booking's total, is recorded (nothing to capture). */
export function recordable(i: { status: string; metadata: Record<string, string> }, bookingId: string): string | null {
  if (i.status !== 'succeeded') return `Stripe shows this payment ${i.status}, not succeeded: nothing is recorded (and nothing is captured here)`;
  if (i.metadata.booking_id !== bookingId) return 'This PaymentIntent is not for this booking';
  if (i.metadata.purpose !== 'booking_total') return `This PaymentIntent is for ${i.metadata.purpose ?? 'something else'}, not the booking total: record it from the booking's page`;
  return null;
}

// ---------------------------------------------------------------- hotfix 3430: payments with no booking in Stripe
/** A PaymentIntent for stripe_record_paid: made for this booking's total (the webhook's path), untied (no booking in its
 *  metadata, as a card taken with Tap to Pay in the Stripe Dashboard app: linked to the booking by its amount), or refused. */
export type Tie = { kind: 'tied' } | { kind: 'untied' } | { kind: 'refused'; why: string };
export function tieOf(i: { status: string; metadata: Record<string, string> }, bookingId: string, bookingNumber: string): Tie {
  const m = i.metadata ?? {};
  const bid = m.booking_id || null;
  const bno = (m.booking_number || '').trim().toUpperCase() || null;
  if ((bid && bid !== bookingId) || (!bid && bno && bno !== bookingNumber.toUpperCase())) return { kind: 'refused', why: `This PaymentIntent is for another booking (${bno ?? bid}) in Stripe` };
  if (i.status !== 'succeeded') return { kind: 'refused', why: `Stripe shows this payment ${i.status}, not succeeded: nothing is recorded (and nothing is captured here)` };
  // no booking at all, or one this tool linked before (a retry after the database recorded it is refused there as recorded)
  if ((!bid && !bno) || m.purpose === LINKED_PURPOSE) return { kind: 'untied' };
  const no = recordable(i, bookingId);
  return no ? { kind: 'refused', why: no } : { kind: 'tied' };
}
/** The metadata set at Stripe once an untied payment is recorded: the booking, never a purpose the webhook settles. */
export const LINKED_PURPOSE = 'linked_outside';
export function linkMetadata(current: Record<string, string>, bookingId: string, bookingNumber: string): Record<string, string> {
  return { booking_id: bookingId, booking_number: bookingNumber, linked_by: 'connector', ...(current.purpose ? {} : { purpose: LINKED_PURPOSE }) };
}

export interface PlanAnswer { ok: boolean; as?: 'rental' | 'deposit' | 'rental_deposit'; rental_cents?: number; deposit_cents?: number; reason?: string; booking_number?: string }
/** The preview's words for an untied payment. */
export function untiedWillDo(pi: string, amountCents: number, bookingNumber: string, plan: PlanAnswer): string {
  const what = plan.as === 'rental' ? 'the rental and fees' : plan.as === 'deposit' ? 'the deposit (kept as captured)'
    : `the rental and fees (${money(plan.rental_cents ?? 0)}) and the deposit (${money(plan.deposit_cents ?? 0)}, kept as captured)`;
  return `${pi} (${money(amountCents)}) is untied: Stripe has no booking on it (a card taken in the Stripe Dashboard, for example Tap to Pay). It will be linked to ${bookingNumber} as ${what}: `
    + `its Stripe metadata set to ${bookingNumber} and recorded as a card payment taken in the Stripe Dashboard (Link a Stripe payment), audited. Nothing is charged, captured or refunded.`;
}

/** stripe_find_payments: one PaymentIntent, and whether the platform recorded it. */
export interface FoundPayment {
  id: string; amount_cents: number; amount_received_cents: number; currency: string | null; status: string; created: string | null;
  card: string | null; method_type: string | null; wallet: string | null; description: string | null;
  booking_metadata: string | null; recorded: boolean; recorded_on: string | null; recorded_as: string | null; no_booking: boolean; flag: string | null;
}
export type Known = Record<string, { booking_number: string | null; where: string }>;
const FIND_STATUSES = new Set(['succeeded', 'requires_capture']);
/** Stripe's PaymentIntents created in the window (100 a page, at most `pages` pages), succeeded or holding, newest first. */
export async function findPayments(get: StripeGet, w: { since: number; until: number; amount_cents?: number | null }, known: (ids: string[]) => Promise<Known>, pages = 10) {
  const all: O[] = [];
  let after: string | null = null;
  let truncated = false;
  for (let p = 0; p < pages; p++) {
    const r = await get('/v1/payment_intents', { 'created[gte]': String(w.since), 'created[lte]': String(w.until), limit: '100', 'expand[]': 'data.latest_charge', ...(after ? { starting_after: after } : {}) });
    const data = arr(r.data);
    all.push(...data);
    if (r.has_more !== true || !data.length) break;
    after = String(data[data.length - 1]!.id);
    if (p === pages - 1) truncated = true;
  }
  const hits = all.filter((x) => FIND_STATUSES.has(String(x.status)) && (!w.amount_cents || n(x.amount) === w.amount_cents));
  const k = hits.length ? await known(hits.map((x) => String(x.id))) : {};
  const payments: FoundPayment[] = hits.map((x) => {
    const ch = o(x.latest_charge);
    const pmd = o(ch?.payment_method_details);
    const c = o(pmd?.card) ?? o(pmd?.card_present) ?? o(pmd?.interac_present);
    const md = o(x.metadata) ?? {};
    const bookingMd = s(md.booking_number) ?? s(md.booking_id);
    const kn = k[String(x.id)];
    const last4 = s(c?.last4);
    const noBooking = !bookingMd;
    return {
      id: String(x.id), amount_cents: n(x.amount), amount_received_cents: n(x.amount_received), currency: s(x.currency), status: String(x.status), created: iso(x.created),
      card: last4 && /^\d{4}$/.test(last4) ? `${s(c?.brand) ?? 'card'} ${last4}` : null, method_type: s(pmd?.type) ?? (Array.isArray(x.payment_method_types) ? s(x.payment_method_types[0]) : null),
      wallet: s(o(c?.wallet)?.type), description: s(x.description), booking_metadata: bookingMd,
      recorded: !!kn, recorded_on: kn?.booking_number ?? null, recorded_as: kn?.where ?? null, no_booking: noBooking,
      flag: kn ? null : noBooking ? (x.status === 'succeeded' ? 'no booking in Stripe and not recorded: stripe_record_paid with the booking links it' : 'a hold with no booking, not recorded') : 'not recorded on the site'
    };
  });
  return { count: payments.length, untied_not_recorded: payments.filter((p) => p.no_booking && !p.recorded).length, truncated, payments };
}

/** The real reader: GET only, with the server's key. */
export function stripeReader(secretKey: string, f: typeof fetch = (...a) => fetch(...a)): StripeGet {
  return async (path, params = {}) => {
    const q = new URLSearchParams(params).toString();
    const res = await f(`https://api.stripe.com${path}${q ? `?${q}` : ''}`, { method: 'GET', headers: { authorization: `Bearer ${secretKey}` } });
    const j = (await res.json().catch(() => ({}))) as O;
    if (!res.ok) throw new Error(s(o(j.error)?.message) ?? `Stripe answered ${res.status}`);
    return j;
  };
}
