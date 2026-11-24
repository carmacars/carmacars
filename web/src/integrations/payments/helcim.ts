import type { Intent, IntentCard, IntentStatus, PaymentsAdapter, Refund } from './types';
import { cents, dollars, HelcimError, helcimApi, verifyCheckoutHash, type HelcimApi, type HelcimTransaction } from './helcim-api.ts';
import { holdWindowDays } from './provider.ts';

// r50: the Helcim adapter, beside the Stripe one (stripe.ts) behind the same PaymentsAdapter, so every money flow the site
// runs on Stripe runs on Helcim with no change to the callers:
//   - a card form (the booking's pay step, a pay link, the offer pay box, add-ons, gift cards, owner invoices by card)
//     opens HelcimPay.js with a checkout session made here; the session's checkoutToken is the "client secret" the forms
//     already pass. The modal's answer comes back to /api/payments/helcim/confirm, which checks its hash with the session's
//     secret token (never sent to the browser) and reads the transaction again from Helcim before anything is recorded.
//   - Helcim has no PaymentIntent: this adapter keeps one per payment in our database (helcim_intents, migration 3710), in
//     Stripe's words (requires_payment_method, requires_capture, succeeded, canceled), so the settle code, the webhook and
//     the Money tab read Helcim exactly as they read Stripe. Ids start hc_ (Stripe's pi_ history stays readable).
//   - Deposit holds are Helcim preauths, captured within 7 days or they expire. The hold's expiry (captureBefore) is placed
//     + 7 days, so the existing "re-authorize before it lapses" To do runs on time. A deposit for a rental longer than the
//     hold window is charged and refunded at release instead (holdPlan): Release refunds it, Capture keeps what is owed and
//     refunds the rest. The booking says so (deposits.held_as_charge).
//   - The saved card (Card on File) is Helcim's card token: off-session charges and holds use it (tolls, incidentals).
//   - Refunds: Helcim's refund, or a reverse when the batch is still open (no fee).
// Pure apart from its API client and its store (both injected: unit tested with helcim-fake.ts and a memory store).

export interface HelcimIntentRow {
  id: string;
  key: string;
  kind: 'booking' | 'addon' | 'gift' | 'invoice' | 'staff' | 'setup' | 'charge';
  capture: 'manual' | 'automatic' | 'verify';
  status: IntentStatus;
  amountCents: number;
  capturableCents: number;
  capturedCents: number;
  refundedCents: number;
  metadata: Record<string, string>;
  customerCode: string | null;
  description: string;
  checkoutToken: string | null;
  secretToken: string | null;
  tokenAt: number | null;
  transactionId: number | null;
  captureTransactionId: number | null;
  cardToken: string | null;
  card: IntentCard | null;
  lastError: string | null;
  heldAsCharge: boolean;
  placedAt: number | null;
  createdAt: number;
}

export interface HelcimStore {
  get(id: string): Promise<HelcimIntentRow | null>;
  byKey(key: string): Promise<HelcimIntentRow | null>;
  byTransaction(id: number): Promise<HelcimIntentRow | null>;
  /** the payment a HelcimPay.js session belongs to (the browser knows only its checkoutToken) */
  byCheckoutToken(token: string): Promise<HelcimIntentRow | null>;
  /** open checkout sessions of this customer and amount, newest first (a webhook for a modal the browser never confirmed) */
  openFor(customerCode: string | null, amountCents: number, sinceMs: number): Promise<HelcimIntentRow[]>;
  put(row: HelcimIntentRow): Promise<void>;
  /** the result of a call kept by its idempotency key (Helcim keeps its keys only 5 minutes; ours are kept for good) */
  callGet(key: string): Promise<unknown | null>;
  callPut(key: string, result: unknown): Promise<void>;
  /** charge: the deposit of this booking is charged and refunded at release (the rental is longer than the hold window) */
  holdPlan(bookingId: string, windowDays: number): Promise<'hold' | 'charge'>;
}

export interface HelcimOptions {
  terminalId?: number;
  now?: () => number;
  /** Helcim asks for the customer's IP on every Payment API call; the server's own calls (capture, refund, reverse, the
   *  saved card) send this one. */
  serverIp?: string;
}

const TOKEN_LIFE_MS = 55 * 60 * 1000; // a checkout session lasts 60 minutes (Helcim): renewed 5 minutes before
const DAY = 86_400_000;
const BRANDS: Record<string, string> = { VI: 'visa', MC: 'mastercard', AX: 'amex', DI: 'discover', DCI: 'diners', JCB: 'jcb', UP: 'unionpay', IN: 'interac', DB: 'debit' };

/** Helcim's card in the shape the site records (brand and last four only). Helcim does not say whether a Visa or Mastercard
 *  is a debit card: only its own debit and Interac types count as debit, so a Visa Debit passes as credit (docs/ops). */
export function cardOf(t: Partial<HelcimTransaction>): IntentCard | null {
  const num = String(t.cardNumber ?? '');
  const last4 = num.replace(/\D/g, '').slice(-4);
  if (!/^\d{4}$/.test(last4)) return null;
  const code = String(t.cardType ?? '').toUpperCase();
  const brand = BRANDS[code] ?? (String(t.cardType ?? '').toLowerCase() || 'card');
  return { brand, last4, expMonth: 0, expYear: 0, funding: code === 'DB' || code === 'IN' ? 'debit' : 'credit', name: t.cardHolderName ? String(t.cardHolderName) : null,
    fingerprint: t.cardToken ? `helcim:${String(t.cardToken).slice(-12)}` : null, country: null };
}

export function toIntent(r: HelcimIntentRow, windowDays = 7): Intent {
  const held = r.status === 'requires_capture';
  return {
    id: r.id, status: r.status, amountCents: r.amountCents, amountCapturableCents: held ? r.capturableCents : 0, currency: 'cad',
    clientSecret: r.status === 'requires_payment_method' ? r.checkoutToken : null, metadata: { ...r.metadata }, customerId: r.customerCode,
    paymentMethodId: r.cardToken, chargeId: r.captureTransactionId ? String(r.captureTransactionId) : r.transactionId ? String(r.transactionId) : null,
    card: r.card, lastError: r.lastError, methodType: 'card',
    // a preauth must be captured within the window; a deposit charged instead never lapses
    captureBefore: held && !r.heldAsCharge && r.placedAt ? Math.floor((r.placedAt + windowDays * DAY) / 1000) - 3600 : null,
    extendedAuth: false, bank: null, mandateId: null
  };
}

const notOnHelcim = (what: string) => new Error(`${what} is not available with Helcim: pay the invoice by card or by Interac e-Transfer`);

export interface HelcimAdapter extends PaymentsAdapter {
  readonly name: 'helcim';
  /** /api/payments/helcim/confirm: what the HelcimPay.js modal reported, checked by its hash and read again from Helcim. */
  confirmCheckout(id: string, message: unknown): Promise<Intent>;
  /** the payment of a checkout session (the card forms know its checkoutToken only) */
  idForCheckout(checkoutToken: string): Promise<string | null>;
  /** a new checkout session for the same payment (the modal was declined or closed: Helcim's session is used up) */
  renewCheckout(id: string): Promise<Intent>;
  /** the webhook: a card transaction Helcim reports, tied to its payment (null: not one of ours) */
  reconcile(transactionId: number): Promise<{ intent: Intent; tx: HelcimTransaction } | { intent: null; tx: HelcimTransaction | null }>;
  /** the connector: Helcim's transactions in a window, and one by id */
  transactions(q: { dateFrom: string; dateTo: string; search?: string }): Promise<HelcimTransaction[]>;
  transaction(id: number): Promise<HelcimTransaction>;
  connectionTest(): Promise<Record<string, unknown>>;
  /** a payment taken outside the site (the Helcim dashboard, a terminal), kept as a payment of ours so it can be recorded */
  adoptTransaction(tx: HelcimTransaction, metadata: Record<string, string>): Promise<Intent>;
}

export function helcimAdapter(token: string, store: HelcimStore, o: HelcimOptions = {}, f?: typeof fetch): HelcimAdapter {
  const api: HelcimApi = helcimApi(token, f);
  const now = o.now ?? (() => Date.now());
  const ip = o.serverIp ?? '';
  const window = holdWindowDays('helcim');
  const newId = () => `hc_${crypto.randomUUID().replace(/-/g, '').slice(0, 24)}`;

  async function session(r: HelcimIntentRow): Promise<HelcimIntentRow> {
    const paymentType = r.capture === 'verify' ? 'verify' : r.capture === 'manual' && !r.heldAsCharge ? 'preauth' : 'purchase';
    const s = await api.initialize({ paymentType, amount: dollars(r.amountCents), currency: 'CAD', ...(r.customerCode ? { customerCode: r.customerCode } : {}),
      ...(o.terminalId ? { terminalId: o.terminalId } : {}) });
    return { ...r, checkoutToken: s.checkoutToken, secretToken: s.secretToken, tokenAt: now() };
  }
  async function fresh(r: HelcimIntentRow): Promise<HelcimIntentRow> {
    if (r.status !== 'requires_payment_method' || (r.checkoutToken && r.tokenAt && now() - r.tokenAt < TOKEN_LIFE_MS)) return r;
    const x = await session(r);
    await store.put(x);
    return x;
  }
  async function must(id: string): Promise<HelcimIntentRow> {
    const r = await store.get(id);
    if (r) return r;
    if (/^(pi|seti|ch)_/.test(id)) throw new Error(`${id} is a Stripe payment: Stripe is not the card processor now. Handle it in the Stripe dashboard, or by e-Transfer`);
    throw new Error(`No such Helcim payment: '${id}'`);
  }
  /** a deposit (a hold for a booking) is charged instead of held when the rental outlasts the hold window */
  async function chargesInstead(capture: 'manual' | 'automatic', md: Record<string, string>): Promise<boolean> {
    const deposit = md.covers === 'deposit' || md.purpose === 'deposit_hold' || md.purpose === 'deposit';
    if (capture !== 'manual' || !deposit || !md.booking_id) return false;
    return (await store.holdPlan(md.booking_id, window)) === 'charge';
  }
  async function checkout(key: string, kind: HelcimIntentRow['kind'], capture: HelcimIntentRow['capture'], amountCents: number, customerCode: string | null,
    description: string, metadata: Record<string, string>): Promise<Intent> {
    const hit = await store.byKey(key);
    if (hit) return toIntent(await fresh(hit), window);
    const heldAsCharge = capture !== 'verify' && await chargesInstead(capture, metadata);
    const base: HelcimIntentRow = { id: newId(), key, kind, capture, status: 'requires_payment_method', amountCents, capturableCents: 0, capturedCents: 0, refundedCents: 0,
      metadata: { ...metadata, processor: 'helcim', ...(heldAsCharge ? { held_as_charge: 'true' } : {}) }, customerCode: customerCode || null, description,
      checkoutToken: null, secretToken: null, tokenAt: null, transactionId: null, captureTransactionId: null, cardToken: null, card: null, lastError: null,
      heldAsCharge, placedAt: null, createdAt: now() };
    const r = await session(base);
    await store.put(r);
    return toIntent(r, window);
  }
  /** a transaction Helcim approved, on its payment: the card, the token, and the state in Stripe's words */
  function settled(r: HelcimIntentRow, t: HelcimTransaction): HelcimIntentRow {
    const ok = String(t.status).toUpperCase() === 'APPROVED';
    if (!ok) return { ...r, lastError: 'Your card was declined.', transactionId: r.transactionId };
    const card = cardOf(t) ?? r.card;
    const base = { ...r, transactionId: t.transactionId, cardToken: t.cardToken ?? r.cardToken, card, lastError: null, placedAt: now() };
    if (r.capture === 'verify') return { ...base, status: 'succeeded' };
    if (r.capture === 'manual') return { ...base, status: 'requires_capture', capturableCents: r.amountCents, capturedCents: r.heldAsCharge ? r.amountCents : 0 };
    return { ...base, status: 'succeeded', capturedCents: r.amountCents };
  }
  const expectedType = (r: HelcimIntentRow) => (r.capture === 'verify' ? 'verify' : r.capture === 'manual' && !r.heldAsCharge ? 'preauth' : 'purchase');

  async function once<T>(key: string, run: () => Promise<T>): Promise<T> {
    const hit = await store.callGet(key);
    if (hit !== null && hit !== undefined) return hit as T;
    const out = await run();
    await store.callPut(key, out);
    return out;
  }
  async function refundTx(txId: number, amountCents: number, fullCents: number, key: string): Promise<HelcimTransaction> {
    try {
      return await api.refund({ originalTransactionId: txId, amount: dollars(amountCents), ipAddress: ip, ecommerce: true }, key);
    } catch (e) {
      // a payment still in an open batch is reversed in full instead (Helcim: no fee, it never settles)
      if (amountCents === fullCents && e instanceof HelcimError && e.status < 500) return api.reverse({ cardTransactionId: txId, ipAddress: ip, ecommerce: true }, `${key}:reverse`);
      throw e;
    }
  }

  const adapter: HelcimAdapter = {
    name: 'helcim',
    async createCustomer(r) {
      const code = `CC${(r.renterId ?? r.ownerId ?? r.idempotencyKey).replace(/[^A-Za-z0-9]/g, '').slice(0, 20).toUpperCase()}`;
      return once(`customer:${code}`, async () => {
        try { return { id: (await api.createCustomer({ customerCode: code, contactName: r.name || r.email, email: r.email })).customerCode || code }; }
        catch (e) { if (e instanceof HelcimError && /exist|taken|duplicate/i.test(e.message)) return { id: code }; throw e; }
      });
    },
    async createInvoiceIntent(r) {
      if (r.method !== 'card') throw notOnHelcim('A pre-authorized bank debit');
      return checkout(r.idempotencyKey, 'invoice', 'automatic', r.amountCents, r.customerId, r.description,
        { owner_invoice_id: r.invoiceId, invoice_number: r.invoiceNumber, owner_id: r.ownerId, purpose: 'owner_invoice' });
    },
    async createDebitSetup() { throw notOnHelcim('A pre-authorized bank debit'); },
    async retrieveDebitSetup() { throw notOnHelcim('A pre-authorized bank debit'); },
    createBookingIntent: (r) => checkout(r.idempotencyKey, 'booking', 'manual', r.amountCents, r.customerId, r.description,
      { booking_id: r.bookingId, booking_number: r.bookingNumber, offer_version: String(r.offerVersion), purpose: 'booking_total' }),
    createAddonIntent: (r) => checkout(r.idempotencyKey, 'addon', 'automatic', r.amountCents, r.customerId, r.description,
      { booking_id: r.bookingId, booking_number: r.bookingNumber, purpose: 'addon_unpaid' }),
    createGiftIntent: (r) => checkout(r.idempotencyKey, 'gift', 'automatic', r.amountCents, r.customerId, r.description, { gift_card_id: r.giftCardId, purpose: 'gift_card' }),
    createStaffIntent: (r) => checkout(r.idempotencyKey, 'staff', r.capture, r.amountCents, r.customerId, r.description, r.metadata),
    createCardSetup: (r) => checkout(r.idempotencyKey, 'setup', 'verify', 0, r.customerId, r.description, r.metadata),
    async retrieveIntent(id) { return toIntent(await fresh(await must(id)), window); },
    async retrieveCardSetup(id) { return toIntent(await fresh(await must(id)), window); },
    // Helcim has no extended authorization: a hold is a 7-day preauth, so there is nothing to step down from
    async standardHold(id) { return toIntent(await must(id), window); },

    async confirmCheckout(id, message) {
      const r = await must(id);
      if (r.status !== 'requires_payment_method') return toIntent(r, window);
      const ok = await verifyCheckoutHash(message, r.secretToken ?? '');
      if (!ok) throw new Error('The card answer did not come from Helcim for this payment');
      // the browser's word is never taken for money: the transaction is read again from Helcim
      const t = await api.transaction(String(ok.data.transactionId ?? ''));
      if (t.type !== expectedType(r)) throw new Error(`Helcim reports a ${t.type}, not the ${expectedType(r)} this payment asked for`);
      if (r.capture !== 'verify' && cents(t.amount) !== r.amountCents) throw new Error('Helcim reports another amount for this payment');
      const other = await store.byTransaction(t.transactionId);
      if (other && other.id !== r.id) throw new Error('This Helcim transaction is already recorded on another payment');
      const x = settled(r, t);
      await store.put(x);
      return toIntent(x, window);
    },
    async idForCheckout(token) { return token ? (await store.byCheckoutToken(token))?.id ?? null : null; },
    async renewCheckout(id) {
      const r = await must(id);
      if (r.status !== 'requires_payment_method') return toIntent(r, window);
      const x = await session(r);
      await store.put(x);
      return toIntent(x, window);
    },
    async reconcile(transactionId) {
      const t = await api.transaction(transactionId);
      let r = await store.byTransaction(t.transactionId);
      if (!r && String(t.status).toUpperCase() === 'APPROVED' && ['purchase', 'preauth', 'verify'].includes(t.type)) {
        // a modal paid but never confirmed by the browser (closed, lost connection): the one open session of this customer
        // and amount in the last 2 hours, and only when exactly one matches
        const open = (await store.openFor(t.customerCode || null, cents(t.amount), now() - 2 * 3600_000)).filter((x) => expectedType(x) === t.type);
        if (open.length === 1) { r = settled(open[0]!, t); await store.put(r); }
      }
      return r ? { intent: toIntent(r, window), tx: t } : { intent: null, tx: t };
    },

    async captureIntent(id, key, amountCents) {
      return once(`capture:${key}`, async () => {
        const r = await must(id);
        if (r.status === 'succeeded') return toIntent(r, window);
        if (r.status !== 'requires_capture') throw new Error(`This payment could not be captured because it has a status of ${r.status}.`);
        const amount = Math.min(amountCents ?? r.amountCents, r.amountCents);
        let x: HelcimIntentRow;
        if (r.heldAsCharge) {
          // already charged: keep what is captured, refund the rest now
          const rest = r.amountCents - amount;
          if (rest > 0 && r.transactionId) await refundTx(r.transactionId, rest, r.amountCents, `${key}:rest`);
          x = { ...r, status: 'succeeded', capturableCents: 0, capturedCents: amount, refundedCents: r.refundedCents + rest, amountCents: amount };
        } else {
          const c = await api.capture({ preAuthTransactionId: r.transactionId!, amount: dollars(amount), ipAddress: ip, ecommerce: true }, key);
          if (String(c.status).toUpperCase() !== 'APPROVED') throw new Error('Helcim did not capture this hold');
          // Helcim leaves the uncaptured part of a preauth to expire with the hold (up to 7 days)
          x = { ...r, status: 'succeeded', capturableCents: 0, capturedCents: amount, amountCents: amount, captureTransactionId: c.transactionId };
        }
        await store.put(x);
        return toIntent(x, window);
      });
    },
    async cancelIntent(id, key) {
      return once(`cancel:${key}`, async () => {
        const r = await must(id);
        if (r.status === 'canceled') return toIntent(r, window);
        if (r.status === 'succeeded') throw new Error('You cannot cancel this payment because it has a status of succeeded.');
        let note: string | null = null;
        if (r.status === 'requires_capture' && r.transactionId) {
          if (r.heldAsCharge) await refundTx(r.transactionId, r.amountCents, r.amountCents, `${key}:refund`);
          else {
            try { await api.reverse({ cardTransactionId: r.transactionId, ipAddress: ip, ecommerce: true }, key); }
            catch (e) { note = `Helcim did not reverse the hold (${e instanceof Error ? e.message.slice(0, 120) : 'error'}): it is never captured and lapses within 7 days`; }
          }
        }
        const x: HelcimIntentRow = { ...r, status: 'canceled', capturableCents: 0, refundedCents: r.heldAsCharge ? r.amountCents : r.refundedCents, lastError: note ?? r.lastError };
        await store.put(x);
        return toIntent(x, window);
      });
    },
    async chargeOffSession(r) {
      const hit = await store.byKey(r.idempotencyKey);
      if (hit) return toIntent(hit, window);
      const capture = r.capture ?? 'automatic';
      const heldAsCharge = await chargesInstead(capture, r.metadata);
      const row: HelcimIntentRow = { id: newId(), key: r.idempotencyKey, kind: 'charge', capture, status: 'requires_payment_method', amountCents: r.amountCents, capturableCents: 0,
        capturedCents: 0, refundedCents: 0, metadata: { ...r.metadata, processor: 'helcim', ...(heldAsCharge ? { held_as_charge: 'true' } : {}) }, customerCode: r.customerId || null,
        description: r.description, checkoutToken: null, secretToken: null, tokenAt: null, transactionId: null, captureTransactionId: null, cardToken: r.paymentMethodId, card: null,
        lastError: null, heldAsCharge, placedAt: null, createdAt: now() };
      const body = { ipAddress: ip, ecommerce: false, currency: 'CAD', amount: dollars(r.amountCents), ...(r.customerId ? { customerCode: r.customerId } : {}),
        ...(o.terminalId ? { terminalId: o.terminalId } : {}), cardData: { cardToken: r.paymentMethodId } };
      let x: HelcimIntentRow;
      try {
        const t = capture === 'manual' && !heldAsCharge ? await api.preauth(body, r.idempotencyKey) : await api.purchase(body, r.idempotencyKey);
        x = settled(row, t);
      } catch (e) {
        if (!(e instanceof HelcimError) || e.status >= 500) throw e;
        x = { ...row, lastError: e.message || 'Your card was declined.' };
      }
      await store.put(x);
      return toIntent(x, window);
    },
    async refund(r) {
      return once(`refund:${r.idempotencyKey}`, async (): Promise<Refund> => {
        const row = r.paymentIntentId ? await must(r.paymentIntentId) : r.chargeId && /^\d+$/.test(r.chargeId) ? await store.byTransaction(Number(r.chargeId)) : null;
        if (!row) throw new Error(r.paymentIntentId || r.chargeId ? `${r.paymentIntentId ?? r.chargeId} is not a Helcim payment: refund it where it was taken` : 'No payment to refund');
        if (row.status !== 'succeeded') throw new Error(`This payment cannot be refunded because it has a status of ${row.status}.`);
        const tx = row.captureTransactionId ?? row.transactionId;
        if (!tx) throw new Error('This payment has no Helcim transaction');
        if (r.amountCents > row.capturedCents - row.refundedCents) throw new Error('Refund amount is greater than the charge.');
        const t = await refundTx(tx, r.amountCents, row.capturedCents - row.refundedCents, `refund:${r.idempotencyKey}`);
        const ok = String(t.status).toUpperCase() === 'APPROVED';
        if (ok) await store.put({ ...row, refundedCents: row.refundedCents + r.amountCents });
        return { id: `hcr_${t.transactionId}`, status: ok ? 'succeeded' : 'failed', amountCents: r.amountCents, failureReason: ok ? null : 'Helcim declined the refund' };
      });
    },
    async verifyWebhook() { throw new Error('Helcim webhooks are received on /api/webhooks/helcim (verifyHelcimWebhook)'); },
    transactions: (q) => api.transactions({ ...q, limit: 1000 }),
    transaction: (id) => api.transaction(id),
    connectionTest: () => api.connectionTest(),
    async adoptTransaction(t, metadata) {
      const hit = await store.byTransaction(t.transactionId);
      if (hit) return toIntent(hit, window);
      const row: HelcimIntentRow = { id: newId(), key: `adopt:${t.transactionId}`, kind: 'charge', capture: t.type === 'preauth' ? 'manual' : 'automatic', status: 'requires_payment_method',
        amountCents: cents(t.amount), capturableCents: 0, capturedCents: 0, refundedCents: 0, metadata: { ...metadata, processor: 'helcim', outside_site: 'true' },
        customerCode: t.customerCode || null, description: 'Taken outside the site (Helcim)', checkoutToken: null, secretToken: null, tokenAt: null, transactionId: null,
        captureTransactionId: null, cardToken: t.cardToken ?? null, card: null, lastError: null, heldAsCharge: false, placedAt: null, createdAt: now() };
      const x = settled(row, t);
      await store.put(x);
      return toIntent(x, window);
    }
  };
  return adapter;
}

/** A store in memory, for tests and local work without a database. */
export function memoryHelcimStore(plan: (bookingId: string, windowDays: number) => 'hold' | 'charge' = () => 'hold'): HelcimStore & { rows: Map<string, HelcimIntentRow> } {
  const rows = new Map<string, HelcimIntentRow>();
  const calls = new Map<string, unknown>();
  return {
    rows,
    async get(id) { const r = rows.get(id); return r ? structuredClone(r) : null; },
    async byKey(key) { for (const r of rows.values()) if (r.key === key) return structuredClone(r); return null; },
    async byTransaction(id) { for (const r of rows.values()) if (r.transactionId === id || r.captureTransactionId === id) return structuredClone(r); return null; },
    async byCheckoutToken(t) { for (const r of rows.values()) if (r.checkoutToken === t) return structuredClone(r); return null; },
    async openFor(code, amount, since) {
      return [...rows.values()].filter((r) => r.status === 'requires_payment_method' && r.amountCents === amount && (r.customerCode ?? null) === (code ?? null) && r.createdAt >= since)
        .sort((a, b) => b.createdAt - a.createdAt).map((r) => structuredClone(r));
    },
    async put(r) { rows.set(r.id, structuredClone(r)); },
    async callGet(k) { return calls.has(k) ? structuredClone(calls.get(k)) : null; },
    async callPut(k, v) { calls.set(k, structuredClone(v)); },
    async holdPlan(b, w) { return plan(b, w); }
  };
}
