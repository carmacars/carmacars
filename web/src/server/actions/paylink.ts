'use server';
import type { ActionResult } from '@/features/forms/schemas';
import { env } from '@/lib/env';
import { fakeOnly, payments } from '@/integrations/payments';
import { payLinkFacts, settlePayreq, type PayLinkFacts } from '@/server/paylink';

// The pay page of a card request staff started (0129): no account needed, the link's token is the key. The renter types
// the card in Stripe's frame; the result is read again from Stripe here, never taken from the browser, and recorded.
type R<T = unknown> = ActionResult<T>;
const fail = (m: string): R<never> => ({ ok: false, code: 'refused', message: m });

export interface PayLinkStart { provider: 'stripe' | 'fake'; clientSecret: string; publishableKey: string | null; kind: PayLinkFacts['kind']; amountCents: number; legalName: string }
export async function payLinkStart(token: string): Promise<R<PayLinkStart>> {
  const f = await payLinkFacts(token);
  if (!f || f.status !== 'open' || !f.intent_id) return fail('This link is no longer open. Ask us for a new one.');
  const p = await payments();
  const i = f.kind === 'setup' ? await p.retrieveCardSetup(f.intent_id) : await p.retrieveIntent(f.intent_id);
  return { ok: true, data: { provider: p.name, clientSecret: i.clientSecret ?? '', publishableKey: env().NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY ?? null, kind: f.kind, amountCents: f.amount_cents, legalName: f.renter_name } };
}

/** The local stand-in for Stripe's frame (tests): a Stripe test card number confirms the intent. */
export async function payLinkFakeConfirm(token: string, card: { number: string; name: string; exp: string }): Promise<R<{ status: string; error: string | null }>> {
  const fake = await fakeOnly();
  const f = await payLinkFacts(token);
  if (!fake || !f?.intent_id) return fail('Not available.');
  const [mm, yy] = (card.exp ?? '').split('/').map((x) => Number(x.trim()));
  if (!mm || mm > 12 || !yy) return { ok: false, code: 'invalid', message: 'Check the expiry date (MM / YY).' };
  const r = await fake.confirm(f.intent_id, { number: card.number, name: card.name, expMonth: mm, expYear: 2000 + (yy % 100) });
  return { ok: true, data: { status: r.status, error: r.lastError } };
}

export async function payLinkFinish(token: string): Promise<R<{ ok: boolean; reason?: string }>> {
  const f = await payLinkFacts(token);
  if (!f?.intent_id) return fail('This link is no longer open.');
  if (f.status === 'paid') return { ok: true, data: { ok: true } };
  try { return { ok: true, data: await settlePayreq(f.id, f.intent_id, f.kind) }; } catch (e) { return fail(e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'We could not record the payment. Call us.'); }
}
