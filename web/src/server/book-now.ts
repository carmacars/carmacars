import 'server-only';

// Book it now (migration 0770): an offer booked without the renter's approval waits for payment. Its rental agreement is
// made as the renter at once, and the agreement's "sign your agreement" email (it opens the Sign and pay page,
// /account/bookings/<n>/checkout) is the renter's one link. Called with what the database returned (book_now of
// send_offer and offer_create, or an Admin's approval); a failure is left to the agreements job and its To do.
export async function bookNowAgreement(data: unknown): Promise<void> {
  const d = data as { status?: string; booking_id?: string; renter_user_id?: string | null; book_now?: unknown } | null;
  if (d && typeof d === 'object' && d.book_now && typeof d.book_now === 'object') return bookNowAgreement(d.book_now);
  if (!d || d.status !== 'approved' || !d.booking_id || !d.renter_user_id) return;
  const { ensureAgreement } = await import('@/server/agreement-auto');
  await ensureAgreement(d.booking_id, d.renter_user_id, 'book_now').catch(() => undefined);
}
