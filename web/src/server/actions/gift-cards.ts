'use server';
import { cardOffMessage } from '@/server/card-provider';
import { revalidatePath } from 'next/cache';
import { DbError, rpc } from '@/lib/db/repo';
import { env } from '@/lib/env';
import { payments, fakeOnly } from '@/integrations/payments';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { findBooking } from '@/server/portal/data';
import { giftIntent, settleGiftIntent, type GiftOrder, type GiftSettle } from '@/server/gift-cards';
import { amountProblem, emailOk, normCode, sendDateProblem, type BookingGiftState, type GiftCardRow } from '@/features/gift-cards/model';
import { bookingPath } from '@/features/portal/status';

// Gift cards (migration 3600): buying one on /gift-cards, adding a code to the account, and using the balance on Sign and
// pay. Every call names the signed-in person; the database checks everything again (amounts, who may use a card, what is
// due) and its words are shown as written. While an Admin views as someone, nothing is changed (src/lib/db/repo.ts).
const SR = { role: 'service_role' as const };
type R<T = null> = ActionResult<T>;
const fail = (message: string, code = 'refused', fieldErrors?: Record<string, string>): { ok: false; code: string; message: string; fieldErrors?: Record<string, string> } => ({ ok: false, code, message, fieldErrors });
const dbMessage = (e: unknown) => (e instanceof DbError ? e.message : 'Something went wrong. Please try again or call us.');
const torontoToday = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());

export interface GiftInput {
  kind: 'purchased' | 'gifted_rental'; amount_cents?: number | null; vehicle_id?: string | null; days?: number | null;
  recipient_name: string; recipient_email: string; message?: string; send_on?: string; buyer_name?: string;
}
export interface StartedGift { id: string; provider: 'stripe' | 'fake'; intentId: string; clientSecret: string; amountCents: number; publishableKey: string | null; rentalText: string | null }

/** The gifted rental's price for a car and a number of days (the site's own quote). */
export async function giftRentalPrice(vehicleId: string, days: number): Promise<R<{ amount_cents: number | null; car: string; days: number } | null>> {
  if (!/^[0-9a-f-]{36}$/.test(vehicleId) || !Number.isInteger(days)) return fail('Choose a car and a number of days.', 'invalid');
  try {
    return { ok: true, data: (await rpc('server_gift_rental_price', { p_vehicle: vehicleId, p_days: days }, SR)) as unknown as { amount_cents: number | null; car: string; days: number } | null };
  } catch (e) { return fail(dbMessage(e)); }
}

/** The order and its card form. Signed in only (a gift card is money: the buyer is known). */
export async function startGiftPurchase(input: GiftInput): Promise<R<StartedGift>> {
  const user = await currentUser();
  if (!user) return fail('Sign in to buy a gift card.', 'sign_in');
  // hotfix 3650: card payments paused: gift cards are sold by card only
  if (await cardOffMessage()) return fail('Gift cards are paid by card, and card payments are paused for a short while. Please try again later, or call us.', 'card_off');
  const fe: Record<string, string> = {};
  if (!input.recipient_name?.trim()) fe.recipient_name = 'Enter the recipient\'s name.';
  if (!emailOk(input.recipient_email)) fe.recipient_email = 'Enter the recipient\'s email.';
  if ((input.message ?? '').length > 500) fe.message = '500 characters at most.';
  const when = sendDateProblem(input.send_on ?? '', torontoToday());
  if (when) fe.send_on = when;
  if (input.kind === 'purchased') { const a = amountProblem(input.amount_cents ?? null, 100, 10_000_000); if (a) fe.amount = a; }
  else if (!input.vehicle_id || !input.days) fe.vehicle = 'Choose a car and the number of days.';
  if (Object.keys(fe).length) return fail('Check the highlighted fields.', 'invalid', fe);
  try {
    const o = (await rpc('server_gift_order_create', { p_by: user.id, p: {
      kind: input.kind, amount_cents: input.amount_cents ?? null, vehicle_id: input.vehicle_id ?? null, days: input.days ?? null,
      recipient_name: input.recipient_name.trim().slice(0, 120), recipient_email: input.recipient_email.trim().toLowerCase(),
      message: (input.message ?? '').trim().slice(0, 500), send_on: input.send_on || null, buyer_name: (input.buyer_name ?? '').trim().slice(0, 120) || null
    } }, SR)) as unknown as GiftOrder;
    const i = await giftIntent(o, user.id);
    const p = await payments();
    return { ok: true, data: { id: o.id, provider: p.name, intentId: i.id, clientSecret: i.clientSecret ?? '', amountCents: i.amountCents, publishableKey: env().NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY ?? null, rentalText: o.rental_text } };
  } catch (e) { return fail(dbMessage(e)); }
}

/** Fake adapter only: what Stripe's frame does in the browser. */
export async function fakeConfirmGift(id: string, intentId: string, card: { number: string; name: string; exp: string }): Promise<R<{ status: string; error: string | null }>> {
  const fake = await fakeOnly();
  if (!fake) return fail('Not available.');
  const user = await currentUser();
  if (!user) return fail('Sign in to buy a gift card.', 'sign_in');
  try {
    const i = await fake.retrieveIntent(intentId);
    if (i.metadata.gift_card_id !== id) return fail('Not available.');
    const [mm, yy] = (card.exp ?? '').split('/').map((x) => Number(x.trim()));
    if (!mm || mm > 12 || !yy) return { ok: false, code: 'invalid', message: 'Check the expiry date (MM / YY).', fieldErrors: { exp: 'Use MM / YY.' } };
    const r = await fake.confirm(intentId, { number: card.number, name: card.name, expMonth: mm, expYear: 2000 + (yy % 100) });
    return { ok: true, data: { status: r.status, error: r.lastError } };
  } catch (e) { return fail(dbMessage(e)); }
}

/** After the browser confirmed the card: the database activates the card and sends the emails. */
export async function finishGiftPurchase(id: string, intentId: string): Promise<R<GiftSettle>> {
  const user = await currentUser();
  if (!user) return fail('Sign in to buy a gift card.', 'sign_in');
  try {
    const mineOrder = (await rpc('server_gift_order_of', { p_id: id, p_by: user.id }, SR)) as unknown as { stripe_intent_id: string | null } | null;
    if (!mineOrder || mineOrder.stripe_intent_id !== intentId) return fail('This payment is not for this gift card.');
    const r = await settleGiftIntent(intentId);
    revalidatePath('/account/gift-cards');
    return { ok: true, data: r };
  } catch (e) { return fail(dbMessage(e)); }
}

/** Add a gift card to the account by its code. */
export async function claimGiftCard(code: string): Promise<R<{ card: GiftCardRow; already?: boolean }>> {
  const user = await currentUser();
  if (!user) return fail('Sign in to add a gift card.', 'sign_in');
  const c = normCode(code);
  if (!c) return fail('Enter the 16-character code, for example CCGC-7KQ4-XM2P-Q7XM.', 'invalid', { code: 'The code on the gift card or in the email.' });
  try {
    const r = (await rpc('server_gift_card_claim', { p_user: user.id, p_code: c }, SR)) as unknown as { card: GiftCardRow; already?: boolean };
    revalidatePath('/account/gift-cards');
    return { ok: true, data: r };
  } catch (e) { return fail(dbMessage(e)); }
}

async function myBookingId(number: string): Promise<{ userId: string; bookingId: string } | null> {
  const user = await currentUser();
  if (!user) return null;
  const b = await findBooking(user, number);
  return b ? { userId: user.id, bookingId: b.id } : null;
}

/** Sign and pay: apply a gift card's balance (all it can pay, or the amount typed). */
export async function applyGiftCard(number: string, cardId: string, amountCents?: number | null): Promise<R<BookingGiftState>> {
  const m = await myBookingId(number);
  if (!m) return fail('Booking not found.');
  try {
    const s = (await rpc('server_booking_gift_apply', { p_booking: m.bookingId, p_user: m.userId, p_card: cardId, ...(amountCents ? { p_amount: Math.round(amountCents) } : {}) }, SR)) as unknown as BookingGiftState;
    revalidatePath(bookingPath(number, 'checkout'));
    return { ok: true, data: s };
  } catch (e) { return fail(dbMessage(e)); }
}

export async function removeGiftCard(number: string, applicationId?: string): Promise<R<BookingGiftState>> {
  const m = await myBookingId(number);
  if (!m) return fail('Booking not found.');
  try {
    const s = (await rpc('server_booking_gift_remove', { p_booking: m.bookingId, p_user: m.userId, ...(applicationId ? { p_application: applicationId } : {}) }, SR)) as unknown as BookingGiftState;
    revalidatePath(bookingPath(number, 'checkout'));
    return { ok: true, data: s };
  } catch (e) { return fail(dbMessage(e)); }
}

/** The gift cards cover everything due: confirm the booking with no card charge (the saved card stays for the deposit). */
export async function payWithGiftCards(number: string): Promise<R<{ ok: boolean; message?: string; reason?: string }>> {
  const m = await myBookingId(number);
  if (!m) return fail('Booking not found.');
  try {
    const r = (await rpc('server_booking_gift_pay', { p_booking: m.bookingId, p_user: m.userId }, SR)) as unknown as { ok: boolean; message?: string; reason?: string };
    if (r.ok) {
      // the signed copy, as after a card payment
      try { const { enqueuePdfJobs } = await import('@/server/pdf-jobs'); await enqueuePdfJobs([{ kind: 'renter_signed_copy', ref: m.bookingId, user_id: m.userId }]); } catch (e) { console.error('signed copy job', e); }
    }
    revalidatePath(bookingPath(number));
    revalidatePath('/account/gift-cards');
    return { ok: true, data: r };
  } catch (e) { return fail(dbMessage(e)); }
}
