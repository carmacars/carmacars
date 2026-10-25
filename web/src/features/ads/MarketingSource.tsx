import { Act } from '@/features/admin/Act';

// A booking's source for the channel report (migration 0167): what staff set ("Came from"), else the renter's visit (the
// last touch; the first in brackets when it differs). Staff set it when the renter told them (a Kijiji reply, a walk-in).
export interface MarketingData { channel: string; label: string; first: string; staff_source: string | null; staff_note: string | null; options: Array<[string, string]> }

export function MarketingSource({ m, booking, refresh }: { m: MarketingData; booking: string; refresh: string[] }) {
  return (
    <span data-testid="booking-came-from">{m.label}{m.staff_source ? ' (set by staff)' : m.first !== m.label ? ` (first visit: ${m.first})` : ''}{m.staff_note ? `: ${m.staff_note}` : ''}{' '}
      <Act action="booking_marketing_source" payload={{ booking }} label={m.staff_source ? 'Change' : 'Set'} variant="quiet" testId="booking-came-from-set" refresh={refresh} done="Saved."
        fields={[{ name: 'source', label: 'Where the renter came from', type: 'select', options: [['', 'From their visit (not set by hand)'], ...m.options], value: m.staff_source ?? '' },
          { name: 'note', label: 'Note (for example "replied to the Kijiji ad")', type: 'text', value: m.staff_note }]} />
    </span>
  );
}
