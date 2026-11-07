import { torontoParts, torontoToday } from '../../lib/dates.ts';

// r32 one-tap return: which bookings show "Returned". A car on rent that is overdue or due back today (Toronto time).
export function showReturned(b: { status: string; return_at: string | null | undefined }, now: Date = new Date()): boolean {
  if (b.status !== 'on_rent' || !b.return_at) return false;
  const at = Date.parse(b.return_at);
  if (Number.isNaN(at)) return false;
  return at <= now.getTime() || torontoParts(b.return_at).date <= torontoToday(now);
}

/** What "Returned" sends besides the form: the 0195 record-now path, the return, with why the details come later. */
export const RETURNED_REASON = 'Returned: marked with one tap, photos and readings later';
