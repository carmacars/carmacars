import { env } from '@/lib/env';
import { rpc } from '@/lib/db/repo';
import { payments } from '@/integrations/payments';
import { stripeEventCalls } from '@/server/stripe-events';
import { settleIntentEvent } from '@/server/intent-events';
import { reportProcessor } from '@/server/card-provider';

// Stripe webhook (docs/blueprint/13-security.md section 8). A route on the Worker rather than a
// Supabase Edge Function: the settlement code, the payments module and the signed-copy renderer live
// here. The signature is checked on the raw body (5-minute tolerance); the event id is claimed in
// webhook_events first, so a replay returns the first result; 2xx only once the event is stored.
export const dynamic = 'force-dynamic';

const SR = { role: 'service_role' as const };

export async function POST(req: Request): Promise<Response> {
  const e = env();
  // r50: with Helcim (or cards off) the Stripe account is closed: its webhook is not listened to
  if (e.PAYMENTS_PROVIDER !== 'stripe' && e.PAYMENTS_PROVIDER !== 'fake') return Response.json({ error: 'Stripe is not the card processor' }, { status: 410 });
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
    // hotfix 3650: the account stopped (or started again) taking charges: card payments follow, the Admins are alerted once
    let result: unknown = obj.object === 'account' && event.type === 'account.updated'
      ? await reportProcessor('stripe', cardFlag(obj, 'charges_enabled'), cardFlag(obj, 'payouts_enabled'), disabledReason(obj))
      : await settleIntentEvent(event.id, event.type, obj);
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

// account.updated (3650): Stripe's own flags, read from the event (no money moves on them; the next check reads the account again)
const cardFlag = (o: unknown, k: 'charges_enabled' | 'payouts_enabled') => (o as Record<string, unknown>)[k] === true;
const disabledReason = (o: unknown) => {
  const r = (o as { requirements?: { disabled_reason?: unknown } }).requirements?.disabled_reason;
  return typeof r === 'string' ? r : null;
};
