import { Suspense } from 'react';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { MasterCalendar, type CalData } from '@/features/admin/MasterCalendar';
import { PageHead } from '@/features/admin/ui';
import { rangeFrom } from '@/features/admin/range';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Calendar', path: '/admin/calendar', noindex: true, description: 'Every vehicle by day.' });

// The master calendar (03-admin.md section 5).
export default async function Calendar({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read }, sp] = await Promise.all([page('/admin/calendar'), searchParams]);
  const { from, to } = rangeFrom(sp.start, sp.view);
  const data = await read<CalData>('calendar', { from: from.toISOString(), to: to.toISOString() });
  return (
    <>
      <PageHead title="Calendar" kicker="Drag a booking to move it, drag its right edge to resize; double-click a row for a new block" />
      <Suspense><MasterCalendar initial={data} /></Suspense>
    </>
  );
}
