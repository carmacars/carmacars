import { Suspense } from 'react';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { MasterCalendar, type CalData } from '@/features/admin/MasterCalendar';
import { rangeFrom } from '@/features/admin/range';
import { PageHead } from '@/features/admin/ui';
import { carThumbs } from '@/server/bookings-now';
import { AvailabilityView, type AvailData } from '@/features/admin/AvailabilityView';
import { availQuery, availRange } from '@/features/admin/availability';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Calendar', path: '/staff/calendar', noindex: true, description: 'Which cars are free, and every vehicle by day.' });

// The master calendar for an assistant: read for every function; Fleet creates blocks (the database decides
// what each may change; customer service and Sales see first names only).
export default async function VaCalendar({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read, fn, user, aal }, sp] = await Promise.all([vaPage('/staff/calendar'), searchParams]);
  const { from, to } = rangeFrom(sp.start, sp.view);
  // r44 (2792): which cars are free for the customer's dates, above the calendar; Sales and customer service offer from it
  const av = availRange(sp);
  const [data, avail] = await Promise.all([read<CalData>('calendar', { from: from.toISOString(), to: to.toISOString() }),
    read<AvailData>('fleet_availability', availQuery(sp)).then((d) => ({ d, e: null }), (e: unknown) => ({ d: null, e: e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '').slice(0, 200) : 'The availability could not be read' }))]);
  const cars = await carThumbs(user.id, data.vehicles.map((v) => v.id), { va: fn, aal });
  return (
    <>
      <PageHead title="Calendar" kicker={fn === 'fleet' ? 'Double-click a row for a new block' : 'Read only'} />
      <Suspense><AvailabilityView data={avail.d} error={avail.e} from={av.af} to={av.at} base="/staff" canOffer={fn === 'cs' || fn === 'sales'} /></Suspense>
      {/* the vehicle page is open to Fleet and customer service only (vaPage of /va/vehicles/[id]) */}
      <Suspense><MasterCalendar initial={data} cars={cars} vehicleLinks={fn === 'fleet' || fn === 'cs'} /></Suspense>
    </>
  );
}
