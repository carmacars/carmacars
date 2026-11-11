'use server';
import { revalidatePath } from 'next/cache';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import type { ActionResult } from '@/features/forms/schemas';
import { refusalMessage } from '@/lib/db/refusal';
import { bookingPath } from '@/features/portal/status';
import { findBooking, requireUser } from '@/server/portal/data';
import { RIDESHARE_PLATFORMS, type RidesharePlatform } from '@/features/rideshare/model';

// r35a: the renter's own small actions: the secondary contact (1302), the rideshare documents (1303) and the photos with a
// review (1305). Each goes to the database as the server with the signed-in renter; the database checks the booking is theirs.
const SR = { role: 'service_role' as const };
type R<T = null> = ActionResult<T>;

export interface ContactInput { name: string; relationship: string; phone: string; email: string; scope: 'profile' | 'booking' | 'both'; booking?: string }

export async function saveSecondaryContact(input: ContactInput): Promise<R> {
  try {
    const user = await requireUser(input.booking ? bookingPath(input.booking) : '/account/profile');
    let booking: string | null = null;
    if (input.booking && input.scope !== 'profile') {
      const b = await findBooking(user, input.booking);
      if (!b) return { ok: false, code: 'refused', message: 'Booking not found.' };
      booking = b.id;
    }
    await rpc('server_secondary_contact_save', { p_by: user.id, p: { name: input.name, relationship: input.relationship, phone: input.phone, email: input.email,
      scope: input.scope, ...(booking ? { booking } : {}) } as unknown as Json }, SR);
    revalidatePath('/account/profile');
    if (input.booking) revalidatePath(bookingPath(input.booking));
    return { ok: true, data: null };
  } catch (e) { return { ok: false, code: 'refused', message: refusalMessage(e) }; }
}

export async function requestRideshareDocs(number: string, platforms: RidesharePlatform[], other: string): Promise<R> {
  try {
    const user = await requireUser(bookingPath(number));
    const b = await findBooking(user, number);
    if (!b) return { ok: false, code: 'refused', message: 'Booking not found.' };
    const picked = platforms.filter((x) => RIDESHARE_PLATFORMS.some(([k]) => k === x));
    await rpc('server_rideshare_docs_request', { p_by: user.id, p: { booking: b.id, platforms: picked, other } as unknown as Json }, SR);
    revalidatePath(bookingPath(number, 'rideshare'));
    return { ok: true, data: null };
  } catch (e) { return { ok: false, code: 'refused', message: refusalMessage(e) }; }
}

export async function setReviewPhotos(number: string, paths: string[]): Promise<R<{ points: number }>> {
  try {
    const user = await requireUser(bookingPath(number, 'review'));
    const b = await findBooking(user, number);
    if (!b) return { ok: false, code: 'refused', message: 'Booking not found.' };
    const r = (await rpc('server_review_photos_set', { p_booking: b.id, p_by: user.id, p_photos: paths.slice(0, 6).map((path) => ({ path })) as unknown as Json }, SR)) as unknown as { points: number };
    revalidatePath(bookingPath(number, 'review'));
    return { ok: true, data: { points: Number(r?.points ?? 0) } };
  } catch (e) { return { ok: false, code: 'refused', message: refusalMessage(e) }; }
}
