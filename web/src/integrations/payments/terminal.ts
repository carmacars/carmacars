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
      return toIntent(await call('POST', '/payment_intents', { amount: r.amountCents, currency: 'cad', payment_method_types: ['card_present'], capture_method: r.capture,
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
    }
  };
}
