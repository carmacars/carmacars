import { Suspense } from 'react';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { MasterCalendar, type CalData } from '@/features/admin/MasterCalendar';
import { PageHead } from '@/features/admin/ui';
import { carThumbs } from '@/server/bookings-now';
import { rangeFrom } from '@/features/admin/range';
import { AvailabilityView, type AvailData } from '@/features/admin/AvailabilityView';
import { availQuery, availRange } from '@/features/admin/availability';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Calendar', path: '/admin/calendar', noindex: true, description: 'Every vehicle by day.' });

// The master calendar (03-admin.md section 5).
export default async function Calendar({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read, user }, sp] = await Promise.all([page('/admin/calendar'), searchParams]);
  const { from, to } = rangeFrom(sp.start, sp.view);
  // r44 (2792): which cars are free for the customer's dates (the same view as the staff portal's), above the calendar
  const av = availRange(sp);
  const [data, avail] = await Promise.all([read<CalData>('calendar', { from: from.toISOString(), to: to.toISOString() }),
    read<AvailData>('fleet_availability', availQuery(sp)).then((d) => ({ d, e: null }), (e: unknown) => ({ d: null, e: e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '').slice(0, 200) : 'The availability could not be read' }))]);
  const cars = await carThumbs(user.id, data.vehicles.map((v) => v.id));
  return (
    <>
      <PageHead title="Calendar" kicker="Drag a booking to move it or its right edge to resize; double-click a row for a new block. Tap a bar for its details." />
      <Suspense><AvailabilityView data={avail.d} error={avail.e} from={av.af} to={av.at} base="/admin" canOffer /></Suspense>
      <Suspense><MasterCalendar initial={data} cars={cars} /></Suspense>
    </>
  );
}
