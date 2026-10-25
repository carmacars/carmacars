import { env } from '@/lib/env';
import { rpc } from '@/lib/db/repo';
import { payments } from '@/integrations/payments';
import { settleIntent } from '@/server/portal/payment';
import { settleAddonIntent } from '@/server/portal/addon-payment';
import { settleDebitIntent, settleInvoiceIntent, verifyDebitSetup } from '@/server/owner/payment';
import { settlePayreq } from '@/server/paylink';
import { stripeEventCalls } from '@/server/stripe-events';
import { isHoldLapse } from '@/server/money-steps';
import { runMoneyAction } from '@/server/deposit-guard';

// Stripe webhook (docs/blueprint/13-security.md section 8). A route on the Worker rather than a
// Supabase Edge Function: the settlement code, the payments module and the signed-copy renderer live
// here. The signature is checked on the raw body (5-minute tolerance); the event id is claimed in
// webhook_events first, so a replay returns the first result; 2xx only once the event is stored.
export const dynamic = 'force-dynamic';

const SR = { role: 'service_role' as const };

export async function POST(req: Request): Promise<Response> {
  const e = env();
  const secret = e.STRIPE_WEBHOOK_SECRET || (e.PAYMENTS_PROVIDER === 'fake' && e.APP_ENV !== 'production' ? 'whsec_local_fake' : '');
  const raw = await req.text();
  const p = await payments();
  let event;
  try {
    event = await p.verifyWebhook(raw, req.headers.get('stripe-signature'), secret);
  } catch {
    return Response.json({ error: 'invalid signature' }, { status: 400 });
  }
  const obj = event.object as { id?: string; object?: string; metadata?: Record<string, string> };
  const bookingId = obj.metadata?.booking_id ?? null;
  const claim = (await rpc('server_webhook_event_claim', { p_provider: 'stripe', p_event_id: event.id, p_event_type: event.type, p_booking: bookingId ?? undefined, p_summary: { object: obj.object ?? null, id: obj.id ?? null } }, SR)) as unknown as { first: boolean; processed: boolean; result: unknown };
  if (!claim.first && claim.processed) return Response.json({ received: true, replay: true, result: claim.result });

  try {
    let result: unknown = { ignored: event.type };
    if (obj.object === 'payment_intent' && obj.id && obj.metadata?.purpose === 'booking_total') {
      if (event.type === 'payment_intent.amount_capturable_updated' || event.type === 'payment_intent.succeeded') {
        // the PaymentIntent is fetched again from Stripe: the event body is never trusted for money
        result = await settleIntent(obj.id, null, event.id);
      } else if (event.type === 'payment_intent.payment_failed' || event.type === 'payment_intent.canceled') {
        result = { noted: event.type };
      }
    } else if ((obj.object === 'payment_intent' || obj.object === 'setup_intent') && obj.id && obj.metadata?.purpose === 'staff_request' && obj.metadata?.payment_request_id) {
      // a card payment, deposit hold or saved card staff started from a booking (0129), when the pay page did not finish
      if (['payment_intent.succeeded', 'payment_intent.amount_capturable_updated', 'setup_intent.succeeded'].includes(event.type)) {
        result = await settlePayreq(obj.metadata.payment_request_id, obj.id, obj.object === 'setup_intent' ? 'setup' : obj.metadata.covers === 'deposit' ? 'hold' : 'charge');
      } else if (isHoldLapse(event.type, obj as Record<string, unknown>)) {
        // a deposit hold lapsed at the bank (0155): recorded, and on a rental on the road or after it the deposit is
        // charged to the saved card (the database says so and gives the payment)
        const lapsed = (await rpc('server_deposit_hold_lapsed', { p_intent: obj.id }, SR)) as unknown as { next?: { payment_id?: string } | null };
        if (lapsed?.next?.payment_id) await runMoneyAction(lapsed.next.payment_id);
        result = lapsed;
      }
    } else if (obj.object === 'payment_intent' && obj.id && obj.metadata?.purpose === 'addon_unpaid') {
      // add-ons paid on the booking's add-on pay page (0079), when the browser did not finish
      if (event.type === 'payment_intent.succeeded') result = await settleAddonIntent(obj.id, null);
    } else if (obj.object === 'payment_intent' && obj.id && obj.metadata?.purpose === 'owner_invoice' && obj.metadata?.debit_attempt_id) {
      // the automatic monthly debit (migration 0037): the attempt settles, fails (late fee, retry or arrears) or is canceled
      if (['payment_intent.succeeded', 'payment_intent.processing', 'payment_intent.payment_failed', 'payment_intent.canceled'].includes(event.type)) {
        result = await settleDebitIntent(obj.id);
      }
    } else if (obj.object === 'mandate' && obj.id && event.type === 'mandate.updated') {
      // a pre-authorized debit agreement cancelled at the bank or by Stripe
      if ((obj as { status?: string }).status === 'inactive') result = await rpc('server_owner_mandate_inactive', { p_mandate: obj.id }, SR);
    } else if (obj.object === 'setup_intent' && obj.id && obj.metadata?.purpose === 'owner_debit_setup') {
      if (event.type === 'setup_intent.succeeded') result = await verifyDebitSetup(obj.id);
    } else if (obj.object === 'payment_intent' && obj.id && obj.metadata?.purpose === 'owner_invoice') {
      // an owner invoice: a card charge, or a pre-authorized debit submitted (processing) and settled days later
      if (['payment_intent.succeeded', 'payment_intent.processing', 'payment_intent.payment_failed', 'payment_intent.canceled'].includes(event.type)) {
        result = await settleInvoiceIntent(obj.id, null, { failedEvent: event.type === 'payment_intent.payment_failed' || event.type === 'payment_intent.canceled' });
      }
    }
    // 0132: refunds, disputes and a charge the bank wants confirmed (each recorded once by the database)
    const calls = stripeEventCalls(event.type, obj as Record<string, unknown>);
    if (calls.length) {
      const out: unknown[] = [];
      for (const c of calls) out.push(await rpc(c.fn, { p: c.p as never }, SR));
      result = out.length === 1 ? out[0] : out;
    }
    await rpc('server_webhook_event_finish', { p_provider: 'stripe', p_event_id: event.id, p_result: result as never }, SR);
    return Response.json({ received: true, result });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    await rpc('server_webhook_event_finish', { p_provider: 'stripe', p_event_id: event.id, p_error: message }, SR).catch(() => undefined);
    return Response.json({ error: 'processing failed' }, { status: 500 });
  }
}
