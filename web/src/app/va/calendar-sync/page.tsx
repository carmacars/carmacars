import { pageMeta } from '@/features/seo/meta';
import { vaPage, FN_LABEL } from '@/server/va';
import { PageHead } from '@/features/admin/ui';
import { CalendarSync, type SyncData } from '@/features/calendar/CalendarSync';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Calendar sync', path: '/va/calendar-sync', noindex: true, description: 'Turo, Getaround and other calendars, both ways, per car.' });

// Cars > Calendar sync (migration 0062): Fleet.
export default async function VaCalendarSync() {
  const { read, fn } = await vaPage('/va/calendar-sync', ['fleet']);
  const d = await read<SyncData>('calendar_sync');
  return (<><PageHead title="Calendar sync" kicker={FN_LABEL[fn]} /><CalendarSync data={d} bookingBase="/va/bookings" /></>);
}
