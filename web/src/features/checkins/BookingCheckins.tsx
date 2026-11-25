import Link from '@/components/Link';
import { Card } from '@/features/admin/ui';
import { Act } from '@/features/admin/Act';
import { WHY_WORDS, dayWords, type VisitRead } from './model';

// The booking page's card (release 50, migration 4000): whether this rental gets monthly check-in visits, the next one,
// and the switch (on for any rental, off, or back to the rule by its length).
export function BookingCheckins({ d, base, refresh }: { d: VisitRead; base: string; refresh: string[] }) {
  const v = d.visit && ['due', 'booked'].includes(d.visit.status) ? d.visit : null;
  const n = d.booking.booking_number;
  return (
    <Card title="Check-in visits" testId="booking-checkins" aside={<span className="small" data-testid="booking-checkins-state">{d.on ? 'On' : 'Off'}</span>}>
      <p className="small">{d.on ? `Monthly visits (${d.why ? WHY_WORDS[d.why] : ''}). ${v ? `Open: ${v.time_words}.` : d.next_on ? `Next around ${dayWords(d.next_on)}.` : 'No visit before the return.'}` : 'No monthly check-in visits on this rental.'}{d.switch ? ` Switched ${d.switch} by staff.` : ''}</p>
      <span className="ad-actions">
        {v && <Link prefetch={false} className="btn btn--ghost btn--sm" href={`${base}/check-ins/${v.id}`} data-testid="booking-checkins-open">Open the visit</Link>}
        {d.may_switch && <>
          {!d.on && <Act ops action="checkin_do" payload={{ op: 'switch', booking: n, mode: 'on' }} label="Turn on" testId="booking-checkins-on" refresh={refresh} done="Check-in visits on." />}
          {d.on && <Act ops action="checkin_do" payload={{ op: 'switch', booking: n, mode: 'off' }} label="Turn off" testId="booking-checkins-off" refresh={refresh} done="Check-in visits off for this rental."
            confirm="No more check-in visits or reminders for this rental?" />}
          {d.switch && <Act ops action="checkin_do" payload={{ op: 'switch', booking: n, mode: null }} label="Back to the rule" variant="quiet" testId="booking-checkins-default" refresh={refresh} done="Back to the rule by the rental's length." />}
        </>}
      </span>
    </Card>
  );
}
