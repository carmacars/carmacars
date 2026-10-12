import { env } from '@/lib/env';
import { rpc } from '@/lib/db/repo';
import { payments } from '@/integrations/payments';
import { settleIntent } from '@/server/portal/payment';
import { settleInvoiceIntent } from '@/server/owner/payment';

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
    } else if (obj.object === 'payment_intent' && obj.id && obj.metadata?.purpose === 'owner_invoice') {
      // an owner invoice: a card charge, or a pre-authorized debit submitted (processing) and settled days later
      if (['payment_intent.succeeded', 'payment_intent.processing', 'payment_intent.payment_failed', 'payment_intent.canceled'].includes(event.type)) {
        result = await settleInvoiceIntent(obj.id, null, { failedEvent: event.type === 'payment_intent.payment_failed' || event.type === 'payment_intent.canceled' });
      }
    }
    await rpc('server_webhook_event_finish', { p_provider: 'stripe', p_event_id: event.id, p_result: result as never }, SR);
    return Response.json({ received: true, result });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    await rpc('server_webhook_event_finish', { p_provider: 'stripe', p_event_id: event.id, p_error: message }, SR).catch(() => undefined);
    return Response.json({ error: 'processing failed' }, { status: 500 });
  }
}
