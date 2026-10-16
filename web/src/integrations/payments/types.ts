// The payments module (docs/architecture.md section 4). Card numbers never reach the app: the browser
// confirms a PaymentIntent in Stripe's own frame (Payment Element) and only processor ids come back.
// Booking payments are authorized first (manual capture) and captured only after the database has
// confirmed the booking (docs/blueprint/02-booking-and-renter.md section 2, step 9).

export interface IntentCard {
  brand: string;
  last4: string;
  expMonth: number;
  expYear: number;
  funding: 'credit' | 'debit' | 'prepaid' | 'unknown';
  name: string | null;
  fingerprint: string | null;
}

export type IntentStatus =
  | 'requires_payment_method' | 'requires_confirmation' | 'requires_action' | 'processing'
  | 'requires_capture' | 'canceled' | 'succeeded';

export interface Intent {
  id: string;
  status: IntentStatus;
  amountCents: number;
  amountCapturableCents: number;
  currency: string;
  clientSecret: string | null;
  metadata: Record<string, string>;
  customerId: string | null;
  paymentMethodId: string | null;
  chargeId: string | null;
  card: IntentCard | null;
  /** The processor's decline message, in plain words, when the last attempt failed. */
  lastError: string | null;
  /** card, or acss_debit (Canadian pre-authorized debit). */
  methodType: 'card' | 'acss_debit' | null;
  /** The bank account of a pre-authorized debit (never the full number). */
  bank: { name: string | null; last4: string } | null;
  /** The pre-authorized debit mandate the owner accepted, kept for the monthly debit. */
  mandateId: string | null;
}

/** An owner invoice paid on the pay page: automatic capture, one method chosen by the owner,
 *  the method saved for the monthly debit on the 15th. */
export interface InvoiceIntentRequest {
  invoiceId: string;
  invoiceNumber: string;
  ownerId: string;
  amountCents: number;
  customerId: string;
  method: 'card' | 'acss_debit';
  /** acss_debit: personal (an individual) or business (a corporation). */
  transactionType: 'personal' | 'business';
  /** The debit schedule in words, from Program settings (app.owner_debit_terms). */
  intervalDescription?: string;
  /** acss_debit: false is a one-time debit of this invoice only (a sporadic mandate, nothing kept for later debits). Default true. */
  recurring?: boolean;
  description: string;
  idempotencyKey: string;
}

/** A pre-authorized debit set up without a payment (Banking > Set up pre-authorized debit): a SetupIntent. */
export interface DebitSetupRequest {
  ownerId: string;
  customerId: string;
  transactionType: 'personal' | 'business';
  intervalDescription: string;
  idempotencyKey: string;
}
export interface DebitSetup {
  id: string;
  /** succeeded (verified), processing, requires_action (micro-deposits to confirm), requires_payment_method, canceled */
  status: string;
  clientSecret: string | null;
  customerId: string | null;
  paymentMethodId: string | null;
  mandateId: string | null;
  bank: { name: string | null; last4: string } | null;
  metadata: Record<string, string>;
  lastError: string | null;
}

export interface BookingIntentRequest {
  bookingId: string;
  bookingNumber: string;
  offerVersion: number;
  amountCents: number;
  customerId: string;
  description: string;
  idempotencyKey: string;
}

export interface OffSessionChargeRequest {
  customerId: string;
  paymentMethodId: string;
  amountCents: number;
  description: string;
  metadata: Record<string, string>;
  idempotencyKey: string;
}

export interface WebhookEvent {
  id: string;
  type: string;
  created: number;
  object: Record<string, unknown>;
}

/** A refund of a card payment (all or part), sent once whatever happens: the idempotency key is the refund's. */
export interface RefundRequest {
  paymentIntentId: string | null;
  chargeId: string | null;
  amountCents: number;
  idempotencyKey: string;
  metadata: Record<string, string>;
}
export interface Refund {
  id: string;
  /** succeeded, pending (the bank has not confirmed yet), failed or canceled */
  status: 'succeeded' | 'pending' | 'failed' | 'canceled' | 'requires_action';
  amountCents: number;
  failureReason: string | null;
}

export interface PaymentsAdapter {
  readonly name: 'stripe' | 'fake';
  /** The renter as a processor customer, so the card can be saved for later charges. */
  createCustomer(r: { email: string; name: string; renterId?: string; ownerId?: string; idempotencyKey: string }): Promise<{ id: string }>;
  /** An owner invoice: card or Canadian pre-authorized debit (with its mandate), saved for later debits. */
  createInvoiceIntent(r: InvoiceIntentRequest): Promise<Intent>;
  /** A SetupIntent for a pre-authorized debit mandate, with no payment. */
  createDebitSetup(r: DebitSetupRequest): Promise<DebitSetup>;
  retrieveDebitSetup(id: string): Promise<DebitSetup>;
  /** A card-only PaymentIntent with manual capture that saves the card for off-session use. */
  createBookingIntent(r: BookingIntentRequest): Promise<Intent>;
  retrieveIntent(id: string): Promise<Intent>;
  captureIntent(id: string, idempotencyKey: string): Promise<Intent>;
  /** Voids an authorization: nothing is charged. */
  cancelIntent(id: string, idempotencyKey: string): Promise<Intent>;
  /** Charges the saved Card on File (extensions, later charges). */
  chargeOffSession(r: OffSessionChargeRequest): Promise<Intent>;
  /** Refunds a card payment; a repeated call with the same key returns the same refund. */
  refund(r: RefundRequest): Promise<Refund>;
  /** Checks the signature header against the raw body; throws when it does not match or is stale. */
  verifyWebhook(rawBody: string, signatureHeader: string | null, secret: string, nowSeconds?: number): Promise<WebhookEvent>;
}
