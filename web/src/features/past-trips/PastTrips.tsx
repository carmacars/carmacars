import Link from '@/components/Link';
import { Act } from '@/features/admin/Act';
import { Badge, Card, Table, t } from '@/features/admin/ui';

// Close past trips (release 35, migration 0910): every booking still confirmed or on rent after its return time. One tap
// closes a trip at the booked times (the past-trip override of 0770); "It was late or early" takes the actual times; "Close
// all on time" closes every one. The renter gets no email or text for a back-dated close; the deposit then settles as
// usual. Admin and Fleet; the same component on both portals.
export interface PastTripRow { booking_id: string; booking_number: string; status: string; pickup_at: string; return_at: string; handed_over_at: string | null;
  vehicle: string; plate: string | null; renter: string | null; hours_past: number; odometer_out_km: number | null; [k: string]: unknown }

export const pastDue = (h: number) => (h < 24 ? `${Math.round(h)} h` : `${Math.floor(h / 24)} d`);

export function PastTrips({ rows, base, refresh }: { rows: PastTripRow[]; base: '/admin' | '/staff'; refresh: string[] }) {
  return (
    <Card title={`Trips open after their return time (${rows.length})`} testId="past-trips"
      aside={rows.length > 0 ? <Act ops action="past_trips_close_all" label="Close all on time" variant="primary" testId="past-trips-close-all" refresh={refresh}
        confirm={`Close the ${rows.length} trip${rows.length === 1 ? '' : 's'} below at their booked pickup and return times. The renters get no email.`} done="Closed." /> : null}>
      <p className="small muted">A trip that was never checked in or out is closed here at its booked times. If it went out or came back at another time, use It was late or early.</p>
      <Table rows={rows} rowKey={(r) => r.booking_id} empty="No trip is open after its return time." testId="past-trips-table" cols={[
        { key: 'booking_number', label: 'Booking', render: (r) => <Link prefetch={false} className="link" href={`${base}/bookings/${encodeURIComponent(r.booking_number)}`}>{r.booking_number}</Link> },
        { key: 'status', label: 'Now', render: (r) => <Badge s={r.status} /> },
        { key: 'vehicle', label: 'Car', render: (r) => <>{r.vehicle}{r.plate ? <span className="muted small"> · {r.plate}</span> : null}</> },
        { key: 'renter', label: 'Renter' },
        { key: 'pickup_at', label: 'Pickup', render: (r) => t(r.handed_over_at ?? r.pickup_at) },
        { key: 'return_at', label: 'Return due', render: (r) => <>{t(r.return_at)} <span className="ad-late small">{pastDue(r.hours_past)} ago</span></> },
        { key: 'act', label: '', render: (r) => <span className="ad-actions">
          <Act ops action="past_trip_close" payload={{ booking: r.booking_id }} label="Close on time" variant="primary" testId={`close-${r.booking_number}`} refresh={refresh} done="Closed on time." />
          <Act ops action="past_trip_close" payload={{ booking: r.booking_id }} label="It was late or early" testId={`close-at-${r.booking_number}`} refresh={refresh} done="Closed at the actual times."
            fields={[
              ...(r.status === 'on_rent' ? [] : [{ name: 'pickup_at', label: 'Actual pickup', type: 'datetime' as const, required: true, value: r.pickup_at }]),
              { name: 'return_at', label: 'Actual return', type: 'datetime' as const, required: true, value: r.return_at },
              ...(r.status === 'on_rent' ? [] : [{ name: 'odometer_out_km', label: 'Odometer at pickup (km, optional)', type: 'number' as const, min: 0 }]),
              { name: 'odometer_in_km', label: 'Odometer at return (km, optional)', type: 'number' as const, min: 0 },
              { name: 'reason', label: 'Note (optional)', type: 'text' as const }]} /></span> }]} />
    </Card>
  );
}
