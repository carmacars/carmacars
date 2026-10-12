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

export interface PaymentsAdapter {
  readonly name: 'stripe' | 'fake';
  /** The renter as a processor customer, so the card can be saved for later charges. */
  createCustomer(r: { email: string; name: string; renterId: string; idempotencyKey: string }): Promise<{ id: string }>;
  /** A card-only PaymentIntent with manual capture that saves the card for off-session use. */
  createBookingIntent(r: BookingIntentRequest): Promise<Intent>;
  retrieveIntent(id: string): Promise<Intent>;
  captureIntent(id: string, idempotencyKey: string): Promise<Intent>;
  /** Voids an authorization: nothing is charged. */
  cancelIntent(id: string, idempotencyKey: string): Promise<Intent>;
  /** Charges the saved Card on File (extensions, later charges). */
  chargeOffSession(r: OffSessionChargeRequest): Promise<Intent>;
  /** Checks the signature header against the raw body; throws when it does not match or is stale. */
  verifyWebhook(rawBody: string, signatureHeader: string | null, secret: string, nowSeconds?: number): Promise<WebhookEvent>;
}
