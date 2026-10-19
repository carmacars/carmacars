import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { PageHead } from '@/features/admin/ui';
import { CalendarSync, type SyncData } from '@/features/calendar/CalendarSync';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Calendar sync', path: '/admin/calendar-sync', noindex: true, description: 'Turo, Getaround and other calendars, both ways, per car.' });

// Cars > Calendar sync (migration 0062).
export default async function AdminCalendarSync() {
  const { read } = await page('/admin/calendar-sync');
  const d = await read<SyncData>('calendar_sync');
  return (<><PageHead title="Calendar sync" kicker="Cars" /><CalendarSync data={d} bookingBase="/admin/bookings" /></>);
}
