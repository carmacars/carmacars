import type { Intent, IntentCard, PaymentsAdapter, Refund, WebhookEvent } from './types';
import { verifyStripeSignature } from './signature.ts';

// Stripe's REST API through fetch (no SDK), so it runs unchanged in the Cloudflare Worker and can be
// tested with a mocked fetch (stripe.test.ts). Test mode on staging, live keys in production.
const API = 'https://api.stripe.com/v1';
const VERSION = '2025-09-30.clover';

type Params = Record<string, string | number | boolean | undefined | null | string[] | Record<string, string>>;

/** Stripe's form encoding: nested objects as a[b]=c, lists as a[]=x. */
export function formEncode(p: Params): string {
  const out = new URLSearchParams();
  for (const [k, v] of Object.entries(p)) {
    if (v === undefined || v === null) continue;
    if (Array.isArray(v)) for (const x of v) out.append(`${k}[]`, x);
    else if (typeof v === 'object') for (const [kk, vv] of Object.entries(v)) out.append(`${k}[${kk}]`, vv);
    else out.append(k, String(v));
  }
  return out.toString();
}

type Obj = Record<string, unknown>;
const str = (v: unknown) => (typeof v === 'string' ? v : null);
const num = (v: unknown) => (typeof v === 'number' ? v : 0);
const obj = (v: unknown): Obj | null => (v && typeof v === 'object' ? (v as Obj) : null);

export function toIntent(pi: Obj): Intent {
  const pm = obj(pi.payment_method);
  const c = obj(pm?.card);
  const charge = obj(pi.latest_charge);
  const funding = str(c?.funding);
  const acss = obj(pm?.acss_debit);
  const chargeAcss = obj(obj(charge?.payment_method_details)?.acss_debit);
  const type = str(pm?.type) ?? str(obj(charge?.payment_method_details)?.type);
  const card: IntentCard | null = c ? {
    brand: str(c.brand) ?? 'card', last4: str(c.last4) ?? '', expMonth: num(c.exp_month), expYear: num(c.exp_year),
    funding: funding === 'credit' || funding === 'debit' || funding === 'prepaid' ? funding : 'unknown',
    name: str(obj(pm?.billing_details)?.name), fingerprint: str(c.fingerprint)
  } : null;
  return {
    id: String(pi.id), status: pi.status as Intent['status'], amountCents: num(pi.amount), amountCapturableCents: num(pi.amount_capturable),
    currency: str(pi.currency) ?? 'cad', clientSecret: str(pi.client_secret), metadata: (obj(pi.metadata) ?? {}) as Record<string, string>,
    customerId: str(pi.customer) ?? str(obj(pi.customer)?.id), paymentMethodId: str(pi.payment_method) ?? str(pm?.id),
    chargeId: str(pi.latest_charge) ?? str(charge?.id), card, lastError: str(obj(pi.last_payment_error)?.message),
    methodType: type === 'card' || type === 'acss_debit' ? type : null,
    bank: acss || chargeAcss ? { name: str(acss?.bank_name) ?? str(chargeAcss?.bank_name), last4: str(acss?.last4) ?? str(chargeAcss?.last4) ?? '' } : null,
    mandateId: str(chargeAcss?.mandate) ?? str(obj(pi.mandate)?.id) ?? str(pi.mandate)
  };
}

export class StripeError extends Error {
  readonly status: number;
  readonly code: string | null;
  readonly declineCode: string | null;
  constructor(message: string, status: number, code: string | null, declineCode: string | null) {
    super(message);
    this.name = 'StripeError';
    this.status = status;
    this.code = code;
    this.declineCode = declineCode;
  }
}

export function toRefund(r: Obj): Refund {
  const st = str(r.status);
  const status: Refund['status'] = st === 'succeeded' || st === 'pending' || st === 'failed' || st === 'canceled' || st === 'requires_action' ? st : 'pending';
  return { id: String(r.id), status, amountCents: num(r.amount), failureReason: str(r.failure_reason) };
}

export function stripeAdapter(secretKey: string, f: typeof fetch = (...a) => fetch(...a)): PaymentsAdapter {
  async function call(method: 'GET' | 'POST', path: string, params: Params = {}, idempotencyKey?: string): Promise<Obj> {
    const body = formEncode(params);
    const url = method === 'GET' && body ? `${API}${path}?${body}` : `${API}${path}`;
    const headers: Record<string, string> = { authorization: `Bearer ${secretKey}`, 'stripe-version': VERSION };
    if (method === 'POST') headers['content-type'] = 'application/x-www-form-urlencoded';
    if (idempotencyKey) headers['idempotency-key'] = idempotencyKey;
    let res: Response | undefined;
    for (let attempt = 0; attempt < 3; attempt++) {
      res = await f(url, { method, headers, body: method === 'POST' ? body : undefined });
      // network-level retries only for Stripe's own transient answers; the idempotency key makes them safe
      if (res.status !== 429 && res.status < 500) break;
    }
    const json = (await res!.json()) as Obj;
    if (!res!.ok) {
      const e = obj(json.error) ?? {};
      throw new StripeError(str(e.message) ?? `Stripe error ${res!.status}`, res!.status, str(e.code), str(e.decline_code));
    }
    return json;
  }
  const expand = ['payment_method', 'latest_charge'];
  return {
    name: 'stripe',
    async createCustomer(r) {
      const metadata: Record<string, string> = {};
      if (r.renterId) metadata.renter_id = r.renterId;
      if (r.ownerId) metadata.owner_id = r.ownerId;
      const c = await call('POST', '/customers', { email: r.email, name: r.name, metadata }, r.idempotencyKey);
      return { id: String(c.id) };
    },
    async createInvoiceIntent(r) {
      const p: Params = {
        amount: r.amountCents, currency: 'cad', customer: r.customerId, setup_future_usage: 'off_session',
        payment_method_types: [r.method], description: r.description,
        metadata: { owner_invoice_id: r.invoiceId, invoice_number: r.invoiceNumber, owner_id: r.ownerId, purpose: 'owner_invoice' },
        expand
      };
      if (r.method === 'acss_debit') {
        // the debit agreement: variable amounts on a schedule (the 15th, retried on the 18th), confirmed by the owner in Stripe's form
        p['payment_method_options[acss_debit][mandate_options][payment_schedule]'] = 'interval';
        p['payment_method_options[acss_debit][mandate_options][interval_description]'] = 'On the 15th of each month for the vehicle fees on your invoice, and on the 18th when a debit is retried';
        p['payment_method_options[acss_debit][mandate_options][transaction_type]'] = r.transactionType;
        p['payment_method_options[acss_debit][verification_method]'] = 'automatic';
      }
      return toIntent(await call('POST', '/payment_intents', p, r.idempotencyKey));
    },
    async createBookingIntent(r) {
      return toIntent(await call('POST', '/payment_intents', {
        amount: r.amountCents, currency: 'cad', customer: r.customerId, capture_method: 'manual', setup_future_usage: 'off_session',
        payment_method_types: ['card'], description: r.description,
        metadata: { booking_id: r.bookingId, booking_number: r.bookingNumber, offer_version: String(r.offerVersion), purpose: 'booking_total' },
        expand
      }, r.idempotencyKey));
    },
    async retrieveIntent(id) {
      return toIntent(await call('GET', `/payment_intents/${encodeURIComponent(id)}`, { expand }));
    },
    async captureIntent(id, key) {
      return toIntent(await call('POST', `/payment_intents/${encodeURIComponent(id)}/capture`, { expand }, key));
    },
    async cancelIntent(id, key) {
      return toIntent(await call('POST', `/payment_intents/${encodeURIComponent(id)}/cancel`, { cancellation_reason: 'abandoned', expand }, key));
    },
    async chargeOffSession(r) {
      return toIntent(await call('POST', '/payment_intents', {
        amount: r.amountCents, currency: 'cad', customer: r.customerId, payment_method: r.paymentMethodId, off_session: true, confirm: true,
        description: r.description, metadata: r.metadata, expand
      }, r.idempotencyKey));
    },
    async refund(r) {
      if (!r.paymentIntentId && !r.chargeId) throw new StripeError('The payment has no processor reference', 400, 'missing_reference', null);
      const p: Params = { amount: r.amountCents, metadata: r.metadata, reason: 'requested_by_customer' };
      if (r.paymentIntentId) p.payment_intent = r.paymentIntentId; else p.charge = r.chargeId;
      return toRefund(await call('POST', '/refunds', p, r.idempotencyKey));
    },
    async verifyWebhook(rawBody, header, secret, now): Promise<WebhookEvent> {
      await verifyStripeSignature(rawBody, header, secret, now);
      const e = JSON.parse(rawBody) as Obj;
      return { id: String(e.id), type: String(e.type), created: num(e.created), object: obj(obj(e.data)?.object) ?? {} };
    }
  };
}
