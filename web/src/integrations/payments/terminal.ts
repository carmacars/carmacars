import type { Intent } from './types';
import { formEncode, StripeError, toIntent } from './stripe.ts';

// Stripe Terminal, server-driven (0202), and the lookup of a payment taken outside the site (0201). Through fetch, no SDK,
// like stripe.ts: the server registers the S700 by the pairing code it shows, creates a card_present PaymentIntent and
// hands it to the reader (readers/{id}/process_payment_intent); the staff screen polls the PaymentIntent until the card
// is presented. No connection token is needed (that is for the SDK-driven integration). The live reader is the primary
// path; the simulated reader of Stripe's test mode (test_helpers) is used only by automated tests.
const API = 'https://api.stripe.com/v1';
const VERSION = '2025-09-30.clover';

type Obj = Record<string, unknown>;
const str = (v: unknown) => (typeof v === 'string' ? v : null);

export interface TerminalAddress { line1: string; line2?: string | null; city: string; state: string; postal_code: string; country: string }
export interface Reader { id: string; label: string | null; deviceType: string | null; serialNumber: string | null; status: string | null; location: string | null;
  action: { type: string | null; status: string | null; failureMessage: string | null } | null }

export interface TerminalAdapter {
  readonly name: 'stripe' | 'fake';
  /** A Terminal location (the reader's address), from the mailing address of Program settings. */
  createLocation(r: { displayName: string; address: TerminalAddress; idempotencyKey: string }): Promise<{ id: string }>;
  /** Registers a reader by the pairing code its screen shows. */
  registerReader(r: { registrationCode: string; label: string; location: string }): Promise<Reader>;
  retrieveReader(id: string): Promise<Reader>;
  /** A card_present PaymentIntent: manual capture for a deposit hold, and for a charge checked before it is captured. */
  createReaderIntent(r: { amountCents: number; capture: 'manual' | 'automatic'; description: string; metadata: Record<string, string>; idempotencyKey: string }): Promise<Intent>;
  /** Shows the amount on the reader and waits for the card. */
  processOnReader(readerId: string, intentId: string, idempotencyKey: string): Promise<Reader>;
  /** Stops what the reader is doing (the renter walked away, the wrong amount). */
  cancelReaderAction(readerId: string): Promise<Reader>;
  /** A payment by its id: a PaymentIntent (pi_...) or a charge (ch_..., read through its PaymentIntent). */
  lookupPayment(id: string): Promise<Intent>;
  /** r35: the succeeded charges since a time (seconds since 1970), newest first, at most `max` (the nightly unlinked check). */
  listCharges(sinceEpoch: number, max?: number): Promise<StripeCharge[]>;
}

/** r35: a charge as the nightly "unlinked Stripe payments" check keeps it: no card number, only what finds its booking. */
export interface StripeCharge { id: string; intentId: string | null; amountCents: number; refundedCents: number; currency: string; created: number; status: string;
  captured: boolean; email: string | null; name: string | null; last4: string | null; brand: string | null; description: string | null; metadata: Record<string, string> }

export function toCharge(c: Obj): StripeCharge {
  const bd = (c.billing_details && typeof c.billing_details === 'object' ? c.billing_details : {}) as Obj;
  const pmd = (c.payment_method_details && typeof c.payment_method_details === 'object' ? c.payment_method_details : {}) as Obj;
  const card = ((pmd.card ?? pmd.card_present) && typeof (pmd.card ?? pmd.card_present) === 'object' ? (pmd.card ?? pmd.card_present) : {}) as Obj;
  const n = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) ? v : 0);
  return { id: String(c.id), intentId: str(c.payment_intent) ?? str((c.payment_intent as Obj | null)?.id), amountCents: n(c.amount), refundedCents: n(c.amount_refunded),
    currency: str(c.currency) ?? 'cad', created: n(c.created), status: str(c.status) ?? 'unknown', captured: c.captured !== false,
    email: str(bd.email) ?? str(c.receipt_email), name: str(bd.name), last4: str(card.last4), brand: str(card.brand), description: str(c.description),
    metadata: (c.metadata && typeof c.metadata === 'object' ? c.metadata : {}) as Record<string, string> };
}

export function toReader(r: Obj): Reader {
  const a = r.action && typeof r.action === 'object' ? (r.action as Obj) : null;
  return { id: String(r.id), label: str(r.label), deviceType: str(r.device_type), serialNumber: str(r.serial_number), status: str(r.status),
    location: str(r.location) ?? str((r.location as Obj | null)?.id),
    action: a ? { type: str(a.type), status: str(a.status), failureMessage: str(a.failure_message) } : null };
}

export function stripeTerminal(secretKey: string, f: typeof fetch = (...a) => fetch(...a)): TerminalAdapter {
  async function call(method: 'GET' | 'POST', path: string, params: Parameters<typeof formEncode>[0] = {}, idempotencyKey?: string): Promise<Obj> {
    const body = formEncode(params);
    const url = method === 'GET' && body ? `${API}${path}?${body}` : `${API}${path}`;
    const headers: Record<string, string> = { authorization: `Bearer ${secretKey}`, 'stripe-version': VERSION };
    if (method === 'POST') headers['content-type'] = 'application/x-www-form-urlencoded';
    if (idempotencyKey) headers['idempotency-key'] = idempotencyKey;
    const res = await f(url, { method, headers, body: method === 'POST' ? body : undefined });
    const json = (await res.json()) as Obj;
    if (!res.ok) {
      const e = (json.error as Obj | undefined) ?? {};
      throw new StripeError(str(e.message) ?? `Stripe error ${res.status}`, res.status, str(e.code), str(e.decline_code));
    }
    return json;
  }
  const expand = ['payment_method', 'latest_charge'];
  return {
    name: 'stripe',
    async createLocation(r) {
      const a = r.address;
      const l = await call('POST', '/terminal/locations', { display_name: r.displayName,
        address: { line1: a.line1, ...(a.line2 ? { line2: a.line2 } : {}), city: a.city, state: a.state, postal_code: a.postal_code, country: a.country } }, r.idempotencyKey);
      return { id: String(l.id) };
    },
    async registerReader(r) {
      return toReader(await call('POST', '/terminal/readers', { registration_code: r.registrationCode, label: r.label, location: r.location }));
    },
    async retrieveReader(id) { return toReader(await call('GET', `/terminal/readers/${encodeURIComponent(id)}`)); },
    async createReaderIntent(r) {
      // a deposit hold on the reader asks for an extended authorization (up to 30 days, Stripe Terminal
      // extended authorizations); a card or account that is not eligible keeps the standard hold
      return toIntent(await call('POST', '/payment_intents', { amount: r.amountCents, currency: 'cad', payment_method_types: ['card_present'], capture_method: r.capture,
        ...(r.capture === 'manual' ? { 'payment_method_options[card_present][request_extended_authorization]': 'true' } : {}),
        description: r.description, metadata: r.metadata, expand }, r.idempotencyKey));
    },
    async processOnReader(readerId, intentId, key) {
      return toReader(await call('POST', `/terminal/readers/${encodeURIComponent(readerId)}/process_payment_intent`, { payment_intent: intentId }, key));
    },
    async cancelReaderAction(readerId) { return toReader(await call('POST', `/terminal/readers/${encodeURIComponent(readerId)}/cancel_action`)); },
    async lookupPayment(id) {
      if (/^ch_/.test(id)) {
        const ch = await call('GET', `/charges/${encodeURIComponent(id)}`);
        const pi = str(ch.payment_intent);
        if (!pi) throw new StripeError('This charge has no PaymentIntent: record it without the Stripe id', 400, 'no_intent', null);
        return toIntent(await call('GET', `/payment_intents/${encodeURIComponent(pi)}`, { expand }));
      }
      return toIntent(await call('GET', `/payment_intents/${encodeURIComponent(id)}`, { expand }));
    },
    async listCharges(since, max = 1000) {
      // 100 a page, newest first, followed by starting_after until the time or `max` is reached
      const out: StripeCharge[] = [];
      let after: string | null = null;
      for (let page = 0; page < 20 && out.length < max; page++) {
        const r = await call('GET', '/charges', { limit: 100, 'created[gte]': since, ...(after ? { starting_after: after } : {}) });
        const data = Array.isArray(r.data) ? (r.data as Obj[]) : [];
        for (const c of data) if (out.length < max) out.push(toCharge(c));
        if (r.has_more !== true || !data.length) break;
        after = String(data[data.length - 1]!.id);
      }
      return out.filter((c) => c.status === 'succeeded');
    }
  };
}
