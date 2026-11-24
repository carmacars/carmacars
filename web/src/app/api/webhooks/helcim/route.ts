import { env } from '@/lib/env';
import { rpc } from '@/lib/db/repo';
import { helcimOnly } from '@/integrations/payments';
import { verifyHelcimWebhook } from '@/integrations/payments/helcim-api';
import { settleIntentEvent } from '@/server/intent-events';

// r50: Helcim's webhook (Helcim > All Tools > Integrations > Webhooks; docs/ops/helcim-setup.md). A cardTransaction event
// carries only the transaction's id: the signature is checked on the raw body (HMAC-SHA256 with the verifier token, 5-minute
// tolerance), the event id (webhook-id) is claimed in webhook_events first so a retry returns the first result, then the
// transaction is read from Helcim's API and tied to its payment (helcim.ts reconcile). A payment the browser never
// confirmed (the modal closed after Helcim approved it) is settled here through the same steps as Stripe's webhook
// (intent-events.ts). 2xx only once the event is stored; a failure answers 500 so Helcim retries.
export const dynamic = 'force-dynamic';

const SR = { role: 'service_role' as const };

export async function POST(req: Request): Promise<Response> {
  const h = await helcimOnly();
  const secret = env().HELCIM_WEBHOOK_VERIFIER_TOKEN ?? '';
  if (!h || !secret) return Response.json({ error: 'Helcim is not connected' }, { status: 503 });
  const raw = await req.text();
  const headers = { id: req.headers.get('webhook-id'), timestamp: req.headers.get('webhook-timestamp'), signature: req.headers.get('webhook-signature') };
  try { await verifyHelcimWebhook(raw, headers, secret); } catch { return Response.json({ error: 'invalid signature' }, { status: 400 }); }
  let event: { id?: unknown; type?: unknown };
  try { event = JSON.parse(raw) as typeof event; } catch { return Response.json({ error: 'not JSON' }, { status: 400 }); }
  const type = String(event.type ?? '');
  const txId = /^\d{1,15}$/.test(String(event.id ?? '')) ? Number(event.id) : null;
  const eventId = String(headers.id);
  const claim = (await rpc('server_webhook_event_claim', { p_provider: 'helcim', p_event_id: eventId, p_event_type: type, p_summary: { object: 'card_transaction', id: txId } }, SR)) as unknown as { first: boolean; processed: boolean; result: unknown };
  if (!claim.first && claim.processed) return Response.json({ received: true, replay: true, result: claim.result });
  try {
    let result: unknown = { ignored: type };
    if (type === 'cardTransaction' && txId) {
      const r = await h.reconcile(txId);
      if (!r.intent) result = { ignored: 'not a payment of the site', transaction: txId, type: r.tx?.type ?? null, status: r.tx?.status ?? null };
      else {
        const i = r.intent;
        const setup = i.metadata.purpose === 'staff_request' && i.amountCents === 0;
        const t = i.status === 'requires_capture' ? 'payment_intent.amount_capturable_updated' : i.status === 'succeeded' ? (setup ? 'setup_intent.succeeded' : 'payment_intent.succeeded') : `payment_intent.${i.status}`;
        result = { transaction: txId, intent: i.id, status: i.status, settled: await settleIntentEvent(eventId, t, { id: i.id, object: setup ? 'setup_intent' : 'payment_intent', metadata: i.metadata }) };
      }
    }
    await rpc('server_webhook_event_finish', { p_provider: 'helcim', p_event_id: eventId, p_result: result as never }, SR);
    return Response.json({ received: true, result });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    await rpc('server_webhook_event_finish', { p_provider: 'helcim', p_event_id: eventId, p_error: message }, SR).catch(() => undefined);
    return Response.json({ error: 'processing failed' }, { status: 500 });
  }
}
