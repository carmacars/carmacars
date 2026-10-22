'use server';
import { revalidatePath } from 'next/cache';
import { DbError } from '@/lib/db/repo';
import { env } from '@/lib/env';
import { payments, fakeOnly } from '@/integrations/payments';
import type { ActionResult } from '@/features/forms/schemas';
import { bookingPath } from '@/features/portal/status';
import { findBooking, requireUser } from '@/server/portal/data';
import { addonIntent, settleAddonIntent, unpaidAddons, type AddonSettle } from '@/server/portal/addon-payment';

// The renter's add-on pay page (migration 0079): start the card form, the fake card in tests, and finalize.
type R<T = null> = ActionResult<T>;
const fail = (message: string, code = 'refused'): { ok: false; code: string; message: string } => ({ ok: false, code, message });
const dbMessage = (e: unknown) => (e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong. Please try again or call us.');

async function mine(number: string) {
  const user = await requireUser(bookingPath(number, 'addons/pay'));
  const b = await findBooking(user, number);
  if (!b) throw new DbError('Booking not found', 'P0002');
  return { userId: user.id, b };
}

export interface StartedAddonPayment { provider: 'stripe' | 'fake'; intentId: string; clientSecret: string; amountCents: number; publishableKey: string | null }

export async function startAddonPayment(number: string): Promise<R<StartedAddonPayment>> {
  try {
    const { userId, b } = await mine(number);
    const u = await unpaidAddons(b.id, userId);
    if (u.total_cents <= 0) return fail('Nothing is waiting for payment on this booking.', 'nothing_due');
    const i = await addonIntent(u, userId);
    const p = await payments();
    return { ok: true, data: { provider: p.name, intentId: i.id, clientSecret: i.clientSecret ?? '', amountCents: i.amountCents, publishableKey: env().NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY ?? null } };
  } catch (e) { return fail(dbMessage(e)); }
}

/** Fake adapter only: what Stripe's frame does in the browser. */
export async function fakeConfirmAddonCard(number: string, intentId: string, card: { number: string; name: string; exp: string }): Promise<R<{ status: string; error: string | null }>> {
  const fake = await fakeOnly();
  if (!fake) return fail('Not available.');
  try {
    const { b } = await mine(number);
    const i = await fake.retrieveIntent(intentId);
    if (i.metadata.booking_id !== b.id || i.metadata.purpose !== 'addon_unpaid') return fail('Not available.');
    const [mm, yy] = (card.exp ?? '').split('/').map((x) => Number(x.trim()));
    if (!mm || mm > 12 || !yy) return { ok: false, code: 'invalid', message: 'Check the expiry date (MM / YY).', fieldErrors: { exp: 'Use MM / YY.' } };
    const r = await fake.confirm(intentId, { number: card.number, name: card.name, expMonth: mm, expYear: 2000 + (yy % 100) });
    return { ok: true, data: { status: r.status, error: r.lastError } };
  } catch (e) { return fail(dbMessage(e)); }
}

export async function finalizeAddonPayment(number: string, intentId: string): Promise<R<AddonSettle>> {
  try {
    const { userId, b } = await mine(number);
    const i = await (await payments()).retrieveIntent(intentId);
    if (i.metadata.booking_id !== b.id) return fail('This payment is not for this booking.');
    const r = await settleAddonIntent(intentId, userId);
    revalidatePath(bookingPath(number));
    return { ok: true, data: r };
  } catch (e) { return fail(dbMessage(e)); }
}
