import Link from '@/components/Link';
import { PortalCard } from '@/components/portal-ui';
import { bookingPath } from '@/features/portal/status';
import { nextLine, type RenterState } from './model';

// The renter's card (release 50, migration 4000): on the trips page and the booking page of a long rental. A suggestion,
// never a requirement or a fee: "Next check-in visit: around <date>", why it helps, and Pick a time.
export function CheckinCard({ s, number }: { s: RenterState; number: string }) {
  const line = nextLine(s);
  if (!line) return null;
  const booked = s.visit?.status === 'booked';
  const open = !!s.visit && ['due', 'booked'].includes(s.visit.status);
  return (
    <PortalCard id={`ci-${number}`} title={line} testId="checkin-card"
      action={open ? <Link prefetch={false} className="btn btn--ghost btn--sm" href={bookingPath(number, 'check-in')} data-testid="checkin-pick">{booked ? 'Change the time' : 'Pick a time'}</Link> : undefined}>
      <p className="small">A quick, free visit about once a month (about 15 minutes): we keep the car in top shape for you and catch maintenance early. Nothing to pay.</p>
      {booked && s.visit && <p className="small" data-testid="checkin-where">{s.visit.place_words}</p>}
      {!open && <p className="small muted">We will send you a reminder a few days before, so you can pick a time that suits you.</p>}
    </PortalCard>
  );
}
