import 'server-only';
import Stripe from 'stripe';
import type { PaymentsAdapter } from './types';

// Stripe through its fetch client, so it runs on Cloudflare Workers. Card numbers never reach the
// app: Checkout collects them, and only the processor's ids come back (docs/architecture.md section 4).
export function stripeAdapter(secretKey: string): PaymentsAdapter {
  const stripe = new Stripe(secretKey, { httpClient: Stripe.createFetchHttpClient(), maxNetworkRetries: 2 });
  return {
    name: 'stripe',
    async createCheckout(r) {
      const s = await stripe.checkout.sessions.create({
        mode: 'payment', customer_email: r.customerEmail, success_url: r.successUrl, cancel_url: r.cancelUrl,
        payment_intent_data: { setup_future_usage: 'off_session', metadata: { booking_id: r.bookingId } },
        line_items: [{ quantity: 1, price_data: { currency: r.currency, unit_amount: r.amountCents, product_data: { name: r.description } } }],
        metadata: { booking_id: r.bookingId, booking_number: r.bookingNumber }
      }, { idempotencyKey: r.idempotencyKey });
      return { id: s.id, status: s.status ?? 'open', url: s.url ?? undefined };
    },
    async placeHold(r) {
      const pi = await stripe.paymentIntents.create({
        amount: r.amountCents, currency: 'cad', customer: r.customerId, payment_method: r.paymentMethodId,
        capture_method: 'manual', confirm: true, off_session: true, metadata: { booking_id: r.bookingId, kind: 'deposit' }
      }, { idempotencyKey: r.idempotencyKey });
      return { id: pi.id, status: pi.status };
    },
    async captureHold(id, amount, key) {
      const pi = await stripe.paymentIntents.capture(id, { amount_to_capture: amount }, { idempotencyKey: key });
      return { id: pi.id, status: pi.status };
    },
    async releaseHold(id, key) {
      const pi = await stripe.paymentIntents.cancel(id, {}, { idempotencyKey: key });
      return { id: pi.id, status: pi.status };
    },
    async refund(id, amount, key) {
      const rf = await stripe.refunds.create({ payment_intent: id, amount }, { idempotencyKey: key });
      return { id: rf.id, status: rf.status ?? 'pending' };
    }
  };
}
