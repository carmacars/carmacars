import { env } from '@/lib/env';
import { fakeOnly } from '@/integrations/payments';

// LOCAL AND TESTS ONLY: what the bank answers days after a pre-authorized debit is submitted. The fake
// adapter's intent becomes succeeded (or returned); the test then sends Stripe's signed webhook event
// to /api/webhooks/stripe, which records it. 404 with the real processor or in production.
export const dynamic = 'force-dynamic';

export async function POST(req: Request) {
  const fake = await fakeOnly();
  if (!fake || env().APP_ENV === 'production') return new Response('Not found', { status: 404 });
  const b = (await req.json().catch(() => ({}))) as { intentId?: string; ok?: boolean; register?: { id: string; amountCents: number; metadata: Record<string, string> } };
  // an off-session debit sent by the owner-debit run (an Edge Function in production): known to this process from now on
  if (b.register) return Response.json(fake.register(b.register));
  if (!b.intentId) return Response.json({ error: 'intentId' }, { status: 400 });
  try {
    const i = await fake.settleDebit(b.intentId, b.ok);
    return Response.json({ id: i.id, status: i.status, metadata: i.metadata });
  } catch (e) {
    return Response.json({ error: e instanceof Error ? e.message : String(e) }, { status: 404 });
  }
}
