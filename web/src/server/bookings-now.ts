import 'server-only';
import { door } from '@/server/door';
import type { Board, Car } from '@/features/bookings-now/model';
import type { Cards } from '@/features/bookings-now/cards';

// Bookings > Now (migration 0330): one read through the door. ops_read for Admins and office staff (the database lets
// fleet and customer service in, with the money), field_read for field staff (the cars without the money). Never kept:
// every load and every 30-second refresh reads afresh.
export async function bookingsNow(userId: string, opts: { field?: boolean; va?: string | null; aal?: 'aal1' | 'aal2' | null } = {}): Promise<Board> {
  return door<Board>(userId, opts.field ? 'field_read' : 'ops_read', 'bookings_now', opts.va ? { _va: opts.va } : {}, opts.aal);
}

/** The rows' car photos, renter mobiles, licences and money (0332), for bookings the caller's list already shows. */
export async function bookingCards(userId: string, ids: string[], opts: { va?: string | null; aal?: 'aal1' | 'aal2' | null } = {}): Promise<Cards> {
  if (!ids.length) return {};
  return door<Cards>(userId, 'ops_read', 'booking_cards', { ids: ids.slice(0, 300), ...(opts.va ? { _va: opts.va } : {}) }, opts.aal).catch(() => ({} as Cards));
}

/** Each car's photo, code and plate for the Calendar's rows (0332). */
export async function carThumbs(userId: string, ids: string[], opts: { va?: string | null; aal?: 'aal1' | 'aal2' | null } = {}): Promise<Record<string, Car>> {
  if (!ids.length) return {};
  return door<Record<string, Car>>(userId, 'ops_read', 'car_thumbs', { ids: ids.slice(0, 500), ...(opts.va ? { _va: opts.va } : {}) }, opts.aal).catch(() => ({}));
}
