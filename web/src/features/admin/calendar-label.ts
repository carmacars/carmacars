// The fleet calendar's bar words and day widths (r48, docs/changes/2026-11-14-r48-fleet-calendar.md). Node-tested.
import { OWNER_TRIP } from '../request-history/model.ts';

/** r48: day widths that leave room for a renter and a booking number on a two-day bar (month: a date and its weekday). */
export const VIEWS: Record<string, { days: number; dw: number; label: string }> = { week: { days: 7, dw: 132, label: 'Week' }, two: { days: 14, dw: 80, label: '2 weeks' }, month: { days: 31, dw: 44, label: 'Month' } };

export interface LabelEntry { type: string; booking_type: string | null; booking_number: string | null; renter: string | null; status: string | null; reason: string | null; note: string | null;
  placeholder?: boolean; blocks: boolean | null; insurer: string | null }
/** r48: a bar's words in two parts, who (or what) first and the booking number or note after, so a short bar still
 * shows the part that matters. The full words stay in the bar's title and label. */
export function barLabel(e: LabelEntry): { main: string; sub: string } {
  if (e.type === 'block') { const r = (e.reason ?? 'block').replace(/_/g, ' '); return { main: r.charAt(0).toUpperCase() + r.slice(1), sub: e.note ?? '' }; }
  if (e.type !== 'booking') return { main: '', sub: '' };
  if (e.booking_type === 'owner') return { main: OWNER_TRIP, sub: e.booking_number ?? '' };
  const state = e.status === 'requested' ? 'Request' : e.status === 'offered' ? 'Offer' : e.status === 'pending_payment' ? 'Payment due' : '';
  const flags = [state, e.placeholder ? 'placeholder' : e.blocks === false ? 'not blocking' : '', e.insurer ? 'insurer' : ''].filter(Boolean).join(', ');
  return { main: e.renter?.trim() || e.booking_number || state || 'Booking', sub: [e.renter?.trim() ? e.booking_number : '', flags].filter(Boolean).join(' · ') };
}
