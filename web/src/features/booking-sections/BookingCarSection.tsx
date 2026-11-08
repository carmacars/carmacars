import Link from '@/components/Link';
import { Card } from '@/features/admin/ui';

// r32 "Car & handovers": the car of the booking and every handover screen from one place (the check-in and check-out
// above, the photo report, sign on this device), for Admin and staff alike; each page keeps its own address.
export function BookingCarSection({ base, number, vehicleName, vehicleHref, status, canSign = true }: { base: string; number: string; vehicleId: string; vehicleName: string | null; vehicleHref: string | null; status: string;
  /** the in-person signing page answers only those who may sign (bookingCan.sign: not Finance) */ canSign?: boolean }) {
  const handed = ['on_rent', 'returned', 'closed'].includes(status);
  return (
    <Card title="Car & handovers" testId="booking-car-section">
      <ul className="stack small">
        <li>Car: {vehicleHref ? <Link prefetch={false} className="link" href={vehicleHref}>{vehicleName ?? 'Open the car'}</Link> : (vehicleName ?? 'not set')}</li>
        <li><Link prefetch={false} className="link" href={`${base}/report`} data-testid="car-report-link">Check-in and check-out photo report</Link>{handed ? '' : ' (after the check-in)'}</li>
        {canSign && <li><Link prefetch={false} className="link" href={`${base}/sign-now`} data-testid="car-sign-now-link">Sign on this device</Link> (the renter signs the agreement in person)</li>}
      </ul>
      <p className="small muted">Booking {number}: the check-in and check-out are recorded above on one screen.</p>
    </Card>
  );
}
