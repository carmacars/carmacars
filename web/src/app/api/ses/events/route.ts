import { rpc } from '@/lib/db/repo';
import { isSnsUrl, sesEvents, verifySns } from '@/lib/ses-sns';

// Amazon SES bounces and complaints (migration 2630, docs/email-providers.md): SES publishes them to an SNS topic and SNS
// posts them here. The signature of every message is checked first (src/lib/ses-sns.ts: certificate only from
// sns.<region>.amazonaws.com); a subscription confirmation is confirmed by fetching its SubscribeURL; a permanent bounce
// or a complaint suppresses the address for every email (app.outbox_record_bounce, idempotent) but only for an email WE sent:
// anyone can make a validly signed message from their own SNS topic, so the wrapper (2630) ignores a message id that is not
// ours (provider id ses:<id> in the outbox) or an address that email was not sent to. SNS retries a non-2xx.
export const dynamic = 'force-dynamic';

export async function POST(req: Request): Promise<Response> {
  const raw = await req.text();
  if (raw.length > 256_000) return Response.json({ error: 'too large' }, { status: 413 });
  const v = await verifySns(raw);
  if (!v.ok) return Response.json({ error: 'invalid message' }, { status: 403 });
  const m = v.message;
  try {
    if (m.Type === 'SubscriptionConfirmation') {
      if (!isSnsUrl(m.SubscribeURL)) return Response.json({ error: 'invalid subscribe URL' }, { status: 400 });
      const r = await fetch(m.SubscribeURL, { redirect: 'error', signal: AbortSignal.timeout(8000) });
      return Response.json({ confirmed: r.ok }, { status: r.ok ? 200 : 502 });
    }
    if (m.Type !== 'Notification') return Response.json({ ignored: m.Type });
    let recorded = 0;
    for (const e of sesEvents(m.Message)) {
      await rpc('server_outbox_record_bounce', { p_provider_id: e.messageId ? `ses:${e.messageId}` : 'ses:unknown', p_kind: e.kind, p_detail: e.detail, p_email: e.email }, { role: 'service_role' });
      recorded++;
    }
    return Response.json({ recorded });
  } catch {
    return Response.json({ error: 'processing failed' }, { status: 500 });
  }
}
