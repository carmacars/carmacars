import { handleQuoWebhook } from '@/server/phone';

// Quo (formerly OpenPhone) webhook, migration 0085: every call and text on the CarmaCars number. The signature is
// checked on the raw body before anything is read (src/features/phone/webhook.ts); a delivery Quo retries is applied
// once (phone_webhook_log). Quo wants a 2xx within 10 seconds: the work is one database call and, for a missed call
// with the text-back switched on, one text.
export const dynamic = 'force-dynamic';

export async function POST(req: Request): Promise<Response> {
  const raw = await req.text();
  if (raw.length > 256_000) return Response.json({ error: 'too large' }, { status: 413 });
  try {
    const r = await handleQuoWebhook(raw, (n) => req.headers.get(n));
    return Response.json(r.body, { status: r.status });
  } catch {
    // Quo retries a failed delivery (8 times over about a day)
    return Response.json({ error: 'processing failed' }, { status: 500 });
  }
}
