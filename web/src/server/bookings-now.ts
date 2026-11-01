import 'server-only';
import { door } from '@/server/door';
import type { Board } from '@/features/bookings-now/model';

// Bookings > Now (migration 0330): one read through the door. ops_read for Admins and office staff (the database lets
// fleet and customer service in, with the money), field_read for field staff (the cars without the money). Never kept:
// every load and every 30-second refresh reads afresh.
export async function bookingsNow(userId: string, opts: { field?: boolean; va?: string | null; aal?: 'aal1' | 'aal2' | null } = {}): Promise<Board> {
  return door<Board>(userId, opts.field ? 'field_read' : 'ops_read', 'bookings_now', opts.va ? { _va: opts.va } : {}, opts.aal);
}
